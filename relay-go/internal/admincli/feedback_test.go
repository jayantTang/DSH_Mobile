package admincli

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// owner 侧反馈命令的用例：JSON 字段、摘要素材、回信与通知的校验顺序、删除的预演。

// seedThread 直接在库里写一条线程（admin 与 serve 共用 schema）。
func seedThread(t *testing.T, dbPath string, in store.CreateFeedbackThreadInput) store.CreatedFeedbackThread {
	t.Helper()
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer st.Close()
	created, err := st.CreateFeedbackThread(context.Background(), in)
	if err != nil {
		t.Fatalf("CreateFeedbackThread: %v", err)
	}
	return created
}

// appendMessage 在已有的库里补一条留言。
func appendMessage(t *testing.T, dbPath string, in store.AppendFeedbackInput) {
	t.Helper()
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer st.Close()
	if _, err := st.AppendFeedbackMessage(context.Background(), in); err != nil {
		t.Fatalf("AppendFeedbackMessage: %v", err)
	}
}

// seedNotice 在已有的库里发一条通知。
func seedNotice(t *testing.T, dbPath string, in store.CreateNoticeInput) store.CreatedNotice {
	t.Helper()
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer st.Close()
	notice, err := st.CreateNotice(context.Background(), in)
	if err != nil {
		t.Fatalf("CreateNotice: %v", err)
	}
	return notice
}

