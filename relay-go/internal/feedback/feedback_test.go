package feedback

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 反馈四端点的 HTTP 用例：校验矩阵、匿名口径、凭据语义、限流与已读。
//
// 全部走真实 handler + 真实 SQLite（临时库），不 mock 仓储层：限流命中"不写库"
// 这类断言必须看得见库里的行数。

type testAPI struct {
	t      *testing.T
	store  *store.Store
	router http.Handler
}

func newTestAPI(t *testing.T) *testAPI {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() {
		if err := st.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	handlers := New(Options{
		Store: st,
		ClientID: func(r *http.Request) string {
			return r.RemoteAddr
		},
	})
	mux := http.NewServeMux()
	handlers.Register(mux, "")
	return &testAPI{t: t, store: st, router: mux}
}

// do 发一次 JSON 请求；remote 是这个请求的来源（限流桶的键）。
func (a *testAPI) do(path string, body any, token, remote string) *httptest.ResponseRecorder {
	a.t.Helper()
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			a.t.Fatalf("序列化请求体: %v", err)
		}
		reader = bytes.NewReader(raw)
	}
	return a.doRaw(path, reader, token, remote)
}

func (a *testAPI) doRaw(path string, body io.Reader, token, remote string) *httptest.ResponseRecorder {
	a.t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, body)
	if remote == "" {
		remote = "198.51.100.7:5000"
	}
	req.RemoteAddr = remote
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	a.router.ServeHTTP(rec, req)
	return rec
}

func decodeJSON(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("响应不是 JSON 对象: %v (%s)", err, rec.Body.String())
	}
	return payload
}

func assertError(t *testing.T, rec *httptest.ResponseRecorder, status int, code string) {
	t.Helper()
	if rec.Code != status {
		t.Fatalf("状态码 = %d, 期望 %d：%s", rec.Code, status, rec.Body.String())
	}
	payload := decodeJSON(t, rec)
	if payload["ok"] != false {
		t.Fatalf("错误响应 ok = %v", payload["ok"])
	}
	body, ok := payload["error"].(map[string]any)
	if !ok || body["code"] != code {
		t.Fatalf("错误信封不对（期望 %s）：%v", code, payload)
	}
	if message, ok := body["message"].(string); !ok || message == "" {
		t.Fatalf("error.message 非法：%v", body["message"])
	}
}

// submit 建一条线程并返回响应体。
func (a *testAPI) submit(text string, extra map[string]any, token string) map[string]any {
	a.t.Helper()
	payload := map[string]any{"text": text}
	for key, value := range extra {
		payload[key] = value
	}
	rec := a.do("/feedback/submit", payload, token, "")
	if rec.Code != http.StatusOK {
		a.t.Fatalf("submit 失败：%d %s", rec.Code, rec.Body.String())
	}
	return decodeJSON(a.t, rec)
}

// ticketPair 是取件凭据的入参形状。
func ticketPair(thread map[string]any) map[string]any {
	return map[string]any{"threadId": thread["threadId"], "ticketKey": thread["ticketKey"]}
}

// pairDevice 直接经仓储层建账户、电脑与一台已配对设备（等价于黑盒的 enroll+claim）。
func pairDevice(t *testing.T, st *store.Store, name string) (string, string, string) {
	t.Helper()
	ctx := t.Context()
	account, err := st.CreateAccount(ctx, name)
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	agent, _, err := st.RegisterAgent(ctx, account.AccountID, name, nil)
	if err != nil {
		t.Fatalf("RegisterAgent: %v", err)
	}
	minted, err := st.MintPairCode(ctx, agent.AgentID, nil)
	if err != nil {
		t.Fatalf("MintPairCode: %v", err)
	}
	model, appVersion := "iPhone17,1", "9.9.9"
	claimed, err := st.ClaimPairCode(ctx, minted.Code, store.ClaimParams{
		DeviceName: name, Model: &model, AppVersion: &appVersion,
		TTLMS: store.DefaultDeviceTTLMS,
	})
	if err != nil {
		t.Fatalf("ClaimPairCode: %v", err)
	}
	return claimed.AccountID, claimed.DeviceID, claimed.DeviceToken
}

// threadCount 是库里的线程数（限流"不写库"这类断言要看得见行数）。
func (a *testAPI) threadCount() int {
	a.t.Helper()
	threads, err := a.store.ListFeedbackThreads(a.t.Context(), nil, nil, 1000, 0)
	if err != nil {
		a.t.Fatalf("读线程清单: %v", err)
	}
	return len(threads)
}

