// alert-dispatch：把中转写下的告警队列投进我们的信箱（Python relay/alert-dispatch.py）。
//
// 为什么投递独立成一个动作（而不是在 relay 里发）：
//
//	中转是转发进程，它的责任只有"转发"，不该持有发信凭据、也不该因为发信慢/失败而
//	影响转发。所以两边只用一个文件交接：relay 追加 alerts.jsonl，本命令取走、投递、
//	删除。取走是原子的 rename；投递失败就原样追加回去，下次重试，一条都不丢。
//
// 只投给我们自己：收件账号取 --account 或 DLP_ALERT_ACCOUNT，两者都没有就报错
// 退出——不猜、不群发。只发给 owner 本人不需要审批（同日报口径）。
//
// 退出码：0 = 没告警或投递成功；2 = 用法/配置错误；3 = 投递失败（队列已放回）。
package admincli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/monitor"
)

const (
	// maxAlertRecords 是一封信最多带多少条明细；再多就只报总数。
	maxAlertRecords = 40
	// maxAlertBodyChars 是正文上限（字符）。信箱通知是给人看的，不是日志备份。
	maxAlertBodyChars = 12_000
	// alertMailTimeout 是投递子进程的上限（Python 的 timeout=60）。
	alertMailTimeout = 60 * time.Second
)

// alertKindLabels 是告警类别的中文名（与 Python 的 KIND_LABELS 一致）。
var alertKindLabels = map[string]string{
	"exception":     "未处理异常",
	"flap":          "连接反复断开",
	"corrupt-frame": "上游坏字符",
}

// 告警详情的渲染顺序。Python 依赖 dict 的插入顺序；Go 的 map 无序，所以这里固定
// 一张已知键表，未列出的键按字典序排在后面（新字段不会悄悄消失）。
var alertDetailOrder = []string{
	"source", "path", "place", "frames", "method", "status",
	"agentId", "name", "windowSeconds", "disconnectsInWindow",
	"deviceId", "frameType", "count", "totalChars", "firstIndex", "trailingChars",
	"kinds", "sample", "sampled",
}

// alertDispatchOptions 是命令行解析结果。
type alertDispatchOptions struct {
	alertDir   string
	accounts   []string
	mailDB     string
	mailAdmin  string
	mailPython string
	format     string
	dryRun     bool
}

