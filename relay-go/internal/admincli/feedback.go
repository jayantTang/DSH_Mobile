package admincli

import (
	"context"
	"flag"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/opsreport"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 反馈通道的 owner 侧命令（014）：读清单、看一条线程、回信、群发通知、删线程。
//
// JSON 输出字段固定：黑盒用例按字段名断言，运维脚本也按它们
// 取值。SQL 与业务规则都在 store 里，这里只做参数解析、校验顺序与输出。

// defaultReplySignature 是 `feedback-reply --template` 的默认署名。
const defaultReplySignature = "DSH Mobile 团队"

// reported 表示"结论已经作为 JSON 打到 stdout，退出码 1"。
//
// Python 的 `_emit({"ok": False, ...}); return 1` 是这种形态：人要看的是 JSON，
// 不是一条重复的 stderr。Main 见到它只设退出码，不再打印错误。
type reported struct{}

func (reported) Error() string { return "already reported" }

// feedbackShowOutput 是 feedback-show 的完整线程（列序与表结构一致）。
type feedbackShowOutput struct {
	ThreadID      string                  `json:"threadId"`
	TicketHash    string                  `json:"ticketHash"`
	AccountID     *string                 `json:"accountId"`
	DeviceID      *string                 `json:"deviceId"`
	AppVersion    *string                 `json:"appVersion"`
	DeviceModel   *string                 `json:"deviceModel"`
	SystemVersion *string                 `json:"systemVersion"`
	CreatedAt     int64                   `json:"createdAt"`
	LastMessageAt int64                   `json:"lastMessageAt"`
	OwnerReadAt   *int64                  `json:"ownerReadAt"`
	UserReadAt    *int64                  `json:"userReadAt"`
	Status        string                  `json:"status"`
	ClientRef     *string                 `json:"clientRef"`
	Subject       *string                 `json:"subject"`
	Messages      []store.FeedbackMessage `json:"messages"`
	MessageCount  int                     `json:"messageCount"`
	Unread        int                     `json:"unread"`
}

// 下面这些输出结构体的键序固定：运维会拿两版命令做 diff，
// 键序不同会让 diff 变得难读（语义上 JSON 对象无序，这里只是把噪声去掉）。

type feedbackMissingOutput struct {
	OK    bool   `json:"ok"`
	Error string `json:"error"`
}

type feedbackReplyOutput struct {
	OK        bool   `json:"ok"`
	ThreadID  string `json:"threadId"`
	MessageID string `json:"messageId"`
	CreatedAt int64  `json:"createdAt"`
}

type feedbackNoRecipientsOutput struct {
	OK         bool     `json:"ok"`
	Error      string   `json:"error"`
	Recipients int      `json:"recipients"`
	Accounts   []string `json:"accounts"`
}

type feedbackNotifyPreview struct {
	OK         bool     `json:"ok"`
	DryRun     bool     `json:"dryRun"`
	Recipients int      `json:"recipients"`
	Accounts   []string `json:"accounts"`
}

type feedbackNotifyOutput struct {
	OK         bool   `json:"ok"`
	NoticeID   string `json:"noticeId"`
	Recipients int    `json:"recipients"`
	CreatedAt  int64  `json:"createdAt"`
}

type feedbackDeletePreview struct {
	OK       bool   `json:"ok"`
	DryRun   bool   `json:"dryRun"`
	ThreadID string `json:"threadId"`
	Exists   bool   `json:"exists"`
	Messages int    `json:"messages"`
}

type feedbackDeleteOutput struct {
	OK       bool   `json:"ok"`
	ThreadID string `json:"threadId"`
	Deleted  bool   `json:"deleted"`
	Messages int64  `json:"messages"`
}

// stringListFlag 是"可以重复给"的参数（Python 的 action="append"）。
type stringListFlag []string

func (s *stringListFlag) String() string { return strings.Join(*s, ",") }

func (s *stringListFlag) Set(value string) error {
	*s = append(*s, value)
	return nil
}

// flagWasSet 报告某个参数是否在命令行上出现过（argparse 的"缺省 None"判据）。
func flagWasSet(fs *flag.FlagSet, name string) bool {
	found := false
	fs.Visit(func(visited *flag.Flag) {
		if visited.Name == name {
			found = true
		}
	})
	return found
}

// runFeedbackList 实现 feedback-list [--status] [--limit] [--since]。
func runFeedbackList(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdFeedbackList, stderr)
	status := fs.String("status", "all", "open / replied / all")
	limit := fs.Int("limit", 50, "最多几行")
	since := fs.Int("since", 0, "只看最近 DAYS 天创建的线程")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	var statusValue *string
	switch *status {
	case "all":
	case "open", "replied":
		statusValue = status
	default:
		return newUsageError("--status 必须是 open / replied / all")
	}

	var sinceMS *int64
	if flagWasSet(fs, "since") {
		days := *since
		if days < 1 {
			days = 1
		}
		value := store.NowMS() - int64(days)*86_400_000
		sinceMS = &value
	}

	rows, err := opsreport.FeedbackRows(ctx, st, statusValue, sinceMS, maxInt(*limit, 1))
	if err != nil {
		return err
	}
	return emit(stdout, rows)
}