// ── 建线程 ──────────────────────────────────────────────────────────────────

func TestSubmitReturnsAOneTimeTicketAndStoresAnAnonymousThread(t *testing.T) {
	api := newTestAPI(t)
	created := api.submit("点了新建会话之后一直转圈", map[string]any{
		"subject": "新建会话卡住", "appVersion": "9.9.9 (100)",
		"deviceModel": "iPhone17,1", "systemVersion": "26.0",
	}, "")

	if created["ok"] != true {
		t.Fatalf("ok = %v", created["ok"])
	}
	threadID, _ := created["threadId"].(string)
	ticket, _ := created["ticketKey"].(string)
	if !strings.HasPrefix(threadID, "th_") {
		t.Fatalf("threadId = %q", threadID)
	}
	if !strings.HasPrefix(ticket, "fk_") || len(ticket) != 46 {
		t.Fatalf("取件凭据形态不对（fk_ + 43 字符）：%q（%d）", ticket, len(ticket))
	}
	if createdAt, ok := created["createdAt"].(float64); !ok || createdAt <= 0 {
		t.Fatalf("createdAt = %v", created["createdAt"])
	}

	thread, err := api.store.FeedbackThread(t.Context(), threadID, nil, 50)
	if err != nil || thread == nil {
		t.Fatalf("读线程: %v %v", thread, err)
	}
	if thread.DeviceID != nil || thread.AccountID != nil {
		t.Fatalf("无令牌的提交必须是匿名：%+v", thread)
	}
	if thread.Subject == nil || *thread.Subject != "新建会话卡住" {
		t.Fatalf("主题没落库：%+v", thread.Subject)
	}
	if thread.Messages[0].Format != "text" || thread.Messages[0].Author != "user" {
		t.Fatalf("首条留言不对：%+v", thread.Messages[0])
	}
	// 库里只存凭据的 SHA-256：用哈希能读回这条线程，凭据原文不会出现在任何行里。
	hash := store.SHA256Hex(ticket)
	if found, err := api.store.FeedbackThread(t.Context(), threadID, &hash, 0); err != nil || found == nil {
		t.Fatalf("按凭据哈希应能读回线程：%v %v", found, err)
	}
}

func TestSubmitRejectsMalformedBodies(t *testing.T) {
	api := newTestAPI(t)
	cases := []map[string]any{
		{},
		{"text": ""},
		{"text": "   "},
		{"text": 12},
		{"text": "ok", "subject": 5},
		{"text": "ok", "appVersion": 3},
		{"text": "ok", "deviceModel": []any{"iPhone"}},
		{"text": "ok", "clientRef": "bad ref!"},
		{"text": "ok", "clientRef": strings.Repeat("x", 65)},
		{"text": "ok", "format": "rtf"},
	}
	for _, payload := range cases {
		rec := api.do("/feedback/submit", payload, "", "")
		assertError(t, rec, http.StatusBadRequest, "feedback/bad-request")
	}
	if api.threadCount() != 0 {
		t.Fatalf("校验失败不该写库")
	}
}

func TestSubmitRejectsNonJSON(t *testing.T) {
	api := newTestAPI(t)
	rec := api.doRaw("/feedback/submit", strings.NewReader("this is not json"), "", "")
	assertError(t, rec, http.StatusBadRequest, "feedback/bad-request")
}

func TestSubmitEnforcesTheTextAndSubjectLimits(t *testing.T) {
	api := newTestAPI(t)

	tooManyChars := api.do("/feedback/submit", map[string]any{
		"text": strings.Repeat("x", 4001)}, "", "")
	assertError(t, tooManyChars, http.StatusBadRequest, "feedback/too-long")

	// 3000 个汉字 = 9000 字节：字符数没超，字节数超了（上限 8000）。
	body := `{"text":"` + strings.Repeat("中", 3000) + `"}`
	tooManyBytes := api.doRaw("/feedback/submit", strings.NewReader(body), "", "")
	assertError(t, tooManyBytes, http.StatusBadRequest, "feedback/too-long")

	longSubject := api.do("/feedback/submit", map[string]any{
		"text": "ok", "subject": strings.Repeat("题", 81)}, "", "")
	assertError(t, longSubject, http.StatusBadRequest, "feedback/too-long")

	longVersion := api.do("/feedback/submit", map[string]any{
		"text": "ok", "appVersion": strings.Repeat("v", 65)}, "", "")
	assertError(t, longVersion, http.StatusBadRequest, "feedback/too-long")

	// 正好 4000 字符是合法的。
	exact := api.do("/feedback/submit", map[string]any{
		"text": strings.Repeat("x", 4000)}, "", "")
	if exact.Code != http.StatusOK {
		t.Fatalf("4000 字符应接受：%d %s", exact.Code, exact.Body.String())
	}
}