func TestFeedbackListReportsTheFieldsTheOwnerReads(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	created := seedThread(t, dbPath, store.CreateFeedbackThreadInput{
		TicketHash: "hash-only", Text: "手机上的反馈正文",
		Subject: stringPtr("设备来源"), AppVersion: stringPtr("9.9.9 (100)"),
		DeviceModel: stringPtr("iPhone17,1"), SystemVersion: stringPtr("26.0"),
		DeviceID: stringPtr("dev_1"), AccountID: stringPtr("acc_1"), At: 1_000,
	})

	code, out, errOut := runAdmin(dbPath, "feedback-list", "--status", "open")
	if code != 0 {
		t.Fatalf("feedback-list 退出码 = %d, stderr = %s", code, errOut)
	}
	var rows []map[string]any
	if err := decodeJSONList(t, out, &rows); err != nil {
		t.Fatalf("解析清单: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("清单应有 1 行：%v", rows)
	}
	row := rows[0]
	if row["threadId"] != created.ThreadID || row["status"] != "open" ||
		row["messages"] != float64(1) || row["ownerUnread"] != float64(1) {
		t.Fatalf("清单字段不对：%v", row)
	}
	if row["subject"] != "设备来源" || row["excerpt"] != "手机上的反馈正文" ||
		row["format"] != "text" {
		t.Fatalf("摘要字段不对：%v", row)
	}
	if row["createdAt"] != float64(1_000) || row["lastMessageAt"] != float64(1_000) {
		t.Fatalf("时间戳不对：%v", row)
	}
	source := row["source"].(map[string]any)
	want := map[string]any{
		"kind": "device", "deviceId": "dev_1", "accountId": "acc_1",
		"deviceModel": "iPhone17,1", "appVersion": "9.9.9 (100)", "systemVersion": "26.0",
	}
	for key, value := range want {
		if source[key] != value {
			t.Fatalf("source.%s = %v, 期望 %v", key, source[key], value)
		}
	}

	// feedback-show：看全文即已读，凭据哈希打码。
	code, out, errOut = runAdmin(dbPath, "feedback-show", "--thread", created.ThreadID)
	if code != 0 {
		t.Fatalf("feedback-show 退出码 = %d, stderr = %s", code, errOut)
	}
	shown := decodeOutput(t, out)
	if shown["threadId"] != created.ThreadID {
		t.Fatalf("show.threadId = %v", shown["threadId"])
	}
	if shown["ticketHash"] != "hash-only…" {
		t.Fatalf("凭据哈希应打码：%v", shown["ticketHash"])
	}
	if shown["ownerReadAt"] != float64(1_000) {
		t.Fatalf("看过之后 ownerReadAt 应推到最新一条用户留言：%v", shown["ownerReadAt"])
	}
	messages := shown["messages"].([]any)
	if len(messages) != 1 || messages[0].(map[string]any)["author"] != "user" {
		t.Fatalf("留言不对：%v", messages)
	}
	if _, ok := messages[0].(map[string]any)["format"]; !ok {
		t.Fatalf("每条留言应自带 format")
	}

	code, out, _ = runAdmin(dbPath, "feedback-list")
	if code != 0 {
		t.Fatalf("feedback-list 退出码 = %d", code)
	}
	rows = nil
	if err := decodeJSONList(t, out, &rows); err != nil {
		t.Fatalf("解析清单: %v", err)
	}
	if rows[0]["ownerUnread"] != float64(0) {
		t.Fatalf("feedback-show 看过即已读：%v", rows[0]["ownerUnread"])
	}
}

func TestFeedbackListFiltersLimitsAndTruncatesTheExcerpt(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	body := strings.Repeat("中", 100)
	old := seedThread(t, dbPath, store.CreateFeedbackThreadInput{
		TicketHash: "hash-old", Text: body, At: store.NowMS() - 3*86_400_000,
	})
	fresh := seedThread(t, dbPath, store.CreateFeedbackThreadInput{
		TicketHash: "hash-fresh", Text: "新的", At: store.NowMS(),
	})
	appendMessage(t, dbPath, store.AppendFeedbackInput{
		ThreadID: old.ThreadID, Body: "刚补充的", At: store.NowMS() + 1_000})

	code, out, errOut := runAdmin(dbPath, "feedback-list", "--since", "1")
	if code != 0 {
		t.Fatalf("feedback-list 退出码 = %d, stderr = %s", code, errOut)
	}
	var rows []map[string]any
	if err := decodeJSONList(t, out, &rows); err != nil {
		t.Fatalf("解析清单: %v", err)
	}
	if len(rows) != 1 || rows[0]["threadId"] != fresh.ThreadID {
		t.Fatalf("--since 1 应只留最近一天创建的线程：%v", rows)
	}

	code, out, _ = runAdmin(dbPath, "feedback-list", "--limit", "1")
	if code != 0 {
		t.Fatalf("feedback-list 退出码 = %d", code)
	}
	rows = nil
	if err := decodeJSONList(t, out, &rows); err != nil {
		t.Fatalf("解析清单: %v", err)
	}
	if len(rows) != 1 || rows[0]["threadId"] != old.ThreadID {
		t.Fatalf("清单按最近活动倒序，limit 应生效：%v", rows)
	}
	excerpt, _ := rows[0]["excerpt"].(string)
	if len([]rune(excerpt)) != 80 || !strings.HasPrefix(body, excerpt) {
		t.Fatalf("摘要应是首条留言的前 80 个字符：%q（%d）", excerpt, len([]rune(excerpt)))
	}
}

func TestFeedbackReplyStoresTheLetterAndFlipsTheStatus(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	created := seedThread(t, dbPath, store.CreateFeedbackThreadInput{
		TicketHash: "hash-one", Text: "我在设置页找不到退出登录", Subject: stringPtr("原主题"),
		At: 1_000,
	})

	code, out, errOut := runAdmin(dbPath, "feedback-reply", "--thread", created.ThreadID,
		"--body", "退出登录在设置最下面，下一版会加搜索。", "--subject", "退出登录的位置")
	if code != 0 {
		t.Fatalf("feedback-reply 退出码 = %d, stderr = %s", code, errOut)
	}
	reply := decodeOutput(t, out)
	if reply["ok"] != true || reply["threadId"] != created.ThreadID {
		t.Fatalf("回信输出：%v", reply)
	}
	if messageID, _ := reply["messageId"].(string); !strings.HasPrefix(messageID, "fm_") {
		t.Fatalf("messageId = %v", reply["messageId"])
	}

	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer st.Close()
	thread, err := st.FeedbackThread(context.Background(), created.ThreadID, nil, 50)
	if err != nil || thread == nil {
		t.Fatalf("读线程: %v %v", thread, err)
	}
	if thread.Status != "replied" || thread.Subject == nil || *thread.Subject != "退出登录的位置" {
		t.Fatalf("回信后状态/主题不对：%+v", thread)
	}
	if len(thread.Messages) != 2 || thread.Messages[1].Author != "owner" ||
		thread.Messages[1].Body != "退出登录在设置最下面，下一版会加搜索。" ||
		thread.Messages[1].Format != "text" {
		t.Fatalf("回信留言不对：%+v", thread.Messages)
	}

	// 线程不存在：JSON 结论 + 退出码 1，不重复 stderr。
	code, out, _ = runAdmin(dbPath, "feedback-reply", "--thread", "th_nope", "--body", "x")
	if code != 1 {
		t.Fatalf("缺线程的退出码 = %d", code)
	}
	missing := decodeOutput(t, out)
	if missing["ok"] != false || missing["error"] != "thread not found" {
		t.Fatalf("缺线程输出：%v", missing)
	}
}

func TestFeedbackReplyValidatesTheLetterBeforeWriting(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	created := seedThread(t, dbPath, store.CreateFeedbackThreadInput{
		TicketHash: "hash-one", Text: "原文", At: 1_000,
	})

	cases := [][]string{
		{"feedback-reply", "--thread", created.ThreadID},
		{"feedback-reply", "--thread", created.ThreadID, "--body", "   "},
		{"feedback-reply", "--thread", created.ThreadID, "--body", "x", "--body-file", "/dev/null"},
	}
	for _, args := range cases {
		code, _, errOut := runAdmin(dbPath, args...)
		if code != 1 {
			t.Fatalf("%v 的退出码 = %d（stderr=%s）", args, code, errOut)
		}
		if strings.TrimSpace(errOut) == "" {
			t.Fatalf("%v 应在 stderr 说明原因", args)
		}
	}

	// 非法格式是用法错误（argparse 的 choices → 退出码 2），且不写库。
	code, _, _ := runAdmin(dbPath, "feedback-reply", "--thread", created.ThreadID,
		"--body", "x", "--format", "rtf")
	if code != 2 {
		t.Fatalf("非法格式的退出码 = %d", code)
	}
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer st.Close()
	thread, _ := st.FeedbackThread(context.Background(), created.ThreadID, nil, 50)
	if thread.MessageCount != 1 || thread.Status != "open" {
		t.Fatalf("校验失败不该写半封信：%+v", thread)
	}
}

func TestFeedbackReplyTemplatePrintsTheFourParts(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	code, out, errOut := runAdmin(dbPath, "feedback-reply", "--template")
	if code != 0 {
		t.Fatalf("--template 退出码 = %d, stderr = %s", code, errOut)
	}
	for _, part := range []string{"<对用户的称呼>：", "<回信正文：先说结论，再说下一步>",
		defaultReplySignature} {
		if !strings.Contains(out, part) {
			t.Fatalf("骨架缺 %q：%s", part, out)
		}
	}
	if !strings.Contains(out, storeDateText()) {
		t.Fatalf("骨架应带当天日期（%s）：%s", storeDateText(), out)
	}
}

func TestFeedbackNotifyRequiresAnExplicitRecipient(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")

	code, _, errOut := runAdmin(dbPath, "feedback-notify", "--body", "通知正文")
	if code != 1 || !strings.Contains(errOut, "必须点名收件人") {
		t.Fatalf("不给收件人应报错：code=%d stderr=%s", code, errOut)
	}

	code, _, errOut = runAdmin(dbPath, "feedback-notify", "--body", "通知正文",
		"--account", "acc_nope")
	if code != 1 || !strings.Contains(errOut, "这些账号不存在") {
		t.Fatalf("未知账号应报错：code=%d stderr=%s", code, errOut)
	}

	// --all 但库里一个账号都没有：不写一条"发给零个账号"的通知。
	code, out, _ := runAdmin(dbPath, "feedback-notify", "--body", "通知正文", "--all", "--yes")
	if code != 1 {
		t.Fatalf("没有收件人时退出码 = %d", code)
	}
	noRecipients := decodeOutput(t, out)
	if noRecipients["ok"] != false || noRecipients["error"] != "no recipients" ||
		noRecipients["recipients"] != float64(0) {
		t.Fatalf("无收件人输出：%v", noRecipients)
	}
}

func TestFeedbackNotifyPreviewsThenDeliversPerAccount(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	code, out, errOut := runAdmin(dbPath, "account-create", "--name", "收件账户")
	if code != 0 {
		t.Fatalf("account-create 退出码 = %d, stderr = %s", code, errOut)
	}
	accountID := decodeOutput(t, out)["accountId"].(string)

	code, out, errOut = runAdmin(dbPath, "feedback-notify", "--account", accountID,
		"--subject", "维护通知", "--body", "今晚 23:00 维护，约十分钟。")
	if code != 0 {
		t.Fatalf("预览退出码 = %d, stderr = %s", code, errOut)
	}
	preview := decodeOutput(t, out)
	if preview["ok"] != true || preview["dryRun"] != true ||
		preview["recipients"] != float64(1) {
		t.Fatalf("预览输出：%v", preview)
	}
	if accounts := preview["accounts"].([]any); len(accounts) != 1 || accounts[0] != accountID {
		t.Fatalf("预览收件人：%v", accounts)
	}
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	notices, err := st.NoticesForAccount(context.Background(), accountID, 200)
	st.Close()
	if err != nil || len(notices) != 0 {
		t.Fatalf("预览不该写库：%v %v", notices, err)
	}

	code, out, errOut = runAdmin(dbPath, "feedback-notify", "--account", accountID,
		"--subject", "维护通知", "--body", "今晚 23:00 维护，约十分钟。", "--yes")
	if code != 0 {
		t.Fatalf("发送退出码 = %d, stderr = %s", code, errOut)
	}
	sent := decodeOutput(t, out)
	if sent["ok"] != true || sent["recipients"] != float64(1) {
		t.Fatalf("发送输出：%v", sent)
	}
	noticeID, _ := sent["noticeId"].(string)
	if !strings.HasPrefix(noticeID, "nt_") {
		t.Fatalf("noticeId = %v", sent["noticeId"])
	}
	if _, ok := sent["createdAt"].(float64); !ok {
		t.Fatalf("createdAt 缺失：%v", sent)
	}

	// --all 是显式全量：一个账号时就发一条。
	code, out, _ = runAdmin(dbPath, "feedback-notify", "--body", "全量通知", "--all", "--yes")
	if code != 0 {
		t.Fatalf("--all 退出码 = %d", code)
	}
	if decodeOutput(t, out)["recipients"] != float64(1) {
		t.Fatalf("--all 应投给全部账号：%v", out)
	}
}

func TestFeedbackDeletePreviewsThenRemovesTheThread(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	created := seedThread(t, dbPath, store.CreateFeedbackThreadInput{
		TicketHash: "hash-one", Text: "原文", At: 1_000,
	})
	appendMessage(t, dbPath, store.AppendFeedbackInput{
		ThreadID: created.ThreadID, Body: "回信", Author: "owner", At: 2_000})

	code, out, errOut := runAdmin(dbPath, "feedback-delete", "--thread", created.ThreadID)
	if code != 0 {
		t.Fatalf("预演退出码 = %d, stderr = %s", code, errOut)
	}
	preview := decodeOutput(t, out)
	if preview["ok"] != true || preview["dryRun"] != true ||
		preview["exists"] != true || preview["messages"] != float64(2) {
		t.Fatalf("删除预演输出：%v", preview)
	}
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if thread, _ := st.FeedbackThread(context.Background(), created.ThreadID, nil, 0); thread == nil {
		st.Close()
		t.Fatal("预演不该删除线程")
	}
	st.Close()

	code, out, _ = runAdmin(dbPath, "feedback-delete", "--thread", created.ThreadID, "--yes")
	if code != 0 {
		t.Fatalf("删除退出码 = %d", code)
	}
	deleted := decodeOutput(t, out)
	if deleted["ok"] != true || deleted["deleted"] != true || deleted["messages"] != float64(2) {
		t.Fatalf("删除输出：%v", deleted)
	}
	st, err = store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer st.Close()
	if thread, _ := st.FeedbackThread(context.Background(), created.ThreadID, nil, 0); thread != nil {
		t.Fatal("--yes 之后线程应不存在")
	}

	code, out, _ = runAdmin(dbPath, "feedback-delete", "--thread", "th_nope")
	if code != 1 {
		t.Fatalf("缺线程的退出码 = %d", code)
	}
	if missing := decodeOutput(t, out); missing["error"] != "thread not found" {
		t.Fatalf("缺线程输出：%v", missing)
	}
}

// decodeJSONList 解析 admin 输出的 JSON 数组。
func decodeJSONList(t *testing.T, text string, target *[]map[string]any) error {
	t.Helper()
	if err := json.Unmarshal([]byte(text), target); err != nil {
		t.Fatalf("admin 输出不是 JSON 数组: %v (%q)", err, text)
	}
	return nil
}

// storeDateText 是回信骨架应带的日期文本（本地日，YYYY-MM-DD）。
func storeDateText() string {
	day := strconv.FormatInt(store.LocalDay(), 10)
	return day[:4] + "-" + day[4:6] + "-" + day[6:]
}

// stringPtr 给可空入参取地址（Python 侧的 None 就是这里的 nil）。
func stringPtr(value string) *string { return &value }