// runFeedbackShow 实现 feedback-show --thread：看全文并把 ownerReadAt 推到最新一条
// 用户留言（"owner 已看过"只有这一个落点）。
func runFeedbackShow(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdFeedbackShow, stderr)
	threadRef := fs.String("thread", "", "线程 ID")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	if err := requireFlag("thread", *threadRef); err != nil {
		return err
	}

	head, err := st.FeedbackThread(ctx, *threadRef, nil, 0)
	if err != nil {
		return err
	}
	if head == nil {
		if err := emit(stdout, feedbackMissingOutput{OK: false, Error: "thread not found"}); err != nil {
			return err
		}
		return reported{}
	}
	thread, err := st.FeedbackThread(ctx, *threadRef, nil, maxInt(head.MessageCount, 1))
	if err != nil {
		return err
	}
	if thread == nil {
		if err := emit(stdout, feedbackMissingOutput{OK: false, Error: "thread not found"}); err != nil {
			return err
		}
		return reported{}
	}

	output := feedbackShowOutput{
		ThreadID: thread.ThreadID, TicketHash: opsreport.MaskPrefix(thread.TicketHash, 12),
		AccountID: thread.AccountID, DeviceID: thread.DeviceID,
		AppVersion: thread.AppVersion, DeviceModel: thread.DeviceModel,
		SystemVersion: thread.SystemVersion, CreatedAt: thread.CreatedAt,
		LastMessageAt: thread.LastMessageAt, OwnerReadAt: thread.OwnerReadAt,
		UserReadAt: thread.UserReadAt, Status: thread.Status, ClientRef: thread.ClientRef,
		Subject: thread.Subject, Messages: thread.Messages,
		MessageCount: thread.MessageCount, Unread: thread.Unread,
	}
	// 只前进不后退：回信之后再看一眼，不该把时间拨回去。
	var latestUser *int64
	for _, message := range thread.Messages {
		if message.Author != "user" {
			continue
		}
		createdAt := message.CreatedAt
		if latestUser == nil || createdAt > *latestUser {
			latestUser = &createdAt
		}
	}
	if latestUser != nil && (head.OwnerReadAt == nil || *latestUser > *head.OwnerReadAt) {
		if _, err := st.TouchOwnerRead(ctx, thread.ThreadID, *latestUser); err != nil {
			return err
		}
		output.OwnerReadAt = latestUser
	}
	return emit(stdout, output)
}

