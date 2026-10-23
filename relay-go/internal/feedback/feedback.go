// Package feedback 是反馈通道的四个追加式 HTTP 端点（014）：
//
//	POST /feedback/submit  新建线程（可选 subject），返回一次性的取件凭据
//	POST /feedback/inbox   拉取线程与通知，**不改任何已读状态**
//	POST /feedback/append  用户在已有线程下补充，线程回到 open
//	POST /feedback/read    标记已读；线程按凭据或设备授权，通知按账号
//
// 鉴权是可选的（Authorization: Bearer <deviceToken>）：有效就绑定设备与账号；
// **无效（撤销、过期、乱填）不返回 401，按匿名处理**——一块过期的设备令牌不该让
// 用户提交不了意见。四个接口都是这条口径。
//
// 限流：submit/append 按来源与设备各一桶，inbox/read 用更宽的读桶；命中限流
// **不写库**。正文、字段与请求体的上限逐项对齐 relay/feedback.py 与
// specs/014-feedback-channel/contracts/feedback-http.md。
//
// SQL 全在 internal/store 里；这个包只管 HTTP、校验、限流与授权。
package feedback

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/apierr"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/authn"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/httpjson"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/ratelimit"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 与 Python feedback.py 的常量逐字一致。
const (
	// MaxTextChars / MaxTextBytes 是用户正文的两条线：字符数与 UTF-8 字节数。
	MaxTextChars = 4000
	MaxTextBytes = 8000
	// MaxBodyBytes 是公开写入接口的请求体上限（16 KB），不是 WebSocket 的 32 MB。
	MaxBodyBytes = 16 * 1024
	// MaxTechChars 是版本/机型/系统各 64 字符。
	MaxTechChars = 64
	// MaxClientRefChars 是幂等键的长度上限（字符集另见 clientRefPattern）。
	MaxClientRefChars = 64
	// MaxTickets 是一次 inbox/read 最多带多少对凭据。
	MaxTickets = 50
	// MaxIDs 是一次 read 最多带多少个 id。
	MaxIDs = 200
	// MaxMessagesPerThread 是每条线程最多回多少条留言（超出取最近的）。
	MaxMessagesPerThread = 200
	// DefaultMessagesPerThread 是 messagesPerThread 的缺省值。
	DefaultMessagesPerThread = 50
)

// clientRefPattern 是幂等键允许的字符集（Python 的同名正则）。
var clientRefPattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// 写入按来源与设备各一桶（换网络也该被算上），读取用更宽的一桶。
const (
	writeLimit       = 30
	writeDeviceLimit = 60
	readLimit        = 120
	limitWindow      = 10 * time.Minute
)

// Options 是装配四个端点需要的输入。
type Options struct {
	Store *store.Store
	// ClientID 把请求映射成限流桶的键。生产注入 httpapi.clientIdentifier——
	// "客户端是什么"的信任边界只允许有一份实现。
	ClientID func(*http.Request) string
	Logger   *slog.Logger
}

// Handlers 是 /feedback/* 的四个处理器与其限流桶。
type Handlers struct {
	store    *store.Store
	clientID func(*http.Request) string
	log      *slog.Logger

	writeLimiter       *ratelimit.Limiter
	writeDeviceLimiter *ratelimit.Limiter
	readLimiter        *ratelimit.Limiter
}

// New 建四个反馈端点。
func New(options Options) *Handlers {
	log := options.Logger
	if log == nil {
		log = slog.Default()
	}
	clientID := options.ClientID
	if clientID == nil {
		// 单测直接调 handler 时没有 httpapi 的信任边界；生产路径不会走到这里。
		clientID = func(r *http.Request) string { return r.RemoteAddr }
	}
	return &Handlers{
		store:              options.Store,
		clientID:           clientID,
		log:                log,
		writeLimiter:       ratelimit.New(writeLimit, limitWindow),
		writeDeviceLimiter: ratelimit.New(writeDeviceLimit, limitWindow),
		readLimiter:        ratelimit.New(readLimit, limitWindow),
	}
}

