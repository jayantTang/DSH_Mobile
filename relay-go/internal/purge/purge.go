// Package purge 是设备死记录的清理工具（Python relay/purge-revoked-devices.py 的
// Go 版本），供 `dsh-relay purge` 与 dsh-relay-go-purge.timer 调用。
//
// 为什么需要它：中转在每次连接器连上时会把该 agent 名下「永远回不来的设备」逐条
// 通知连接器（hub.tellAgentAboutTheGone）。2026-10-12 库里攒了 2012 条已撤销记录，
// 每次重连灌 2012 帧，把连接器处理链堵住，手机跟着断断续续；这类死记录同时也是
// 重连风暴的助燃剂。清理只在凌晨跑一次，把已撤销/已过期的行真删掉。
//
// 安全约定（与 Python 版一致）：
//   - 默认只预演，--apply 才改库；
//   - 只删 revokedAt IS NOT NULL OR expiresAt <= now，在用设备一行都不碰；
//   - 一条待删行都没有时不写备份、不动库；
//   - --apply 时先做整库备份与待删行 JSON 导出，核对备份行数后才删；
//   - --keep N 只清理本工具命名的旧备份（state-*.db / purged-devices-*.json）。
package purge

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// backupPattern 只匹配本工具写的备份文件（--keep 不碰目录里别的东西）。
var backupPattern = regexp.MustCompile(`^(?:state|purged-devices-.+)-(20\d{6}-\d{6})\.(?:db|json)$`)

// Options 是一次清理的参数。
type Options struct {
	DBPath    string
	AgentID   string
	AllAgents bool
	Apply     bool
	BackupDir string
	Keep      int
	// Now 覆盖「现在」；单测用它固定时间戳。
	Now func() time.Time
}

// AgentReport 是一个 agent 的清理明细（整行留在 JSON 输出里，便于核对）。
type AgentReport struct {
	AgentID     string         `json:"agentId"`
	Total       int            `json:"total"`
	Doomed      int            `json:"doomed"`
	Live        int            `json:"live"`
	LiveDevices []DeviceBrief  `json:"liveDevices,omitempty"`
	DoomedNames map[string]int `json:"doomedNames,omitempty"`
}

// DeviceBrief 是在用设备的可读摘要（不含令牌哈希）。
type DeviceBrief struct {
	DeviceID  string `json:"deviceId"`
	Name      string `json:"name"`
	ExpiresAt int64  `json:"expiresAt"`
}

// Report 是命令的 JSON 输出。
type Report struct {
	OK             bool          `json:"ok"`
	Applied        bool          `json:"applied"`
	Agents         []AgentReport `json:"agents"`
	Removed        int64         `json:"removed"`
	Backup         string        `json:"backup,omitempty"`
	Dump           string        `json:"dump,omitempty"`
	BackupsRemoved []string      `json:"backupsRemoved,omitempty"`
}

// UsageError 是参数/配置错误（退出码 2）；其余错误一律是运行失败（退出码 1）。
type UsageError struct{ err error }

func (e *UsageError) Error() string { return e.err.Error() }
func (e *UsageError) Unwrap() error { return e.err }

func usagef(format string, args ...any) error {
	return &UsageError{err: fmt.Errorf(format, args...)}
}

