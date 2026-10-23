// Package admincli 实现 dsh-relay 的 admin 子命令。
//
// 子命令与 JSON 输出逐项对齐 Python 版 relay/admin.py，黑盒测试的 ADMIN_CMD 可以
// 直接指向 `dsh-relay admin`。调用形态固定为：
//
//	dsh-relay admin --db <path> <子命令> [参数]
//
// `--db` 是全局参数，必须写在子命令之前（与 argparse 的 subparsers 行为一致）。
package admincli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/config"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// DefaultRelay 是中转的公网地址（与 admin.py 的 DEFAULT_RELAY 一致）。
//
// 中转发布在已有站点的一个路径前缀下：不新增 DNS 记录，也不要新证书。
const DefaultRelay = "wss://relay.example.com/dsh-link"

// 子命令名。
const (
	cmdAccountCreate = "account-create"
	cmdAccountList   = "account-list"
	cmdAgentRegister = "agent-register"
	cmdAgentRotate   = "agent-rotate"
	cmdAgentList     = "agent-list"
	cmdAgentDisable  = "agent-disable"
	cmdAgentEnable   = "agent-enable"
	cmdCodeMint      = "code-mint"
	cmdInviteMint    = "invite-mint"
	cmdInviteList    = "invite-list"
	cmdInviteRevoke  = "invite-revoke"
	cmdInviteCheck   = "invite-check"
	cmdDeviceList    = "device-list"
	cmdDeviceRevoke  = "device-revoke"
	cmdDeviceHygiene = "device-hygiene"
	cmdEnrollments   = "enrollments"
	cmdUsage         = "usage"
	cmdPurge         = "purge"
	cmdPushTest      = "push-test"
	cmdOpsReport     = "ops-report"
	cmdAlertDispatch = "alert-dispatch"

	cmdFeedbackList   = "feedback-list"
	cmdFeedbackShow   = "feedback-show"
	cmdFeedbackReply  = "feedback-reply"
	cmdFeedbackNotify = "feedback-notify"
	cmdFeedbackDelete = "feedback-delete"
)