// Register 把四条路由挂到 mux 上（带前缀与去前缀两种形式由调用方各挂一次）。
func (h *Handlers) Register(mux *http.ServeMux, prefix string) {
	mux.HandleFunc("POST "+prefix+"/feedback/submit", h.HandleSubmit)
	mux.HandleFunc("POST "+prefix+"/feedback/inbox", h.HandleInbox)
	mux.HandleFunc("POST "+prefix+"/feedback/append", h.HandleAppend)
	mux.HandleFunc("POST "+prefix+"/feedback/read", h.HandleRead)
}

// ── 响应形状 ────────────────────────────────────────────────────────────────

// submitResponse 是建线程成功的响应：取件凭据**只在这里出现一次**。
type submitResponse struct {
	OK        bool   `json:"ok"`
	ThreadID  string `json:"threadId"`
	TicketKey string `json:"ticketKey"`
	CreatedAt int64  `json:"createdAt"`
}

// appendResponse 是用户补充留言的响应。
type appendResponse struct {
	OK        bool   `json:"ok"`
	ThreadID  string `json:"threadId"`
	MessageID string `json:"messageId"`
	CreatedAt int64  `json:"createdAt"`
}

// readResponse 只回未读数：调用方下一次 inbox 会拿到完整列表。
type readResponse struct {
	OK          bool `json:"ok"`
	UnreadCount int  `json:"unreadCount"`
}

// inboxResponse 是线程与通知的合并视图。
type inboxResponse struct {
	OK          bool           `json:"ok"`
	Threads     []publicThread `json:"threads"`
	Notices     []publicNotice `json:"notices"`
	UnreadCount int            `json:"unreadCount"`
}

// publicThread 是出网的线程形状：ticketHash 与来源信息这类内部列不得出网。
type publicThread struct {
	ThreadID      string          `json:"threadId"`
	Subject       *string         `json:"subject"`
	Status        string          `json:"status"`
	CreatedAt     int64           `json:"createdAt"`
	LastMessageAt int64           `json:"lastMessageAt"`
	Unread        int             `json:"unread"`
	Messages      []publicMessage `json:"messages"`
}

// publicMessage 是留言的出网形状（附件尚未进入契约，这里没有 attachments）。
type publicMessage struct {
	MessageID string `json:"messageId"`
	Author    string `json:"author"`
	Body      string `json:"body"`
	Format    string `json:"format"`
	CreatedAt int64  `json:"createdAt"`
}

// publicNotice 是通知的出网形状：read 是账号级已读。
type publicNotice struct {
	NoticeID  string  `json:"noticeId"`
	Subject   *string `json:"subject"`
	Body      string  `json:"body"`
	Format    string  `json:"format"`
	CreatedAt int64   `json:"createdAt"`
	Read      bool    `json:"read"`
}

// ── 四个端点 ────────────────────────────────────────────────────────────────