func TestSubmitRejectsBodiesOverSixteenKilobytes(t *testing.T) {
	api := newTestAPI(t)
	rec := api.do("/feedback/submit", map[string]any{"text": strings.Repeat("x", 20000)}, "", "")
	assertError(t, rec, http.StatusRequestEntityTooLarge, "feedback/too-large")
	if api.threadCount() != 0 {
		t.Fatalf("413 不该写库")
	}
}

func TestSubmitIsIdempotentPerClientRef(t *testing.T) {
	api := newTestAPI(t)
	first := api.submit("第一次", map[string]any{"clientRef": "ref-1"}, "")
	second := api.submit("重试", map[string]any{"clientRef": "ref-1"}, "")

	if second["threadId"] != first["threadId"] {
		t.Fatalf("同一 clientRef 应是同一条线程：%v vs %v", first["threadId"], second["threadId"])
	}
	if second["ticketKey"] == first["ticketKey"] {
		t.Fatalf("重试必须换一把新凭据")
	}
	fresh := decodeJSON(t, api.do("/feedback/inbox", map[string]any{
		"tickets": []any{ticketPair(second)}}, "", ""))
	threads := fresh["threads"].([]any)
	if len(threads) != 1 || len(threads[0].(map[string]any)["messages"].([]any)) != 1 {
		t.Fatalf("重试不该再写一条留言：%v", fresh)
	}
	stale := decodeJSON(t, api.do("/feedback/inbox", map[string]any{
		"tickets": []any{ticketPair(first)}}, "", ""))
	if len(stale["threads"].([]any)) != 0 {
		t.Fatalf("旧凭据必须失效：%v", stale)
	}
}

func TestInvalidDeviceTokenIsTreatedAsAnonymous(t *testing.T) {
	api := newTestAPI(t)
	created := api.submit("过期令牌也要能提意见", nil, "dt_nope")
	thread, err := api.store.FeedbackThread(t.Context(), created["threadId"].(string), nil, 50)
	if err != nil || thread == nil {
		t.Fatalf("读线程: %v %v", thread, err)
	}
	if thread.DeviceID != nil {
		t.Fatalf("无效令牌应按匿名处理：%+v", thread.DeviceID)
	}
	rec := api.do("/feedback/inbox", map[string]any{}, "dt_nope", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("无效令牌不该返回 401：%d %s", rec.Code, rec.Body.String())
	}
	if len(decodeJSON(t, rec)["threads"].([]any)) != 0 {
		t.Fatalf("匿名且没有凭据时什么都看不到")
	}
}

// ── 列表与详情 ──────────────────────────────────────────────────────────────

func TestInboxListsTheThreadAndItsMessagesByTicket(t *testing.T) {
	api := newTestAPI(t)
	created := api.submit("列表里应该看到这句", map[string]any{"subject": "一句主题"}, "")
	rec := api.do("/feedback/inbox", map[string]any{
		"tickets": []any{ticketPair(created)}}, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("inbox: %d %s", rec.Code, rec.Body.String())
	}
	payload := decodeJSON(t, rec)
	if payload["ok"] != true || payload["unreadCount"] != float64(0) {
		t.Fatalf("未读数应为 0（用户自己的留言不算未读）：%v", payload)
	}
	if len(payload["notices"].([]any)) != 0 {
		t.Fatalf("匿名不该有通知：%v", payload["notices"])
	}
	thread := payload["threads"].([]any)[0].(map[string]any)
	if thread["threadId"] != created["threadId"] || thread["status"] != "open" ||
		thread["subject"] != "一句主题" || thread["unread"] != float64(0) {
		t.Fatalf("线程字段不对：%v", thread)
	}
	message := thread["messages"].([]any)[0].(map[string]any)
	want := map[string]bool{"messageId": true, "author": true, "body": true,
		"format": true, "createdAt": true}
	if len(message) != len(want) {
		t.Fatalf("留言形状多出或少字段：%v", message)
	}
	for key := range message {
		if !want[key] {
			t.Fatalf("留言多出字段 %q：%v", key, message)
		}
	}
	if message["author"] != "user" || message["body"] != "列表里应该看到这句" ||
		message["format"] != "text" {
		t.Fatalf("留言内容不对：%v", message)
	}
}