// runAlertDispatch 实现 admin alert-dispatch。
func runAlertDispatch(args []string, getenv func(string) string,
	stdout, stderr io.Writer) error {
	if getenv == nil {
		getenv = os.Getenv
	}
	fs := flag.NewFlagSet(cmdAlertDispatch, flag.ContinueOnError)
	fs.SetOutput(stderr)
	var accounts stringListFlag
	alertDir := fs.String("alert-dir", getenv("DLP_ALERT_DIR"), "relay 写告警的目录")
	fs.Var(&accounts, "account", "收件账号；不给则用 DLP_ALERT_ACCOUNT（只投给 owner 本人）")
	mailDB := fs.String("mail-db", getenv("DLP_ALERT_MAIL_DB"), "信箱库路径")
	mailAdmin := fs.String("mail-admin", getenv("DLP_ALERT_MAIL_ADMIN"), "信箱 admin 脚本路径")
	mailPython := fs.String("mail-python", getenv("DLP_ALERT_MAIL_PYTHON"), "跑信箱 admin 的 python")
	format := fs.String("format", "text", "text 或 html")
	dryRun := fs.Bool("dry-run", false, "只打印正文，不动队列、不发信")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	if *format != "text" && *format != "html" {
		return newUsageError("--format 只支持 text 或 html，收到 %q", *format)
	}

	options := alertDispatchOptions{
		alertDir: strings.TrimSpace(*alertDir), accounts: accounts,
		mailDB: *mailDB, mailAdmin: *mailAdmin, mailPython: *mailPython,
		format: *format, dryRun: *dryRun,
	}
	if options.alertDir == "" {
		return newUsageError("--alert-dir (或 DLP_ALERT_DIR) 是必填项")
	}

	if options.dryRun {
		records, _, err := monitor.ReadQueue(filepath.Join(options.alertDir, monitor.QueueName))
		if err != nil {
			if os.IsNotExist(err) {
				fmt.Fprintln(stdout, "alert-dispatch: queue is empty")
				return nil
			}
			return err
		}
		records = firstRecords(records)
		if len(records) == 0 {
			fmt.Fprintln(stdout, "alert-dispatch: queue is empty")
			return nil
		}
		fmt.Fprintln(stdout, buildAlertBody(records, time.Now()))
		return nil
	}

	recipients := normalizedAccounts(options.accounts)
	if len(recipients) == 0 {
		recipients = envAccounts(getenv("DLP_ALERT_ACCOUNT"))
	}
	if len(recipients) == 0 {
		return newUsageError("no recipient account (--account or DLP_ALERT_ACCOUNT)")
	}
	for _, required := range []struct {
		label string
		value string
	}{
		{"--mail-db", options.mailDB}, {"--mail-admin", options.mailAdmin},
		{"--mail-python", options.mailPython},
	} {
		if strings.TrimSpace(required.value) == "" {
			return newUsageError("%s is required", required.label)
		}
	}

	records, bad, err := monitor.TakeQueue(options.alertDir)
	if err != nil {
		return err
	}
	if bad > 0 {
		fmt.Fprintf(stderr, "alert-dispatch: skipped %d malformed queue line(s)\n", bad)
	}
	if len(records) == 0 {
		return nil
	}
	// 一次只展开 MAX_RECORDS 条；其余留在 taken 里（成功时随 taken 一起删掉——
	// 与 Python 相同：这一封只报总数，别让通知变成日志备份）。
	batch := firstRecords(records)
	subject := time.Now().Format("中转告警 2006-01-02 15:04")
	if extra := len(records) - len(batch); extra > 0 {
		subject += fmt.Sprintf("（另有 %d 条未展开）", extra)
	}
	body := buildAlertBody(batch, time.Now())

	var deliveryErr error
	for _, account := range recipients {
		if err := deliverAlert(options, subject, body, account, stdout, stderr); err != nil {
			deliveryErr = err
			break
		}
	}
	if deliveryErr != nil {
		if restoreErr := monitor.RestoreQueue(options.alertDir); restoreErr != nil {
			return fmt.Errorf("投递失败（%v），放回队列也失败: %w", deliveryErr, restoreErr)
		}
		return deliveryErr
	}
	if err := monitor.DiscardTaken(options.alertDir); err != nil {
		return fmt.Errorf("投递成功但清理队列失败: %w", err)
	}
	return nil
}

// firstRecords 取正文里最多展开的条数。
func firstRecords(records []monitor.Record) []monitor.Record {
	if len(records) <= maxAlertRecords {
		return records
	}
	return records[:maxAlertRecords]
}

// buildAlertBody 把队列记录拼成一封信的 Markdown 正文（与 Python 逐段一致）。
func buildAlertBody(records []monitor.Record, now time.Time) string {
	lines := []string{
		fmt.Sprintf("中转在 %s 前后报出 %d 类事件（同类只留最近一条）。",
			now.Format("2006-01-02 15:04"), len(records)),
		"",
	}
	for index, record := range records {
		label := alertKindLabels[record.Kind]
		if label == "" {
			label = record.Kind
		}
		if label == "" {
			label = "unknown"
		}
		badge := "再次出现"
		if record.NewCategory {
			badge = "新类别"
		}
		title := strings.TrimSpace(record.Title)
		if title == "" {
			title = strings.TrimSpace(record.Key)
		}
		lines = append(lines, fmt.Sprintf("%d. [%s] %s：%s", index+1, badge, label, title))
		if summary := strings.TrimSpace(record.Summary); summary != "" {
			lines = append(lines, "   "+summary)
		}
		if record.Count != 0 {
			lines = append(lines, fmt.Sprintf("   累计 %d 次", record.Count))
		}
		if details := formatAlertDetails(record.Details); details != "" {
			lines = append(lines, "   "+details)
		}
		lines = append(lines, "")
	}
	body := strings.TrimSpace(strings.Join(lines, "\n")) + "\n"
	if runes := []rune(body); len(runes) > maxAlertBodyChars {
		body = string(runes[:maxAlertBodyChars]) +
			"\n…（正文已截断，完整记录在服务器 /var/lib/dsh-relay/alerts/alerts.taken.jsonl）\n"
	}
	return body
}