// HandleSubmit 新建一条线程并把取件凭据返回一次（库里只留它的 SHA-256）。
func (h *Handlers) HandleSubmit(w http.ResponseWriter, r *http.Request) {
	body, ok := h.readBody(w, r)
	if !ok {
		return
	}
	text, problem := textOf(body)
	if problem != nil {
		problem.write(w)
		return
	}
	subject, problem := subjectOf(body)
	if problem != nil {
		problem.write(w)
		return
	}
	// 用户提交的正文永远是 text：这里只把不合法的取值挡在 400。
	if problem := formatOf(body); problem != nil {
		problem.write(w)
		return
	}
	fields := make(map[string]*string, 3)
	for _, key := range []string{"appVersion", "deviceModel", "systemVersion"} {
		value, problem := techOf(body, key)
		if problem != nil {
			problem.write(w)
			return
		}
		fields[key] = value
	}
	clientRef, problem := clientRefOf(body)
	if problem != nil {
		problem.write(w)
		return
	}

	device, err := h.caller(r)
	if err != nil {
		h.storeFailure(w, r, "feedback/store-error", "the relay could not store the feedback", err)
		return
	}
	if !h.charge(r, true, device) {
		writeRateLimited(w)
		return
	}

	ticket := store.NewFeedbackTicket()
	thread, err := h.store.CreateFeedbackThread(r.Context(), store.CreateFeedbackThreadInput{
		TicketHash: store.SHA256Hex(ticket), Text: text,
		AccountID:  deviceValue(device, func(d store.Device) *string { return &d.AccountID }),
		DeviceID:   deviceValue(device, func(d store.Device) *string { return &d.DeviceID }),
		AppVersion: fields["appVersion"], DeviceModel: fields["deviceModel"],
		SystemVersion: fields["systemVersion"], ClientRef: clientRef, Subject: subject,
	})
	if err != nil {
		var conflict *store.Conflict
		if errors.As(err, &conflict) {
			// 这个 clientRef 已经属于别的来源：不新建，也不把那条线程交出去。
			writeProblem(w, http.StatusBadRequest, "feedback/bad-request",
				"clientRef has already been used")
			return
		}
		h.storeFailure(w, r, "feedback/store-error",
			"the relay could not store the feedback", err)
		return
	}
	httpjson.WriteJSON(w, http.StatusOK, submitResponse{
		OK: true, ThreadID: thread.ThreadID, TicketKey: ticket, CreatedAt: thread.CreatedAt,
	})
	h.log.Info("relay: feedback handled", "requestId", reqctx.ID(r.Context()),
		"op", "submit", "threadId", thread.ThreadID, "anonymous", device == nil,
		"status", http.StatusOK, "ok", true)
}

// HandleInbox 拉取；**只读**：拉一次不会把未读清掉。
func (h *Handlers) HandleInbox(w http.ResponseWriter, r *http.Request) {
	body, ok := h.readBody(w, r)
	if !ok {
		return
	}
	pairs, problem := ticketPairsOf(body)
	if problem != nil {
		problem.write(w)
		return
	}
	limit, problem := messagesLimitOf(body)
	if problem != nil {
		problem.write(w)
		return
	}
	device, err := h.caller(r)
	if err != nil {
		h.storeFailure(w, r, "feedback/store-error", "the relay could not read the feedback", err)
		return
	}
	if !h.charge(r, false, device) {
		writeRateLimited(w)
		return
	}

	payload, err := h.collect(r.Context(), pairs, device, limit, withNotices(body))
	if err != nil {
		h.storeFailure(w, r, "feedback/store-error", "the relay could not read the feedback", err)
		return
	}
	httpjson.WriteJSON(w, http.StatusOK, payload)
	h.log.Info("relay: feedback handled", "requestId", reqctx.ID(r.Context()),
		"op", "inbox", "threads", len(payload.Threads), "notices", len(payload.Notices),
		"unread", payload.UnreadCount, "anonymous", device == nil,
		"status", http.StatusOK, "ok", true)
}