// Run 执行一次清理。options.Now 只影响时间戳与「过期」的判定。
func Run(ctx context.Context, options Options) (Report, error) {
	if strings.TrimSpace(options.DBPath) == "" {
		return Report{}, usagef("--db 是必填项")
	}
	if !options.AllAgents && strings.TrimSpace(options.AgentID) == "" {
		return Report{}, usagef("--agent 与 --all-agents 必须给一个")
	}
	if options.AllAgents && strings.TrimSpace(options.AgentID) != "" {
		return Report{}, usagef("--agent 与 --all-agents 只能给一个")
	}
	if _, err := os.Stat(options.DBPath); err != nil {
		return Report{}, fmt.Errorf("数据库不可读（%s）：%w", options.DBPath, err)
	}
	now := time.Now()
	if options.Now != nil {
		now = options.Now()
	}
	stamp := now.UnixMilli()

	// 运维例外（DESIGN-20261023 §2.5）：purge 是按路径自己打开库的一次性工具，
	// 实际只用 4 个方法（AgentIDsWithDevices/DevicePurgeReport/DeleteDoomedDevices/
	// BackupTo）。为它引入端口层只是多一层适配，故保留完整仓储类型 *store.Store。
	live, err := store.Open(options.DBPath)
	if err != nil {
		return Report{}, err
	}
	defer live.Close()

	agentIDs, err := targetAgents(ctx, live, options)
	if err != nil {
		return Report{}, err
	}
	rows, err := live.DevicePurgeReport(ctx, agentIDs, stamp)
	if err != nil {
		return Report{}, err
	}
	report := Report{OK: true, Applied: options.Apply, Agents: make([]AgentReport, 0, len(rows))}
	doomed := 0
	for _, row := range rows {
		entry := AgentReport{
			AgentID: row.AgentID, Total: row.Total,
			Doomed: len(row.Doomed), Live: len(row.Live),
			DoomedNames: map[string]int{},
		}
		for _, device := range row.Doomed {
			name := device.Name
			if name == "" {
				name = "(无名)"
			}
			entry.DoomedNames[name]++
		}
		for _, device := range row.Live {
			entry.LiveDevices = append(entry.LiveDevices, DeviceBrief{
				DeviceID: device.DeviceID, Name: device.Name, ExpiresAt: device.ExpiresAt,
			})
		}
		doomed += len(row.Doomed)
		report.Agents = append(report.Agents, entry)
	}
	if !options.Apply {
		return report, nil
	}

	backupDir := options.BackupDir
	if backupDir == "" {
		backupDir = filepath.Join(filepath.Dir(options.DBPath), "backups")
	}
	if doomed == 0 {
		report.BackupsRemoved, err = pruneBackups(backupDir, options.Keep)
		return report, err
	}

	if err := os.MkdirAll(backupDir, 0o700); err != nil {
		return Report{}, fmt.Errorf("创建备份目录 %s: %w", backupDir, err)
	}
	stampText := now.Format("20060102-150405")
	scope := "all"
	if !options.AllAgents {
		scope = options.AgentID
	}
	backupPath := filepath.Join(backupDir, "state-"+stampText+".db")
	dumpPath := filepath.Join(backupDir, "purged-devices-"+scope+"-"+stampText+".json")
	if err := live.BackupTo(ctx, backupPath); err != nil {
		return Report{}, err
	}
	// 备份必须在删除之前核对：行数对不上就停手，库一行都不动。
	backupCounts, err := store.CountDevicesInBackup(ctx, backupPath, agentIDs)
	if err != nil {
		return Report{}, err
	}
	expected := 0
	for _, row := range rows {
		expected += row.Total
		if backupCounts[row.AgentID] != row.Total {
			return Report{}, fmt.Errorf(
				"备份里 agent %s 有 %d 行，源库 %d 行；停手",
				row.AgentID, backupCounts[row.AgentID], row.Total)
		}
	}
	if err := writeDump(dumpPath, rows); err != nil {
		return Report{}, err
	}
	report.Backup = backupPath
	report.Dump = dumpPath

	removed, err := live.DeleteDoomedDevices(ctx, agentIDs, stamp)
	if err != nil {
		return Report{}, err
	}
	report.Removed = removed

	// 删完再核对一次：每个 agent 剩余行数必须等于「在用」数，且不再有死行。
	after, err := live.DevicePurgeReport(ctx, agentIDs, stamp)
	if err != nil {
		return Report{}, err
	}
	for index, row := range after {
		if len(row.Doomed) != 0 || len(row.Live) != len(rows[index].Live) {
			return Report{}, fmt.Errorf(
				"agent %s 清理后核对失败：仍剩 %d 行待删、在用 %d 行（期望 %d）",
				row.AgentID, len(row.Doomed), len(row.Live), len(rows[index].Live))
		}
	}
	report.BackupsRemoved, err = pruneBackups(backupDir, options.Keep)
	return report, err
}