func TestInboxDoesNotLeakThreadsWithoutTheTicket(t *testing.T) {
	api := newTestAPI(t)
	created := api.submit("只有凭据能打开这条", nil, "")

	wrong := decodeJSON(t, api.do("/feedback/inbox", map[string]any{
		"tickets": []any{map[string]any{"threadId": created["threadId"],
			"ticketKey": "fk_" + strings.Repeat("A", 43)}}}, "", ""))
	if len(wrong["threads"].([]any)) != 0 {
		t.Fatalf("错误凭据不该看到线程：%v", wrong)
	}
	anonymous := decodeJSON(t, api.do("/feedback/inbox", map[string]any{}, "", ""))
	if len(anonymous["threads"].([]any)) != 0 {
		t.Fatalf("匿名且没有凭据时什么都看不到")
	}

	_, _, otherToken := pairDevice(t, api.store, "另一个账户")
	theirs := decodeJSON(t, api.do("/feedback/inbox", map[string]any{}, otherToken, ""))
	if len(theirs["threads"].([]any)) != 0 {
		t.Fatalf("别的账号的设备不该看到这条线程")
	}
}

func TestInboxMessagesPerThreadDefaultsToFiftyAndCapsAtTwoHundred(t *testing.T) {
	api := newTestAPI(t)
	created := api.submit("原文", nil, "")
	threadID := created["threadId"].(string)
	for index := 0; index < 205; index++ {
		if _, err := api.store.AppendFeedbackMessage(t.Context(), store.AppendFeedbackInput{
			ThreadID: threadID, Body: "补充 " + itoa(index), Author: "user",
			At: 9_000_000_000_000 + int64(index),
		}); err != nil {
			t.Fatalf("补充 %d: %v", index, err)
		}
	}

	defaulted := decodeJSON(t, api.do("/feedback/inbox", map[string]any{
		"tickets": []any{ticketPair(created)}}, "", ""))
	messages := defaulted["threads"].([]any)[0].(map[string]any)["messages"].([]any)
	if len(messages) != 50 {
		t.Fatalf("默认 50 条，实际 %d", len(messages))
	}
	capped := decodeJSON(t, api.do("/feedback/inbox", map[string]any{
		"tickets": []any{ticketPair(created)}, "messagesPerThread": 500}, "", ""))
	messages = capped["threads"].([]any)[0].(map[string]any)["messages"].([]any)
	if len(messages) != 200 {
		t.Fatalf("上限 200 条，实际 %d", len(messages))
	}
	if last := messages[len(messages)-1].(map[string]any)["body"]; last != "补充 204" {
		t.Fatalf("应取最近的 N 条：%v", last)
	}
}

func TestInboxRejectsMalformedInput(t *testing.T) {
	api := newTestAPI(t)
	tooMany := make([]any, 0, 51)
	for index := 0; index < 51; index++ {
		tooMany = append(tooMany, map[string]any{"threadId": "th_x",
			"ticketKey": "fk_" + strings.Repeat("A", 43)})
	}
	cases := []map[string]any{
		{"tickets": "nope"},
		{"tickets": []any{map[string]any{"threadId": "th_x"}}},
		{"tickets": []any{map[string]any{"threadId": "th_x", "ticketKey": 1}}},
		{"tickets": []any{1}},
		{"tickets": tooMany},
		{"messagesPerThread": 0},
		{"messagesPerThread": "50"},
	}
	for _, payload := range cases {
		assertError(t, api.do("/feedback/inbox", payload, "", ""),
			http.StatusBadRequest, "feedback/bad-request")
	}
}