// HandleAppend 用户在已有线程下补充一句（异步留言，不是即时对话）。
func (h *Handlers) HandleAppend(w http.ResponseWriter, r *http.Request) {
	body, ok := h.readBody(w, r)
	if !ok {
		return
	}
	threadID := stringOf(body["threadId"])
	ticketKey := stringOf(body["ticketKey"])
	if threadID == "" || ticketKey == "" {
		writeProblem(w, http.StatusBadRequest, "feedback/bad-request",
			"threadId and ticketKey are required")
		return
	}
	text, problem := textOf(body)
	if problem != nil {
		problem.write(w)
		return
	}
	// 与 submit 同一条：用户补充的正文永远是 text，只校验取值合不合法。
	if problem := formatOf(body); problem != nil {
		problem.write(w)
		return
	}
	clientRef, problem := clientRefOf(body)
	if problem != nil {
		problem.write(w)
		return
	}
	device, err := h.caller(r)
	if err != nil {
		h.storeFailure(w, r, "feedback/store-error", "the relay could not store the message", err)
		return
	}
	if !h.charge(r, true, device) {
		writeRateLimited(w)
		return
	}

	thread, err := h.store.FeedbackThread(r.Context(), threadID,
		ptrString(store.SHA256Hex(ticketKey)), 0)
	if err != nil {
		h.storeFailure(w, r, "feedback/store-error", "the relay could not store the message", err)
		return
	}
	if thread == nil {
		writeNotFound(w)
		return
	}
	message, err := h.store.AppendFeedbackMessage(r.Context(), store.AppendFeedbackInput{
		ThreadID: threadID, Body: text, Author: "user", ClientRef: clientRef,
		BindDeviceID:  deviceValue(device, func(d store.Device) *string { return &d.DeviceID }),
		BindAccountID: deviceValue(device, func(d store.Device) *string { return &d.AccountID }),
	})
	if err != nil {
		h.storeFailure(w, r, "feedback/store-error", "the relay could not store the message", err)
		return
	}
	if message == nil { // 与上面同一条 404：不泄露线程是否存在
		writeNotFound(w)
		return
	}
	httpjson.WriteJSON(w, http.StatusOK, appendResponse{
		OK: true, ThreadID: threadID, MessageID: message.MessageID, CreatedAt: message.CreatedAt,
	})
	h.log.Info("relay: feedback handled", "requestId", reqctx.ID(r.Context()),
		"op", "append", "threadId", threadID, "messageId", message.MessageID,
		"anonymous", device == nil, "status", http.StatusOK, "ok", true)
}

// HandleRead 标记已读；只有调用方能证明的线程才标得动，通知按账号标。
func (h *Handlers) HandleRead(w http.ResponseWriter, r *http.Request) {
	body, ok := h.readBody(w, r)
	if !ok {
		return
	}
	threadIDs, problem := idListOf(body, "threadIds")
	if problem != nil {
		problem.write(w)
		return
	}
	noticeIDs, problem := idListOf(body, "noticeIds")
	if problem != nil {
		problem.write(w)
		return
	}
	pairs, problem := ticketPairsOf(body)
	if problem != nil {
		problem.write(w)
		return
	}
	device, err := h.caller(r)
	if err != nil {
		h.storeFailure(w, r, "feedback/store-error", "the relay could not mark the feedback", err)
		return
	}
	if !h.charge(r, false, device) {
		writeRateLimited(w)
		return
	}

	allowed, err := h.authorizedThreads(r.Context(), pairs, device)
	if err != nil {
		h.storeFailure(w, r, "feedback/store-error", "the relay could not mark the feedback", err)
		return
	}
	for _, threadID := range threadIDs {
		if _, ok := allowed[threadID]; !ok {
			continue
		}
		if _, err := h.store.MarkThreadRead(r.Context(), threadID, nil); err != nil {
			h.storeFailure(w, r, "feedback/store-error",
				"the relay could not mark the feedback", err)
			return
		}
	}
	if device != nil && len(noticeIDs) > 0 {
		if _, err := h.store.MarkNoticesRead(r.Context(), device.AccountID, noticeIDs, 0); err != nil {
			h.storeFailure(w, r, "feedback/store-error",
				"the relay could not mark the feedback", err)
			return
		}
	}
	payload, err := h.collect(r.Context(), pairs, device, 0, true)
	if err != nil {
		h.storeFailure(w, r, "feedback/store-error", "the relay could not mark the feedback", err)
		return
	}
	httpjson.WriteJSON(w, http.StatusOK, readResponse{OK: true, UnreadCount: payload.UnreadCount})
	h.log.Info("relay: feedback handled", "requestId", reqctx.ID(r.Context()),
		"op", "read", "threads", len(threadIDs), "notices", len(noticeIDs),
		"unread", payload.UnreadCount, "status", http.StatusOK, "ok", true)
}