// runFeedbackReply 实现 feedback-reply：以 owner 身份回一封信（可顺带换主题）。
func runFeedbackReply(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdFeedbackReply, stderr)
	threadRef := fs.String("thread", "", "线程 ID")
	body := fs.String("body", "", "回信正文（原样入库）")
	bodyFile := fs.String("body-file", "", "从文件读正文")
	subject := fs.String("subject", "", "替换线程主题（≤80 字符；空白清空）")
	format := fs.String("format", store.DefaultFeedbackFormat, "text / html")
	template := fs.Bool("template", false, "打印官方骨架，不写库")
	signature := fs.String("signature", defaultReplySignature, "骨架里的署名")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	cleanedFormat, err := store.CleanFeedbackFormat(*format)
	if err != nil {
		// argparse 的 choices 是用法错误（退出码 2），不是业务错误。
		return newUsageError("--format 必须是 text 或 html")
	}
	if *template {
		_, err := io.WriteString(stdout, replyTemplate(*signature))
		return err
	}
	if *threadRef == "" {
		return &store.StoreError{Message: "feedback-reply 需要 --thread（或者 --template）"}
	}

	// 两个入参都先校验再动库：正文缺/空白、主题超长都在写信之前拒绝，
	// 不能写完半封才报错（那封信已经进库了）。
	letter, err := readLetter(fs, *body, *bodyFile)
	if err != nil {
		return err
	}
	if flagWasSet(fs, "subject") {
		// 线程不存在时这里是 false；下面的 append 同样返回 nil，报的还是 not found。
		if _, err := st.SetFeedbackSubject(ctx, *threadRef, subject); err != nil {
			return err
		}
	}
	written, err := st.AppendFeedbackMessage(ctx, store.AppendFeedbackInput{
		ThreadID: *threadRef, Body: letter, Author: "owner", Format: cleanedFormat,
	})
	if err != nil {
		return err
	}
	if written == nil {
		if err := emit(stdout, feedbackMissingOutput{OK: false, Error: "thread not found"}); err != nil {
			return err
		}
		return reported{}
	}
	return emit(stdout, feedbackReplyOutput{
		OK: true, ThreadID: *threadRef, MessageID: written.MessageID,
		CreatedAt: written.CreatedAt,
	})
}

// runFeedbackNotify 实现 feedback-notify：给账号发一条通知（默认只预演）。
func runFeedbackNotify(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdFeedbackNotify, stderr)
	body := fs.String("body", "", "通知正文")
	bodyFile := fs.String("body-file", "", "从文件读正文")
	subject := fs.String("subject", "", "通知主题")
	format := fs.String("format", store.DefaultFeedbackFormat, "text / html")
	var accounts stringListFlag
	fs.Var(&accounts, "account", "accountId（可重复）")
	all := fs.Bool("all", false, "发给全部账号（必须显式给出）")
	yes := fs.Bool("yes", false, "真的写库")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	cleanedFormat, err := store.CleanFeedbackFormat(*format)
	if err != nil {
		return newUsageError("--format 必须是 text 或 html")
	}

	letter, err := readLetter(fs, *body, *bodyFile)
	if err != nil {
		return err
	}
	targets, err := notifyAccounts(ctx, st, accounts, *all)
	if err != nil {
		return err
	}
	if len(targets) == 0 {
		// 没有收件人时**连 --yes 也不写库**：留下一条发给零个账号的通知，
		// 会让"发送记录"从此撒谎。
		if err := emit(stdout, feedbackNoRecipientsOutput{
			OK: false, Error: "no recipients", Recipients: 0, Accounts: []string{},
		}); err != nil {
			return err
		}
		return reported{}
	}
	if !*yes {
		return emit(stdout, feedbackNotifyPreview{
			OK: true, DryRun: true, Recipients: len(targets), Accounts: targets,
		})
	}
	var subjectValue *string
	if flagWasSet(fs, "subject") {
		subjectValue = subject
	}
	notice, err := st.CreateNotice(ctx, store.CreateNoticeInput{
		Body: letter, Subject: subjectValue, AccountIDs: targets,
		Format: cleanedFormat, CreatedBy: stringPtrValue("admin.py"),
	})
	if err != nil {
		return err
	}
	return emit(stdout, feedbackNotifyOutput{
		OK: true, NoticeID: notice.NoticeID, Recipients: notice.Recipients,
		CreatedAt: notice.CreatedAt,
	})
}