// Main 执行一次 admin 调用，返回进程退出码：
//
//	0 = 成功；1 = 仓储/业务错误；2 = 用法错误。
func Main(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	dbPath, rest, err := parseGlobal(args, getenv)
	if err != nil {
		fmt.Fprintf(stderr, "dsh-relay admin: %v\n", err)
		return 2
	}
	if len(rest) == 0 {
		usage(stderr)
		return 2
	}

	command := rest[0]
	commandArgs := rest[1:]
	switch command {
	case cmdAccountCreate, cmdAccountList, cmdAgentRegister, cmdAgentRotate, cmdAgentList,
		cmdAgentDisable, cmdAgentEnable, cmdCodeMint, cmdInviteMint, cmdInviteList,
		cmdInviteRevoke, cmdInviteCheck, cmdDeviceList, cmdDeviceRevoke, cmdDeviceHygiene,
		cmdEnrollments, cmdUsage, cmdPurge, cmdPushTest, cmdOpsReport, cmdAlertDispatch,
		cmdFeedbackList, cmdFeedbackShow, cmdFeedbackReply, cmdFeedbackNotify,
		cmdFeedbackDelete:
	case "-h", "--help", "help":
		usage(stdout)
		return 0
	default:
		fmt.Fprintf(stderr, "dsh-relay admin: 未知子命令 %q\n", command)
		usage(stderr)
		return 2
	}

	// alert-dispatch 用的是**信箱的**库（--mail-db），不碰中转库；它必须能在没有
	// 中转库的机器上跑（投递进程与转发进程是分开部署的）。
	if command == cmdAlertDispatch {
		return AlertDispatch(commandArgs, getenv, stdout, stderr)
	}

	// 打开库会建目录、建表、迁移；admin 与 serve 用同一套 schema 口径。
	//
	// 运维例外（DESIGN-20261023 §2.5 / §2.8）：admin 是多子命令运维面（32 个仓储
	// 方法），逐命令切端口会产生 20 个小接口，维护成本大于收益。因此这里保留完整
	// 仓储类型 *store.Store；serve 侧的消费者（hub/httpapi/wsapi/files/feedback）
	// 一律只依赖自己声明的最小端口。
	st, err := store.Open(dbPath)
	if err != nil {
		fmt.Fprintf(stderr, "dsh-relay admin: %v\n", err)
		return 1
	}
	defer st.Close()

	ctx := context.Background()
	var runErr error
	switch command {
	case cmdAccountCreate:
		runErr = runAccountCreate(ctx, st, commandArgs, stdout, stderr)
	case cmdAccountList:
		runErr = runAccountList(ctx, st, commandArgs, stdout, stderr)
	case cmdAgentRegister:
		runErr = runAgentRegister(ctx, st, commandArgs, stdout, stderr)
	case cmdAgentRotate:
		runErr = runAgentRotate(ctx, st, commandArgs, stdout, stderr)
	case cmdAgentList:
		runErr = runAgentList(ctx, st, commandArgs, stdout, stderr)
	case cmdAgentDisable, cmdAgentEnable:
		runErr = runAgentToggle(ctx, st, command, commandArgs, stdout, stderr)
	case cmdCodeMint:
		runErr = runCodeMint(ctx, st, commandArgs, stdout, stderr)
	case cmdInviteMint:
		runErr = runInviteMint(ctx, st, commandArgs, stdout, stderr)
	case cmdInviteList:
		runErr = runInviteList(ctx, st, commandArgs, stdout, stderr)
	case cmdInviteRevoke:
		runErr = runInviteRevoke(ctx, st, commandArgs, stdout, stderr)
	case cmdInviteCheck:
		runErr = runInviteCheck(ctx, st, commandArgs, stdout, stderr)
	case cmdDeviceList:
		runErr = runDeviceList(ctx, st, commandArgs, stdout, stderr)
	case cmdDeviceRevoke:
		runErr = runDeviceRevoke(ctx, st, commandArgs, stdout, stderr)
	case cmdDeviceHygiene:
		runErr = runDeviceHygiene(ctx, st, getenv, commandArgs, stdout, stderr)
	case cmdEnrollments:
		runErr = runEnrollments(ctx, st, commandArgs, stdout, stderr)
	case cmdUsage:
		runErr = runUsage(ctx, st, commandArgs, stdout, stderr)
	case cmdPurge:
		runErr = runPurge(ctx, st, commandArgs, stdout, stderr)
	case cmdPushTest:
		runErr = runPushTest(ctx, st, getenv, commandArgs, stdout, stderr)
	case cmdOpsReport:
		runErr = runOpsReport(ctx, st, commandArgs, stdout, stderr)
	case cmdFeedbackList:
		runErr = runFeedbackList(ctx, st, commandArgs, stdout, stderr)
	case cmdFeedbackShow:
		runErr = runFeedbackShow(ctx, st, commandArgs, stdout, stderr)
	case cmdFeedbackReply:
		runErr = runFeedbackReply(ctx, st, commandArgs, stdout, stderr)
	case cmdFeedbackNotify:
		runErr = runFeedbackNotify(ctx, st, commandArgs, stdout, stderr)
	case cmdFeedbackDelete:
		runErr = runFeedbackDelete(ctx, st, commandArgs, stdout, stderr)
	}
	if runErr != nil {
		// 已经打印过 JSON 结论的失败：只设退出码，不重复一条 stderr。
		var soft reported
		if errors.As(runErr, &soft) {
			return 1
		}
		var usageErr usageError
		if errors.As(runErr, &usageErr) {
			fmt.Fprintf(stderr, "dsh-relay admin %s: %v\n", command, runErr)
			return 2
		}
		fmt.Fprintf(stderr, "dsh-relay admin: %v\n", runErr)
		return 1
	}
	return 0
}

// usageError 标记"参数用法错误"（退出码 2），与业务错误（1）区分。
type usageError struct{ message string }

func (e usageError) Error() string { return e.message }

func newUsageError(format string, args ...any) error {
	return usageError{message: fmt.Sprintf(format, args...)}
}