// ── 组装与授权 ──────────────────────────────────────────────────────────────

// collect 读调用方看得到的线程（凭据命中 ∪ 设备/账号命中，去重）与未读计数。
func (h *Handlers) collect(ctx context.Context, pairs []store.TicketPair,
	device *store.Device, messagesPerThread int, withNotices bool) (inboxResponse, error) {
	threads, err := h.store.FeedbackThreadsByTickets(ctx, pairs, messagesPerThread)
	if err != nil {
		return inboxResponse{}, err
	}
	if device != nil {
		bound, err := h.store.FeedbackThreadsByDevice(ctx, device.DeviceID,
			&device.AccountID, messagesPerThread)
		if err != nil {
			return inboxResponse{}, err
		}
		seen := make(map[string]struct{}, len(threads))
		for _, thread := range threads {
			seen[thread.ThreadID] = struct{}{}
		}
		for _, thread := range bound {
			if _, done := seen[thread.ThreadID]; done {
				continue
			}
			threads = append(threads, thread)
		}
	}
	// Python 的 sort 是稳定排序；同一毫秒的两条线程保持读出来的顺序。
	sort.SliceStable(threads, func(i, j int) bool {
		return threads[i].LastMessageAt > threads[j].LastMessageAt
	})

	notices := make([]store.Notice, 0)
	if withNotices && device != nil {
		// 通知按**账号**取（019）：同一账号下的设备共享一份收件箱与一份已读。
		notices, err = h.store.NoticesForAccount(ctx, device.AccountID, 0)
		if err != nil {
			return inboxResponse{}, err
		}
	}

	unread := 0
	for _, thread := range threads {
		unread += thread.Unread
	}
	for _, notice := range notices {
		if !notice.Read {
			unread++
		}
	}

	payload := inboxResponse{
		OK: true, Threads: make([]publicThread, 0, len(threads)),
		Notices: make([]publicNotice, 0, len(notices)), UnreadCount: unread,
	}
	for _, thread := range threads {
		payload.Threads = append(payload.Threads, publicThread{
			ThreadID: thread.ThreadID, Subject: thread.Subject, Status: thread.Status,
			CreatedAt: thread.CreatedAt, LastMessageAt: thread.LastMessageAt,
			Unread: thread.Unread, Messages: publicMessages(thread.Messages),
		})
	}
	for _, notice := range notices {
		payload.Notices = append(payload.Notices, publicNotice{
			NoticeID: notice.NoticeID, Subject: notice.Subject, Body: notice.Body,
			Format: notice.Format, CreatedAt: notice.CreatedAt, Read: notice.Read,
		})
	}
	return payload, nil
}

// authorizedThreads 是这次调用可以标记的线程：凭据命中 ∪ 设备（或账号）命中。
func (h *Handlers) authorizedThreads(ctx context.Context, pairs []store.TicketPair,
	device *store.Device) (map[string]struct{}, error) {
	allowed := make(map[string]struct{}, len(pairs))
	for _, pair := range pairs {
		thread, err := h.store.FeedbackThread(ctx, pair.ThreadID,
			ptrString(pair.TicketHash), 0)
		if err != nil {
			return nil, err
		}
		if thread != nil {
			allowed[pair.ThreadID] = struct{}{}
		}
	}
	if device != nil {
		bound, err := h.store.FeedbackThreadsByDevice(ctx, device.DeviceID,
			&device.AccountID, 0)
		if err != nil {
			return nil, err
		}
		for _, thread := range bound {
			allowed[thread.ThreadID] = struct{}{}
		}
	}
	return allowed, nil
}