func TestInboxCanSkipNotices(t *testing.T) {
	api := newTestAPI(t)
	accountID, _, token := pairDevice(t, api.store, "通知账户")
	if _, err := api.store.CreateNotice(t.Context(), store.CreateNoticeInput{
		Body: "今晚维护", Subject: stringPtr("维护通知"), AccountIDs: []string{accountID},
	}); err != nil {
		t.Fatalf("CreateNotice: %v", err)
	}

	withNotices := decodeJSON(t, api.do("/feedback/inbox", map[string]any{}, token, ""))
	if len(withNotices["notices"].([]any)) != 1 || withNotices["unreadCount"] != float64(1) {
		t.Fatalf("默认应带通知：%v", withNotices)
	}
	skipped := decodeJSON(t, api.do("/feedback/inbox", map[string]any{"notices": false}, token, ""))
	if len(skipped["notices"].([]any)) != 0 || skipped["unreadCount"] != float64(0) {
		t.Fatalf("notices:false 应跳过通知与它的未读：%v", skipped)
	}
}

func TestAttachmentsAreIgnored(t *testing.T) {
	api := newTestAPI(t)
	created := api.submit("带一个附件试试", map[string]any{
		"attachments": []any{map[string]any{"name": "shot.png", "bytes": 3}},
	}, "")
	rec := api.do("/feedback/inbox", map[string]any{
		"tickets": []any{ticketPair(created)}}, "", "")
	if strings.Contains(rec.Body.String(), "attachments") {
		t.Fatalf("附件不在当前契约里：%s", rec.Body.String())
	}
	payload := decodeJSON(t, rec)
	message := payload["threads"].([]any)[0].(map[string]any)["messages"].([]any)[0].(map[string]any)
	if len(message) != 5 {
		t.Fatalf("留言形状被附件改动了：%v", message)
	}
}

// ── 回信与已读 ──────────────────────────────────────────────────────────────

func TestAppendThenReadClearsUnread(t *testing.T) {
	api := newTestAPI(t)
	created := api.submit("第一个问题", nil, "")
	appended := api.do("/feedback/append", map[string]any{
		"threadId": created["threadId"], "ticketKey": created["ticketKey"],
		"text": "补充一句：重启之后还是一样"}, "", "")
	if appended.Code != http.StatusOK {
		t.Fatalf("append: %d %s", appended.Code, appended.Body.String())
	}
	if body := decodeJSON(t, appended); body["ok"] != true ||
		body["threadId"] != created["threadId"] {
		t.Fatalf("append 响应：%v", body)
	}

	before := decodeJSON(t, api.do("/feedback/inbox", map[string]any{
		"tickets": []any{ticketPair(created)}}, "", ""))
	thread := before["threads"].([]any)[0].(map[string]any)
	if len(thread["messages"].([]any)) != 2 || thread["status"] != "open" {
		t.Fatalf("用户补充后仍是 open 且有两条留言：%v", thread)
	}

	if _, err := api.store.AppendFeedbackMessage(t.Context(), store.AppendFeedbackInput{
		ThreadID: created["threadId"].(string), Body: "收到，我看一下。", Author: "owner",
	}); err != nil {
		t.Fatalf("owner 回信: %v", err)
	}
	unread := decodeJSON(t, api.do("/feedback/inbox", map[string]any{
		"tickets": []any{ticketPair(created)}}, "", ""))
	if unread["unreadCount"] != float64(1) {
		t.Fatalf("owner 的留言应计入未读：%v", unread["unreadCount"])
	}

	marked := api.do("/feedback/read", map[string]any{
		"threadIds": []any{created["threadId"]},
		"tickets":   []any{ticketPair(created)}}, "", "")
	if marked.Code != http.StatusOK {
		t.Fatalf("read: %d %s", marked.Code, marked.Body.String())
	}
	if body := decodeJSON(t, marked); body["ok"] != true || body["unreadCount"] != float64(0) {
		t.Fatalf("read 响应：%v", body)
	}
	after := decodeJSON(t, api.do("/feedback/inbox", map[string]any{
		"tickets": []any{ticketPair(created)}}, "", ""))
	if after["unreadCount"] != float64(0) {
		t.Fatalf("已读后未读应清零：%v", after["unreadCount"])
	}
	if len(after["threads"].([]any)[0].(map[string]any)["messages"].([]any)) != 3 {
		t.Fatalf("已读不该删留言")
	}

	wrong := api.do("/feedback/append", map[string]any{
		"threadId": created["threadId"], "ticketKey": "fk_" + strings.Repeat("A", 43),
		"text": "我是谁"}, "", "")
	assertError(t, wrong, http.StatusNotFound, "feedback/not-found")
}