// parseGlobal 解析子命令之前的全局参数，返回库路径与剩余参数。
func parseGlobal(args []string, getenv func(string) string) (string, []string, error) {
	dbPath := getenv(config.EnvDB)
	if dbPath == "" {
		dbPath = config.DefaultDBPath()
	}
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch {
		case arg == "--db":
			if index+1 >= len(args) {
				return "", nil, errors.New("--db 需要一个路径")
			}
			dbPath = args[index+1]
			index++
		case strings.HasPrefix(arg, "--db="):
			dbPath = strings.TrimPrefix(arg, "--db=")
		case arg == "-h", arg == "--help":
			// 把帮助交给子命令分支处理。
			return dbPath, []string{arg}, nil
		case len(arg) > 0 && arg[0] == '-':
			return "", nil, fmt.Errorf("未知全局参数 %q（--db 要写在子命令之前）", arg)
		default:
			return dbPath, args[index:], nil
		}
	}
	return dbPath, nil, nil
}

// usage 打印 admin 的用法。
func usage(w io.Writer) {
	fmt.Fprintln(w, "用法: dsh-relay admin --db <path> <子命令> [参数]")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "子命令:")
	fmt.Fprintln(w, "  account-create  --name <名字>")
	fmt.Fprintln(w, "  account-list")
	fmt.Fprintln(w, "  agent-register  --account <accountId> --name <名字> [--agent <agentId>] [--relay <url>] [--write-config <path>]")
	fmt.Fprintln(w, "  agent-rotate    --agent <agentId> [--name <名字>] [--relay <url>] [--write-config <path>]")
	fmt.Fprintln(w, "  agent-list      [--account <accountId>]")
	fmt.Fprintln(w, "  agent-disable   --agent <agentId>")
	fmt.Fprintln(w, "  agent-enable    --agent <agentId>")
	fmt.Fprintln(w, "  code-mint       --agent <agentId> [--ttl-seconds 600] [--relay <url>]")
	fmt.Fprintln(w, "  invite-mint     [--ttl-seconds 604800] [--note <备注>] [--relay <url>] [--count 1]")
	fmt.Fprintln(w, "  invite-list     [--all]")
	fmt.Fprintln(w, "  invite-revoke   --code <邀请码>")
	fmt.Fprintln(w, "  invite-check    [--code <邀请码> ...] [--stdin]")
	fmt.Fprintln(w, "  device-list     [--agent <agentId>] [--all]")
	fmt.Fprintln(w, "  device-revoke   (--device <deviceId> | --token <设备令牌>)")
	fmt.Fprintln(w, "  device-hygiene  [--agent <agentId>]")
	fmt.Fprintln(w, "  enrollments")
	fmt.Fprintln(w, "  usage           [--days 7] [--by account|device]")
	fmt.Fprintln(w, "  purge           [--json]")
	fmt.Fprintln(w, "  push-test       --device <deviceId> [--kind turnEnd|attention] [--sid push-test]")
	fmt.Fprintln(w, "  ops-report      [--days 30] [--as-of now|yesterday|YYYY-MM-DD] [--journal-unit dsh-relay]")
	fmt.Fprintln(w, "  alert-dispatch  --alert-dir <目录> --account <accountId> --mail-db <路径> --mail-admin <路径> --mail-python <路径> [--format text|html] [--dry-run]")
	fmt.Fprintln(w, "  feedback-list   [--status open|replied|all] [--limit 50] [--since DAYS]")
	fmt.Fprintln(w, "  feedback-show   --thread <threadId>")
	fmt.Fprintln(w, "  feedback-reply  --thread <threadId> (--body <正文> | --body-file <路径>) [--subject <主题>] [--format text|html]")
	fmt.Fprintln(w, "  feedback-reply  --template [--signature <署名>]")
	fmt.Fprintln(w, "  feedback-notify (--body <正文> | --body-file <路径>) (--account <accountId> ... | --all) [--subject <主题>] [--format text|html] [--yes]")
	fmt.Fprintln(w, "  feedback-delete --thread <threadId> [--yes]")
}