// caller 是可选令牌背后的设备；nil 就是匿名。
//
// 撤销、过期、乱填的令牌在这里都变成"匿名"，**不是错误**（见包注释）。
func (h *Handlers) caller(r *http.Request) (*store.Device, error) {
	token := authn.BearerToken(r)
	if token == "" {
		return nil, nil
	}
	device, ok, err := h.store.DeviceByToken(r.Context(), token)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, nil
	}
	// 有效令牌：把身份记进请求作用域（访问日志与聚合日志由此得到 deviceId）。
	reqctx.NoteDevice(r.Context(), device.DeviceID)
	reqctx.NoteAgent(r.Context(), device.AgentID)
	return &device, nil
}

// charge 把这次调用记到调用方的预算上；预算用尽返回 false（调用方回 429）。
//
// 命中限流的那次既没有读行、也没有写库（调用方在 charge 通过之后才动 store）。
func (h *Handlers) charge(r *http.Request, write bool, device *store.Device) bool {
	type bucket struct {
		limiter *ratelimit.Limiter
		key     string
	}
	buckets := make([]bucket, 0, 2)
	if write {
		buckets = append(buckets, bucket{h.writeLimiter, h.clientID(r)})
		if device != nil {
			buckets = append(buckets, bucket{h.writeDeviceLimiter, device.DeviceID})
		}
	} else {
		buckets = append(buckets, bucket{h.readLimiter, h.clientID(r)})
	}
	for _, entry := range buckets {
		if entry.limiter.Blocked(entry.key) {
			return false
		}
	}
	for _, entry := range buckets {
		entry.limiter.CountFailure(entry.key, false)
	}
	return true
}

// ── 请求体与字段校验 ────────────────────────────────────────────────────────

// problem 是一次可以原样写出的 400/413。
type problem struct {
	status  int
	code    string
	message string
}

func (p *problem) write(w http.ResponseWriter) {
	writeProblem(w, p.status, p.code, p.message)
}

func badRequest(message string) *problem {
	return &problem{status: http.StatusBadRequest, code: "feedback/bad-request", message: message}
}

func tooLong(message string) *problem {
	return &problem{status: http.StatusBadRequest, code: "feedback/too-long", message: message}
}

// readBody 按 16 KB 上限读 JSON 体；超限 413，非法 JSON 400。
//
// app 自己的 client_max_size 是 WebSocket 帧的大小（几十 MB），对公开写入接口太宽，
// 所以这里显式计数。
func (h *Handlers) readBody(w http.ResponseWriter, r *http.Request) (map[string]any, bool) {
	body, status := httpjson.ReadObject(r, MaxBodyBytes)
	switch status {
	case httpjson.TooLarge:
		writeProblem(w, http.StatusRequestEntityTooLarge, "feedback/too-large",
			"the request body may be at most 16 KB")
		return nil, false
	case httpjson.Invalid:
		writeProblem(w, http.StatusBadRequest, "feedback/bad-request", "body must be a JSON object")
		return nil, false
	}
	return body, true
}

// textOf 是用户正文（去首尾空白）；空、类型不对、超长按契约分别拒绝。
func textOf(body map[string]any) (string, *problem) {
	text, ok := body["text"].(string)
	if !ok {
		return "", badRequest("text is required")
	}
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return "", badRequest("text must not be blank")
	}
	if utf8.RuneCountInString(trimmed) > MaxTextChars || len(trimmed) > MaxTextBytes {
		return "", tooLong("text may be at most 4000 characters / 8000 bytes")
	}
	return trimmed, nil
}

// subjectOf 是可选主题（≤80 字符）：去首尾空白，空白按未填处理（不是错误）。
func subjectOf(body map[string]any) (*string, *problem) {
	value, present := body["subject"]
	if !present || value == nil {
		return nil, nil
	}
	text, ok := value.(string)
	if !ok {
		return nil, badRequest("subject must be a string")
	}
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return nil, nil
	}
	if utf8.RuneCountInString(trimmed) > store.MaxSubjectChars {
		return nil, tooLong("subject may be at most 80 characters")
	}
	return &trimmed, nil
}