func TestReadRejectsMalformedIDLists(t *testing.T) {
	api := newTestAPI(t)
	tooMany := make([]any, 0, 51)
	for index := 0; index < 51; index++ {
		tooMany = append(tooMany, map[string]any{"threadId": "th_" + itoa(index),
			"ticketKey": "fk_" + strings.Repeat("A", 43)})
	}
	cases := []map[string]any{
		{"threadIds": "th_one"},
		{"noticeIds": []any{1, 2}},
		{"tickets": []any{map[string]any{"threadId": "th_one"}}},
		{"tickets": tooMany},
	}
	for _, payload := range cases {
		assertError(t, api.do("/feedback/read", payload, "", ""),
			http.StatusBadRequest, "feedback/bad-request")
	}
}

func TestReadOnlyMarksAuthorizedThreads(t *testing.T) {
	api := newTestAPI(t)
	created := api.submit("只有凭据或设备能标记", nil, "")
	if _, err := api.store.AppendFeedbackMessage(t.Context(), store.AppendFeedbackInput{
		ThreadID: created["threadId"].(string), Body: "回信", Author: "owner"}); err != nil {
		t.Fatalf("owner 回信: %v", err)
	}

	wrongTicket := api.do("/feedback/read", map[string]any{
		"threadIds": []any{created["threadId"]},
		"tickets": []any{map[string]any{"threadId": created["threadId"],
			"ticketKey": "fk_" + strings.Repeat("A", 43)}},
	}, "", "")
	if wrongTicket.Code != http.StatusOK {
		t.Fatalf("read: %d %s", wrongTicket.Code, wrongTicket.Body.String())
	}
	thread, _ := api.store.FeedbackThread(t.Context(), created["threadId"].(string), nil, 0)
	if thread.UserReadAt != nil {
		t.Fatalf("错误凭据不该标已读：%v", thread.UserReadAt)
	}

	// 设备绑定的线程可以由设备令牌标记。
	_, _, token := pairDevice(t, api.store, "设备账户")
	bound := api.submit("设备提交", nil, token)
	if _, err := api.store.AppendFeedbackMessage(t.Context(), store.AppendFeedbackInput{
		ThreadID: bound["threadId"].(string), Body: "回信", Author: "owner"}); err != nil {
		t.Fatalf("owner 回信: %v", err)
	}
	marked := api.do("/feedback/read", map[string]any{
		"threadIds": []any{bound["threadId"]}}, token, "")
	if marked.Code != http.StatusOK {
		t.Fatalf("read: %d %s", marked.Code, marked.Body.String())
	}
	thread, _ = api.store.FeedbackThread(t.Context(), bound["threadId"].(string), nil, 0)
	if thread.UserReadAt == nil {
		t.Fatalf("设备能证明的线程应可标已读")
	}
}

func TestReadMarksANoticeForTheWholeAccount(t *testing.T) {
	api := newTestAPI(t)
	accountID, _, firstToken := pairDevice(t, api.store, "同账号账户")
	// 同账号的第二台设备：用持久码再认领一次（pairDevice 每次建新账户，这里单独做）。
	accountDevices, err := api.store.ListDevices(t.Context(), "", false)
	if err != nil || len(accountDevices) != 1 {
		t.Fatalf("设备清单: %v %v", accountDevices, err)
	}
	agentID := accountDevices[0].AgentID
	minted, err := api.store.MintPairCode(t.Context(), agentID, nil)
	if err != nil {
		t.Fatalf("MintPairCode: %v", err)
	}
	second, err := api.store.ClaimPairCode(t.Context(), minted.Code, store.ClaimParams{
		DeviceName: "第二台", TTLMS: store.DefaultDeviceTTLMS,
	})
	if err != nil {
		t.Fatalf("ClaimPairCode: %v", err)
	}
	if second.AccountID != accountID {
		t.Fatalf("前提：两台设备同账号：%s vs %s", second.AccountID, accountID)
	}

	notice, err := api.store.CreateNotice(t.Context(), store.CreateNoticeInput{
		Body: "今晚 23:00 维护", Subject: stringPtr("维护通知"), AccountIDs: []string{accountID},
	})
	if err != nil {
		t.Fatalf("CreateNotice: %v", err)
	}
	for _, token := range []string{firstToken, second.DeviceToken} {
		payload := decodeJSON(t, api.do("/feedback/inbox", map[string]any{}, token, ""))
		notices := payload["notices"].([]any)
		if len(notices) != 1 || notices[0].(map[string]any)["noticeId"] != notice.NoticeID {
			t.Fatalf("同账号两台设备应看到同一条通知：%v", payload)
		}
		if notices[0].(map[string]any)["read"] != false {
			t.Fatalf("未读状态不对：%v", notices[0])
		}
	}

	marked := api.do("/feedback/read", map[string]any{
		"noticeIds": []any{notice.NoticeID}}, firstToken, "")
	if body := decodeJSON(t, marked); body["unreadCount"] != float64(0) {
		t.Fatalf("标记后未读应为 0：%v", body)
	}
	after := decodeJSON(t, api.do("/feedback/inbox", map[string]any{}, second.DeviceToken, ""))
	if after["notices"].([]any)[0].(map[string]any)["read"] != true ||
		after["unreadCount"] != float64(0) {
		t.Fatalf("一台读过，另一台也是已读：%v", after)
	}
}