// emit 输出一份带缩进的 JSON（与 admin.py 的 indent=2 一致）。
//
// 不转义 HTML 字符：Python 默认也不转义，两版输出可直接用 diff 对比。
func emit(w io.Writer, value any) error {
	encoder := json.NewEncoder(w)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

// resolveAgent 按 agentId 或唯一的名字找一台电脑（Python admin._resolve_agent）。
func resolveAgent(ctx context.Context, st *store.Store, raw string) (store.Agent, error) {
	agent, ok, err := st.AgentByID(ctx, raw)
	if err != nil {
		return store.Agent{}, err
	}
	if ok {
		return agent, nil
	}
	agents, err := st.ListAgents(ctx, "")
	if err != nil {
		return store.Agent{}, err
	}
	var matches []store.Agent
	for _, candidate := range agents {
		if candidate.Name == raw {
			matches = append(matches, candidate)
		}
	}
	if len(matches) == 1 {
		return matches[0], nil
	}
	return store.Agent{}, fmt.Errorf("no agent matches %q", raw)
}

// writeAgentConfig 写连接器身份文件（mode 0600），与 admin.py 的 _write_config 一致。
func writeAgentConfig(path, relay string, agent store.Agent, secret string) error {
	payload := struct {
		RelayURL    string `json:"relayUrl"`
		AgentID     string `json:"agentId"`
		AgentSecret string `json:"agentSecret"`
		AgentName   string `json:"agentName"`
	}{RelayURL: relay, AgentID: agent.AgentID, AgentSecret: secret, AgentName: agent.Name}

	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("创建目录 %s: %w", dir, err)
		}
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("写身份文件 %s: %w", path, err)
	}
	encoder := json.NewEncoder(file)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	writeErr := encoder.Encode(payload)
	closeErr := file.Close()
	// 已有的文件不会被 OpenFile 的 mode 改写，显式再收一次权限。
	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("设置身份文件权限 %s: %w", path, err)
	}
	if writeErr != nil {
		return fmt.Errorf("写身份文件 %s: %w", path, writeErr)
	}
	if closeErr != nil {
		return fmt.Errorf("写身份文件 %s: %w", path, closeErr)
	}
	return nil
}

// requireFlag 是"必填参数"的统一检查（argparse 的 required=True 行为）。
func requireFlag(name, value string) error {
	if value == "" {
		return newUsageError("缺少必填参数 --%s", name)
	}
	return nil
}

// percentEncode 复刻 Python urllib.parse.quote(value, safe="")：
// 只保留 A-Za-z0-9_.-~，其余按 UTF-8 字节写成 %XX（大写）。
func percentEncode(value string) string {
	const upper = "0123456789ABCDEF"
	var out []byte
	for index := 0; index < len(value); index++ {
		ch := value[index]
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
			(ch >= '0' && ch <= '9') || ch == '_' || ch == '.' ||
			ch == '-' || ch == '~' {
			out = append(out, ch)
			continue
		}
		out = append(out, '%', upper[ch>>4], upper[ch&0x0f])
	}
	return string(out)
}

// qrPayload 是 iOS App 扫的 dsh://pair?relay=...&code=... 深链。
func qrPayload(relay, code string) string {
	return "dsh://pair?relay=" + percentEncode(relay) + "&code=" + percentEncode(code)
}

// enrollCommand 是收到邀请码的人在自己电脑上跑的那一条命令。
func enrollCommand(relay, code string) string {
	return fmt.Sprintf("dsh-mobile-link enroll --invite %s --relay %s", code, relay)
}

// AlertDispatch 是 `dsh-relay alert-dispatch`（运维 timer）的入口。
//
// 与 `dsh-relay admin alert-dispatch` 共用同一份 runAlertDispatch：运维 timer 与
// 手工排障不可能给出两种投递语义。退出码：0 成功、2 用法错误、3 投递失败。
func AlertDispatch(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	if err := runAlertDispatch(args, getenv, stdout, stderr); err != nil {
		var usageErr usageError
		if errors.As(err, &usageErr) {
			fmt.Fprintf(stderr, "dsh-relay alert-dispatch: %v\n", err)
			return 2
		}
		fmt.Fprintf(stderr, "dsh-relay alert-dispatch: %v\n", err)
		return 3
	}
	return 0
}