// techOf 是自动附带的技术信息（版本/机型/iOS）；各 64 字符上限，不去空白。
func techOf(body map[string]any, key string) (*string, *problem) {
	value, present := body[key]
	if !present || value == nil {
		return nil, nil
	}
	text, ok := value.(string)
	if !ok {
		return nil, badRequest(key + " must be a string")
	}
	if utf8.RuneCountInString(text) > MaxTechChars {
		return nil, tooLong(key + " may be at most 64 characters")
	}
	if text == "" {
		return nil, nil
	}
	return &text, nil
}

// formatOf 校验可选的 format；非法取值 400，缺字段放行。
//
// 契约里带 format 的是**我们发出**的正文；用户提交的正文永远是 text，所以这里
// 只做校验，返回值不参与写入。
func formatOf(body map[string]any) *problem {
	value, present := body["format"]
	if !present || value == nil {
		return nil
	}
	text, ok := value.(string)
	if !ok {
		return badRequest("format must be text or html")
	}
	if _, err := store.CleanFeedbackFormat(text); err != nil {
		return badRequest("format must be text or html")
	}
	return nil
}

// clientRefOf 是幂等键：≤64 字符且只允许 [A-Za-z0-9._-]（空字符串等于没带）。
func clientRefOf(body map[string]any) (*string, *problem) {
	value, present := body["clientRef"]
	if !present || value == nil {
		return nil, nil
	}
	text, ok := value.(string)
	if !ok {
		return nil, badRequest("clientRef may be at most 64 characters of [A-Za-z0-9._-]")
	}
	if text == "" {
		return nil, nil
	}
	if utf8.RuneCountInString(text) > MaxClientRefChars || !clientRefPattern.MatchString(text) {
		return nil, badRequest("clientRef may be at most 64 characters of [A-Za-z0-9._-]")
	}
	return &text, nil
}

// ticketPairsOf 是 tickets 里的 (threadId, ticketKey) 对，最多 50 对。
func ticketPairsOf(body map[string]any) ([]store.TicketPair, *problem) {
	value, present := body["tickets"]
	if !present || value == nil {
		return []store.TicketPair{}, nil
	}
	items, ok := value.([]any)
	if !ok || len(items) > MaxTickets {
		return nil, badRequest("tickets may hold at most 50 entries")
	}
	pairs := make([]store.TicketPair, 0, len(items))
	for _, item := range items {
		ticket, ok := item.(map[string]any)
		if !ok {
			return nil, badRequest("each ticket needs threadId and ticketKey")
		}
		threadID, okThread := ticket["threadId"].(string)
		ticketKey, okTicket := ticket["ticketKey"].(string)
		if !okThread || threadID == "" || !okTicket || ticketKey == "" {
			return nil, badRequest("each ticket needs threadId and ticketKey")
		}
		pairs = append(pairs, store.TicketPair{
			ThreadID: threadID, TicketHash: store.SHA256Hex(ticketKey),
		})
	}
	return pairs, nil
}

// idListOf 是一串 id（去重、限长）；缺字段等于空表。
func idListOf(body map[string]any, key string) ([]string, *problem) {
	value, present := body[key]
	if !present || value == nil {
		return []string{}, nil
	}
	items, ok := value.([]any)
	if !ok || len(items) > MaxIDs {
		return nil, badRequest(key + " must be a list of ids")
	}
	ids := make([]string, 0, len(items))
	seen := make(map[string]struct{}, len(items))
	for _, item := range items {
		text, ok := item.(string)
		if !ok || text == "" {
			return nil, badRequest(key + " must be a list of ids")
		}
		if _, done := seen[text]; done {
			continue
		}
		seen[text] = struct{}{}
		ids = append(ids, text)
	}
	return ids, nil
}