// runFeedbackDelete 实现 feedback-delete：删线程与它的全部留言（需要 --yes）。
func runFeedbackDelete(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdFeedbackDelete, stderr)
	threadRef := fs.String("thread", "", "线程 ID")
	yes := fs.Bool("yes", false, "真的删除")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	if err := requireFlag("thread", *threadRef); err != nil {
		return err
	}

	thread, err := st.FeedbackThread(ctx, *threadRef, nil, 0)
	if err != nil {
		return err
	}
	if thread == nil {
		if err := emit(stdout, feedbackMissingOutput{OK: false, Error: "thread not found"}); err != nil {
			return err
		}
		return reported{}
	}
	if !*yes {
		return emit(stdout, feedbackDeletePreview{
			OK: true, DryRun: true, ThreadID: *threadRef, Exists: true,
			Messages: thread.MessageCount,
		})
	}
	removed, err := st.DeleteFeedbackThread(ctx, *threadRef)
	if err != nil {
		return err
	}
	return emit(stdout, feedbackDeleteOutput{
		OK: true, ThreadID: *threadRef, Deleted: true, Messages: removed,
	})
}

// readLetter 取命令的正文：恰好一个来源，且去首尾空白后非空。
func readLetter(fs *flag.FlagSet, body, bodyFile string) (string, error) {
	bodyGiven := flagWasSet(fs, "body")
	fileGiven := flagWasSet(fs, "body-file")
	if bodyGiven == fileGiven {
		return "", &store.StoreError{Message: "pass exactly one of --body or --body-file"}
	}
	letter := body
	if fileGiven {
		raw, err := os.ReadFile(bodyFile)
		if err != nil {
			return "", &store.StoreError{Message: "cannot read --body-file: " + err.Error()}
		}
		letter = string(raw)
	}
	if strings.TrimSpace(letter) == "" {
		return "", &store.StoreError{Message: "正文去掉首尾空白后为空，服务端会拒收这条"}
	}
	return letter, nil
}

// notifyAccounts 是通知的收件账号：--account 点名，或**显式** --all。
//
// 点名一个不存在的账号是错误，不静默丢弃：打错一个 accountId 却看到"发出去了"
// 是最糟的结果。两个都不给也是错误——全量群发必须显式写下来。
func notifyAccounts(ctx context.Context, st *store.Store, accounts []string,
	all bool) ([]string, error) {
	if len(accounts) > 0 {
		wanted := dedupeStrings(accounts)
		unknown := make([]string, 0)
		for _, accountID := range wanted {
			_, found, err := st.GetAccount(ctx, accountID)
			if err != nil {
				return nil, err
			}
			if !found {
				unknown = append(unknown, accountID)
			}
		}
		if len(unknown) > 0 {
			return nil, &store.StoreError{Message: "这些账号不存在：" + strings.Join(unknown, ", ")}
		}
		return wanted, nil
	}
	if !all {
		return nil, &store.StoreError{
			Message: "必须点名收件人：--account <accountId>（可重复），或显式 --all 发给全部账号",
		}
	}
	allAccounts, err := st.ListAccounts(ctx)
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(allAccounts))
	for _, account := range allAccounts {
		ids = append(ids, account.AccountID)
	}
	return ids, nil
}

// replyTemplate 是官方回信骨架：称呼 / 正文 / 署名 / 日期四部分（打印，不写库）。
func replyTemplate(signature string) string {
	day := strconv.FormatInt(store.LocalDay(), 10)
	date := day
	if len(day) == 8 {
		date = day[:4] + "-" + day[4:6] + "-" + day[6:]
	} else {
		// 本地日序号不是 8 位（理论上不会发生）：保留原样，不编造日期。
		date = time.Now().Format("2006-01-02")
	}
	return "<对用户的称呼>：\n" +
		"\n" +
		"<回信正文：先说结论，再说下一步>\n" +
		"\n" +
		signature + "\n" +
		date + "\n"
}

// dedupeStrings 去空并保序去重。
func dedupeStrings(values []string) []string {
	out := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		if value == "" {
			continue
		}
		if _, done := seen[value]; done {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out
}

// stringPtrValue 是"一定存在的字符串"取地址（admin 内部的来源标记）。
func stringPtrValue(value string) *string { return &value }

// maxInt 返回两个整数里较大的一个。
func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}