// targetAgents 解析 --agent / --all-agents。
func targetAgents(ctx context.Context, live *store.Store, options Options) ([]string, error) {
	if !options.AllAgents {
		return []string{options.AgentID}, nil
	}
	return live.AgentIDsWithDevices(ctx)
}

// writeDump 把待删行导出成 JSON（Python 版同物：purged-devices-<scope>-<stamp>.json）。
func writeDump(path string, rows []store.DevicePurgeAgent) error {
	devices := make([]store.Device, 0)
	for _, row := range rows {
		devices = append(devices, row.Doomed...)
	}
	payload, err := json.MarshalIndent(devices, "", " ")
	if err != nil {
		return fmt.Errorf("序列化待删行: %w", err)
	}
	if err := os.WriteFile(path, payload, 0o600); err != nil {
		return fmt.Errorf("写待删行导出 %s: %w", path, err)
	}
	return nil
}

// pruneBackups 只留最近 keep 组（一组 = 同一时间戳的 .db 与 .json）。
// keep <= 0 表示不清理。
func pruneBackups(directory string, keep int) ([]string, error) {
	if keep <= 0 {
		return nil, nil
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	stamps := map[string][]string{}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		match := backupPattern.FindStringSubmatch(entry.Name())
		if match == nil {
			continue
		}
		stamps[match[1]] = append(stamps[match[1]], entry.Name())
	}
	ordered := make([]string, 0, len(stamps))
	for stamp := range stamps {
		ordered = append(ordered, stamp)
	}
	sort.Strings(ordered)
	if len(ordered) <= keep {
		return nil, nil
	}
	removed := []string{}
	for _, stamp := range ordered[:len(ordered)-keep] {
		names := stamps[stamp]
		sort.Strings(names)
		for _, name := range names {
			path := filepath.Join(directory, name)
			if err := os.Remove(path); err != nil {
				return removed, fmt.Errorf("删除旧备份 %s: %w", path, err)
			}
			removed = append(removed, path)
		}
	}
	return removed, nil
}

// Main 是 `dsh-relay purge` 的入口：退出码 0 成功、1 失败、2 用法错误。
func Main(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	if getenv == nil {
		getenv = os.Getenv
	}
	fs := flag.NewFlagSet("purge", flag.ContinueOnError)
	fs.SetOutput(stderr)
	db := fs.String("db", getenv("DLP_DB"), "中转库路径（必填）")
	agentID := fs.String("agent", "", "只清这一个 agent")
	allAgents := fs.Bool("all-agents", false, "清库里所有 agent（定时任务用这个）")
	apply := fs.Bool("apply", false, "真的删；不给就是预演")
	backupDir := fs.String("backup-dir", "", "备份与待删行导出的目录（默认库文件旁的 backups/）")
	keep := fs.Int("keep", 0, "只留最近 N 组备份（0 = 不清理）")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	report, err := Run(context.Background(), Options{
		DBPath: *db, AgentID: *agentID, AllAgents: *allAgents, Apply: *apply,
		BackupDir: *backupDir, Keep: *keep,
	})
	if err != nil {
		fmt.Fprintf(stderr, "dsh-relay purge: %v\n", err)
		// 参数/配置错误回 2，其余（库、IO）回 1：定时任务从退出码就能分辨。
		var usageErr *UsageError
		if errors.As(err, &usageErr) {
			return 2
		}
		return 1
	}
	encoder := json.NewEncoder(stdout)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(report); err != nil {
		fmt.Fprintf(stderr, "dsh-relay purge: 写输出失败: %v\n", err)
		return 1
	}
	return 0
}