// messagesLimitOf：messagesPerThread 默认 50，上限 200（超出取最近的 200 条）。
func messagesLimitOf(body map[string]any) (int, *problem) {
	value, present := body["messagesPerThread"]
	if !present {
		return DefaultMessagesPerThread, nil
	}
	limit, ok := httpjson.Int(value)
	if !ok || limit < 1 {
		return 0, badRequest("messagesPerThread must be a positive integer")
	}
	if limit > MaxMessagesPerThread {
		return MaxMessagesPerThread, nil
	}
	return int(limit), nil
}

// withNotices 复刻 Python 的 `bool(body.get("notices", True))`：缺省为真。
func withNotices(body map[string]any) bool {
	value, present := body["notices"]
	if !present {
		return true
	}
	switch typed := value.(type) {
	case nil:
		return false
	case bool:
		return typed
	case string:
		return typed != ""
	case []any:
		return len(typed) > 0
	case map[string]any:
		return len(typed) > 0
	case json.Number:
		// Python 的 bool(0) / bool(0.0) 是假，其余数字是真。
		number, err := typed.Float64()
		if err != nil {
			return true
		}
		return number != 0
	default:
		return true
	}
}

// ── 出网形状 ────────────────────────────────────────────────────────────────

func publicMessages(messages []store.FeedbackMessage) []publicMessage {
	out := make([]publicMessage, 0, len(messages))
	for _, message := range messages {
		out = append(out, publicMessage{
			MessageID: message.MessageID, Author: message.Author, Body: message.Body,
			Format: message.Format, CreatedAt: message.CreatedAt,
		})
	}
	return out
}

// ── 响应写入 ────────────────────────────────────────────────────────────────

func writeProblem(w http.ResponseWriter, status int, code, message string) {
	apierr.Write(w, status, code, message, nil)
}

// writeProblemFor 与 writeProblem 相同；5xx 额外带上这次请求的 requestId。
func writeProblemFor(w http.ResponseWriter, r *http.Request, status int, code, message string) {
	if status >= 500 {
		apierr.WriteWithRequestID(w, status, code, message, nil, reqctx.ID(r.Context()))
		return
	}
	apierr.Write(w, status, code, message, nil)
}

// writeRateLimited 是四个端点共用的 429。
func writeRateLimited(w http.ResponseWriter) {
	writeProblem(w, http.StatusTooManyRequests, "feedback/rate-limited",
		"too many feedback requests; try again later")
}

// writeNotFound 是"线程不存在"与"凭据不匹配"共用的响应：逐字节相同。
func writeNotFound(w http.ResponseWriter) {
	writeProblem(w, http.StatusNotFound, "feedback/not-found", "thread not found")
}

// storeFailure 把仓储错误兜底成 5xx JSON：busy → 503 + Retry-After，其余 500。
func (h *Handlers) storeFailure(w http.ResponseWriter, r *http.Request, code, message string,
	err error) {
	if store.IsBusy(err) {
		w.Header().Set("Retry-After", "1")
		h.log.Warn("relay: feedback request failed",
			"requestId", reqctx.ID(r.Context()), "route", r.Pattern,
			"status", http.StatusServiceUnavailable, "error", err)
		writeProblemFor(w, r, http.StatusServiceUnavailable, "db/busy",
			"the relay database is busy; retry shortly")
		return
	}
	h.log.Error("relay: feedback request failed",
		"requestId", reqctx.ID(r.Context()), "route", r.Pattern, "error", err)
	writeProblemFor(w, r, http.StatusInternalServerError, code, message)
}

// ── 小工具 ──────────────────────────────────────────────────────────────────

// deviceValue 在设备为空时返回 nil（匿名写入落 NULL）。
func deviceValue(device *store.Device, pick func(store.Device) *string) *string {
	if device == nil {
		return nil
	}
	return pick(*device)
}

func stringOf(value any) string {
	text, _ := value.(string)
	return text
}

func ptrString(value string) *string { return &value }