// formatAlertDetails 渲染 details 段；context 是唯一可能与用户内容有关的一小段，
// 单独换行放在最后（Python 同名逻辑）。
func formatAlertDetails(details map[string]any) string {
	if len(details) == 0 {
		return ""
	}
	keys := orderedAlertDetailKeys(details)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		if key == "context" {
			continue
		}
		parts = append(parts, fmt.Sprintf("%s=%v", key, details[key]))
	}
	text := strings.Join(parts, "，")
	if context, ok := details["context"].(string); ok && context != "" {
		text = fmt.Sprintf("%s\n     片段：%s", text, context)
	}
	return text
}

// orderedAlertDetailKeys 按固定顺序排详情键，未知键按字典序跟上。
func orderedAlertDetailKeys(details map[string]any) []string {
	seen := make(map[string]struct{}, len(details))
	keys := make([]string, 0, len(details))
	for _, key := range alertDetailOrder {
		if _, ok := details[key]; ok {
			keys = append(keys, key)
			seen[key] = struct{}{}
		}
	}
	extra := make([]string, 0, len(details)-len(keys))
	for key := range details {
		if _, ok := seen[key]; !ok {
			extra = append(extra, key)
		}
	}
	sort.Strings(extra)
	return append(keys, extra...)
}

// deliverAlert 调信箱的 admin.py 投一条通知；返回非 nil 表示投递失败。
func deliverAlert(options alertDispatchOptions, subject, body, account string,
	stdout, stderr io.Writer) error {
	handle, err := os.CreateTemp("", "dsh-alert-*.md")
	if err != nil {
		return fmt.Errorf("创建正文临时文件: %w", err)
	}
	path := handle.Name()
	defer os.Remove(path)
	if _, err := handle.WriteString(body); err != nil {
		_ = handle.Close()
		return fmt.Errorf("写正文临时文件: %w", err)
	}
	if err := handle.Close(); err != nil {
		return fmt.Errorf("写正文临时文件: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), alertMailTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, options.mailPython, options.mailAdmin,
		"--db", options.mailDB, "feedback-notify",
		"--account", account, "--subject", subject,
		"--body-file", path, "--format", options.format, "--yes")
	command.Stdout = stdout
	command.Stderr = stderr
	if err := command.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			fmt.Fprintf(stderr, "alert-dispatch: mail admin exited with %d\n", exitErr.ExitCode())
			return fmt.Errorf("信箱投递失败（退出码 %d）", exitErr.ExitCode())
		}
		return fmt.Errorf("无法运行信箱 admin: %w", err)
	}
	return nil
}

// normalizedAccounts 去空白、去空、去重，保持输入顺序（Python dict.fromkeys）。
func normalizedAccounts(values []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(values))
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed == "" {
			continue
		}
		if _, ok := seen[trimmed]; ok {
			continue
		}
		seen[trimmed] = struct{}{}
		out = append(out, trimmed)
	}
	return out
}

// envAccounts 解析 DLP_ALERT_ACCOUNT（逗号分隔）。
func envAccounts(raw string) []string {
	return normalizedAccounts(strings.Split(raw, ","))
}