// ── 限流 ────────────────────────────────────────────────────────────────────

func TestSubmitIsRateLimitedPerSourceAndARefusedRequestIsNotStored(t *testing.T) {
	api := newTestAPI(t)
	accepted := 0
	var blocked *httptest.ResponseRecorder
	for index := 0; index < 200; index++ {
		rec := api.do("/feedback/submit", map[string]any{"text": "spam"}, "", "")
		if rec.Code == http.StatusOK {
			accepted++
			continue
		}
		blocked = rec
		break
	}
	if blocked == nil {
		t.Fatalf("公开的写入接口必须有限流")
	}
	assertError(t, blocked, http.StatusTooManyRequests, "feedback/rate-limited")
	if accepted != writeLimit {
		t.Fatalf("来源桶应在 %d 次后拒绝，实际接受 %d 次", writeLimit, accepted)
	}
	if got := api.threadCount(); got != accepted {
		t.Fatalf("命中限流的那次不该落库：库里 %d 行，接受 %d 次", got, accepted)
	}

	// 换一个来源仍有自己的预算（一个人不能把所有人堵死）。
	other := api.do("/feedback/submit", map[string]any{"text": "另一个来源"}, "", "203.0.113.9:5000")
	if other.Code != http.StatusOK {
		t.Fatalf("限流按来源分桶：%d %s", other.Code, other.Body.String())
	}
}

func TestSubmitIsRateLimitedPerDeviceAcrossSources(t *testing.T) {
	api := newTestAPI(t)
	_, _, token := pairDevice(t, api.store, "限流设备")
	accepted := 0
	var blocked *httptest.ResponseRecorder
	for index := 0; index < 200; index++ {
		// 每次换来源，让来源桶（30）永远打不满，只剩设备桶（60）在拦。
		remote := "203.0.113." + itoa(index%200) + ":5000"
		rec := api.do("/feedback/submit", map[string]any{"text": "spam"}, token, remote)
		if rec.Code == http.StatusOK {
			accepted++
			continue
		}
		blocked = rec
		break
	}
	if blocked == nil {
		t.Fatalf("设备桶必须生效")
	}
	assertError(t, blocked, http.StatusTooManyRequests, "feedback/rate-limited")
	if accepted != writeDeviceLimit {
		t.Fatalf("设备桶应在 %d 次后拒绝，实际接受 %d 次", writeDeviceLimit, accepted)
	}
}

func TestInboxAndReadUseTheWiderReadBucket(t *testing.T) {
	api := newTestAPI(t)
	accepted := 0
	var blocked *httptest.ResponseRecorder
	for index := 0; index < 200; index++ {
		rec := api.do("/feedback/inbox", map[string]any{}, "", "")
		if rec.Code == http.StatusOK {
			accepted++
			continue
		}
		blocked = rec
		break
	}
	if blocked == nil {
		t.Fatalf("读取也要有限流")
	}
	assertError(t, blocked, http.StatusTooManyRequests, "feedback/rate-limited")
	if accepted != readLimit {
		t.Fatalf("读桶应在 %d 次后拒绝，实际接受 %d 次", readLimit, accepted)
	}
}

// ── 小工具 ──────────────────────────────────────────────────────────────────

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	digits := make([]byte, 0, 4)
	for value > 0 {
		digits = append([]byte{byte('0' + value%10)}, digits...)
		value /= 10
	}
	return string(digits)
}

func stringPtr(value string) *string { return &value }
