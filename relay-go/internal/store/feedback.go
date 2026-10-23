package store

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// 反馈通道（014）的写入上限与取值定义。
//
// 只有一处：HTTP 面（internal/feedback）按契约回 400，owner 侧命令（admin）也读
// 这一份，两张表的默认值同源。不要在别处再抄一个 80 或 "text"。
const (
	// MaxSubjectChars 是线程主题的字符上限（specs/014 的 subject）。
	MaxSubjectChars = 80
	// DefaultFeedbackFormat 是"没给格式"时落到两张表里的值。
	DefaultFeedbackFormat = "text"
	// FeedbackFormatText 由手机按 Markdown 渲染。
	FeedbackFormatText = "text"
	// FeedbackFormatHTML 走 App 里锁死的 HTML 容器（报告类正文）。
	FeedbackFormatHTML = "html"
)

// feedbackFormats 是合法正文格式的集合；公开判定走 IsFeedbackFormat。
var feedbackFormats = map[string]struct{}{
	FeedbackFormatText: {},
	FeedbackFormatHTML: {},
}

// IsFeedbackFormat 报告一个格式是否属于契约允许的取值。
func IsFeedbackFormat(value string) bool {
	_, ok := feedbackFormats[value]
	return ok
}

// FeedbackFormats 返回合法取值的稳定顺序（只读，调用方不得修改）。
func FeedbackFormats() []string { return []string{FeedbackFormatText, FeedbackFormatHTML} }

// FeedbackMessage 是一行 feedbackMessages。
//
// 字段顺序与 Python SQL 的列序一致：admin 的 feedback-show 直接序列化这个结构，
// 键序因此与 admin.py 的输出相同。
type FeedbackMessage struct {
	MessageID string  `json:"messageId"`
	ThreadID  string  `json:"threadId"`
	Author    string  `json:"author"`
	Body      string  `json:"body"`
	CreatedAt int64   `json:"createdAt"`
	ClientRef *string `json:"clientRef"`
	Format    string  `json:"format"`
}

// FeedbackThread 是一行 feedbackThreads 加派生字段。
//
// 同样的理由：列序即 JSON 键序，`feedback-show` 的输出与 admin.py 逐键对齐。
// `Messages` 的零值是空切片（不是 nil），序列化成 `[]` 而不是 `null`。
type FeedbackThread struct {
	ThreadID      string            `json:"threadId"`
	TicketHash    string            `json:"ticketHash"`
	AccountID     *string           `json:"accountId"`
	DeviceID      *string           `json:"deviceId"`
	AppVersion    *string           `json:"appVersion"`
	DeviceModel   *string           `json:"deviceModel"`
	SystemVersion *string           `json:"systemVersion"`
	CreatedAt     int64             `json:"createdAt"`
	LastMessageAt int64             `json:"lastMessageAt"`
	OwnerReadAt   *int64            `json:"ownerReadAt"`
	UserReadAt    *int64            `json:"userReadAt"`
	Status        string            `json:"status"`
	ClientRef     *string           `json:"clientRef"`
	Subject       *string           `json:"subject"`
	Messages      []FeedbackMessage `json:"messages"`
	MessageCount  int               `json:"messageCount"`
	Unread        int               `json:"unread"`
}

// TicketPair 是一对 (threadId, 取件凭据的 SHA-256)。
type TicketPair struct {
	ThreadID   string
	TicketHash string
}

// CreateFeedbackThreadInput 是建线程的全部入参（`subject` 为 nil = 用户没填）。
type CreateFeedbackThreadInput struct {
	TicketHash    string
	Text          string
	AccountID     *string
	DeviceID      *string
	AppVersion    *string
	DeviceModel   *string
	SystemVersion *string
	ClientRef     *string
	Subject       *string
	// At 是毫秒时间戳；0 表示此刻（单测用它固定时间）。
	At int64
}

// CreatedFeedbackThread 是建线程的结果；Created=false 表示 clientRef 命中了既有线程。
type CreatedFeedbackThread struct {
	ThreadID      string
	CreatedAt     int64
	LastMessageAt int64
	Created       bool
}

// AppendFeedbackInput 是往线程里加一条留言的全部入参。
type AppendFeedbackInput struct {
	ThreadID string
	Body     string
	// Author 是 "user"（手机补充）或 "owner"（回信）；空串按 "user"。
	Author string
	// Format 空串按默认 text；非法取值在建之前拒绝。
	Format    string
	ClientRef *string
	// BindDeviceID/BindAccountID 给匿名线程补绑定（匿名提交后来配对了）。
	BindDeviceID  *string
	BindAccountID *string
	At            int64
}

// AppendedFeedbackMessage 是加留言的结果；Created=false 表示 clientRef 命中既有留言。
type AppendedFeedbackMessage struct {
	MessageID string
	ThreadID  string
	CreatedAt int64
	Created   bool
}

// CreateNoticeInput 是发一条通知的全部入参。
type CreateNoticeInput struct {
	Body       string
	Subject    *string
	AccountIDs []string
	Format     string
	CreatedBy  *string
	At         int64
}

// CreatedNotice 是发通知的结果（Recipients 是去重后的账号数）。
type CreatedNotice struct {
	NoticeID   string
	CreatedAt  int64
	Recipients int
}

// Notice 是投给某个账号的一条通知（含账号级已读）。
type Notice struct {
	NoticeID  string  `json:"noticeId"`
	Subject   *string `json:"subject"`
	Body      string  `json:"body"`
	Format    string  `json:"format"`
	CreatedAt int64   `json:"createdAt"`
	CreatedBy *string `json:"createdBy"`
	ReadAt    *int64  `json:"readAt"`
	Read      bool    `json:"read"`
}

// FeedbackDigestEntry 是 owner 清单里一条线程的摘要（首条留言）。
type FeedbackDigestEntry struct {
	Subject      *string
	Excerpt      string
	Format       string
	FirstReplyAt *int64
}

const feedbackThreadColumns = "threadId, ticketHash, accountId, deviceId, appVersion," +
	" deviceModel, systemVersion, createdAt, lastMessageAt, ownerReadAt, userReadAt," +
	" status, clientRef, subject"

const feedbackMessageColumns = "messageId, threadId, author, body, createdAt, clientRef, format"

// NewFeedbackTicket 生成取件凭据：`fk_` + 43 字符 base64url（32 随机字节）。
//
// 与 Python 的 `"fk_" + secrets.token_urlsafe(32)` 同格式（46 字符）；newToken 负责
// 拼那次下划线，所以前缀只给 "fk"。库里只存它的 SHA-256。
func NewFeedbackTicket() string { return newToken("fk") }

// CleanFeedbackFormat 规范化正文格式：去首尾空白，空按默认 text，其余只认两个取值。
func CleanFeedbackFormat(value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return DefaultFeedbackFormat, nil
	}
	if !IsFeedbackFormat(trimmed) {
		return "", newStoreError("format must be one of: %s", strings.Join(FeedbackFormats(), ", "))
	}
	return trimmed, nil
}

// CleanFeedbackSubject 规范化线程主题：去首尾空白，空存 NULL，超过 80 字符报错。
//
// 接口层（internal/feedback）先按契约给 400；这里是落到库前的最后一道，owner 侧的
// `feedback-reply --subject` 只有这一道。
func CleanFeedbackSubject(value *string) (*string, error) {
	if value == nil {
		return nil, nil
	}
	trimmed := strings.TrimSpace(*value)
	if len([]rune(trimmed)) > MaxSubjectChars {
		return nil, newStoreError("subject may be at most %d characters", MaxSubjectChars)
	}
	if trimmed == "" {
		return nil, nil
	}
	return &trimmed, nil
}

// CreateFeedbackThread 建一条线程，并把用户原文作为线程里的第一条留言。
//
// clientRef 命中唯一索引时**不新建**：返回既有那条（Created=false），并把 ticketHash
// 换成这一次带来的哈希——重试发生在上一条响应丢了之后，所以重试必须拿到一把能用的
// 凭据。同一个 clientRef 来自别的来源时返回 *Conflict，不把线程交出去。
func (s *Store) CreateFeedbackThread(ctx context.Context,
	in CreateFeedbackThreadInput) (CreatedFeedbackThread, error) {
	subject, err := CleanFeedbackSubject(in.Subject)
	if err != nil {
		return CreatedFeedbackThread{}, err
	}
	stamp := in.At
	if stamp == 0 {
		stamp = NowMS()
	}

	var out CreatedFeedbackThread
	err = s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		if in.ClientRef != nil && *in.ClientRef != "" {
			existing, found, err := feedbackRowBy(ctx, q, "clientRef", *in.ClientRef)
			if err != nil {
				return err
			}
			if found {
				if !feedbackSourceMatches(existing, in.DeviceID, in.AccountID) {
					return newConflict("clientRef %s belongs to another source", *in.ClientRef)
				}
				if _, err := q.ExecContext(ctx,
					"UPDATE feedbackThreads SET ticketHash=? WHERE threadId=?",
					in.TicketHash, existing.ThreadID); err != nil {
					return fmt.Errorf("store: 重签反馈凭据: %w", err)
				}
				out = CreatedFeedbackThread{ThreadID: existing.ThreadID, CreatedAt: existing.CreatedAt,
					LastMessageAt: existing.LastMessageAt, Created: false}
				return nil
			}
		}

		threadID := newID("th")
		if _, err := q.ExecContext(ctx,
			"INSERT INTO feedbackThreads(threadId, ticketHash, accountId, deviceId, appVersion,"+
				" deviceModel, systemVersion, createdAt, lastMessageAt, status, clientRef, subject)"+
				" VALUES(?,?,?,?,?,?,?,?,?,'open',?,?)",
			threadID, in.TicketHash, nullStringValue(in.AccountID), nullStringValue(in.DeviceID),
			nullStringValue(in.AppVersion), nullStringValue(in.DeviceModel),
			nullStringValue(in.SystemVersion), stamp, stamp, nullStringValue(in.ClientRef),
			nullStringValue(subject)); err != nil {
			return fmt.Errorf("store: 写反馈线程: %w", err)
		}
		// 用户自己敲进来的正文永远是纯文本：format 在这里写死 'text'，不给参数。
		if _, err := q.ExecContext(ctx,
			"INSERT INTO feedbackMessages(messageId, threadId, author, body, format, createdAt)"+
				" VALUES(?,?,'user',?,'text',?)",
			newID("fm"), threadID, in.Text, stamp); err != nil {
			return fmt.Errorf("store: 写反馈留言: %w", err)
		}
		out = CreatedFeedbackThread{ThreadID: threadID, CreatedAt: stamp,
			LastMessageAt: stamp, Created: true}
		return nil
	})
	if err != nil {
		return CreatedFeedbackThread{}, err
	}
	return out, nil
}

// SetFeedbackSubject 改一条线程的主题；线程不存在返回 false。
//
// 只动这一列，不碰 lastMessageAt/status——改标题不是一次往返。
func (s *Store) SetFeedbackSubject(ctx context.Context, threadID string, subject *string) (bool, error) {
	cleaned, err := CleanFeedbackSubject(subject)
	if err != nil {
		return false, err
	}
	var changed bool
	err = s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		result, err := q.ExecContext(ctx,
			"UPDATE feedbackThreads SET subject=? WHERE threadId=?",
			nullStringValue(cleaned), threadID)
		if err != nil {
			return fmt.Errorf("store: 改反馈主题: %w", err)
		}
		affected, err := result.RowsAffected()
		if err != nil {
			return fmt.Errorf("store: 改反馈主题: %w", err)
		}
		changed = affected > 0
		return nil
	})
	return changed, err
}

// AppendFeedbackMessage 在线程里加一条留言；线程不存在返回 (nil, nil)。
//
// author="user" 把线程拨回 open，author="owner" 置 replied。clientRef 命中唯一索引
// 时返回既有那条、不重复写。带设备时顺带补上匿名线程的绑定：匿名提交后来配对了，
// 这台设备也能找回来。
func (s *Store) AppendFeedbackMessage(ctx context.Context,
	in AppendFeedbackInput) (*AppendedFeedbackMessage, error) {
	cleanedFormat, err := CleanFeedbackFormat(in.Format)
	if err != nil {
		return nil, err
	}
	author := in.Author
	if author == "" {
		author = "user"
	}
	status := "open"
	if author == "owner" {
		status = "replied"
	}
	stamp := in.At
	if stamp == 0 {
		stamp = NowMS()
	}

	var out *AppendedFeedbackMessage
	err = s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		thread, found, err := feedbackRowBy(ctx, q, "threadId", in.ThreadID)
		if err != nil {
			return err
		}
		if !found {
			return nil
		}
		if in.BindDeviceID != nil && *in.BindDeviceID != "" && thread.DeviceID == nil {
			if _, err := q.ExecContext(ctx,
				"UPDATE feedbackThreads SET deviceId=?, accountId=? WHERE threadId=?",
				*in.BindDeviceID, nullStringValue(in.BindAccountID), in.ThreadID); err != nil {
				return fmt.Errorf("store: 绑定反馈线程: %w", err)
			}
		}
		if in.ClientRef != nil && *in.ClientRef != "" {
			existing, found, err := feedbackMessageRowBy(ctx, q, *in.ClientRef)
			if err != nil {
				return err
			}
			if found {
				out = &AppendedFeedbackMessage{MessageID: existing.MessageID,
					ThreadID: existing.ThreadID, CreatedAt: existing.CreatedAt, Created: false}
				return nil
			}
		}
		messageID := newID("fm")
		if _, err := q.ExecContext(ctx,
			"INSERT INTO feedbackMessages(messageId, threadId, author, body, format, createdAt,"+
				" clientRef) VALUES(?,?,?,?,?,?,?)",
			messageID, in.ThreadID, author, in.Body, cleanedFormat, stamp,
			nullStringValue(in.ClientRef)); err != nil {
			return fmt.Errorf("store: 写反馈留言: %w", err)
		}
		if _, err := q.ExecContext(ctx,
			"UPDATE feedbackThreads SET lastMessageAt=?, status=? WHERE threadId=?",
			stamp, status, in.ThreadID); err != nil {
			return fmt.Errorf("store: 更新反馈线程: %w", err)
		}
		out = &AppendedFeedbackMessage{MessageID: messageID, ThreadID: in.ThreadID,
			CreatedAt: stamp, Created: true}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// CreateNotice 发一条通知，并给每个收件账号写一行未读投递。
//
// 收件人是账号：一封通知对一个账号恰好一行，账号下有几台设备都不影响投递。
// 这里只去重，不核对账号是否存在（那是命令层的调度问题）。
func (s *Store) CreateNotice(ctx context.Context, in CreateNoticeInput) (CreatedNotice, error) {
	cleanedFormat, err := CleanFeedbackFormat(in.Format)
	if err != nil {
		return CreatedNotice{}, err
	}
	stamp := in.At
	if stamp == 0 {
		stamp = NowMS()
	}
	targets := dedupeNonEmpty(in.AccountIDs)
	noticeID := newID("nt")
	err = s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		if _, err := q.ExecContext(ctx,
			"INSERT INTO notices(noticeId, subject, body, format, createdAt, createdBy)"+
				" VALUES(?,?,?,?,?,?)",
			noticeID, nullStringValue(in.Subject), in.Body, cleanedFormat, stamp,
			nullStringValue(in.CreatedBy)); err != nil {
			return fmt.Errorf("store: 写通知: %w", err)
		}
		for _, accountID := range targets {
			if _, err := q.ExecContext(ctx,
				"INSERT OR IGNORE INTO noticeDeliveries(noticeId, accountId, createdAt)"+
					" VALUES(?,?,?)", noticeID, accountID, stamp); err != nil {
				return fmt.Errorf("store: 写通知投递: %w", err)
			}
		}
		return nil
	})
	if err != nil {
		return CreatedNotice{}, err
	}
	return CreatedNotice{NoticeID: noticeID, CreatedAt: stamp, Recipients: len(targets)}, nil
}

// FeedbackThread 读一条线程（最近 N 条留言 + 用户侧未读 + 留言总数）；取不到返回 nil。
//
// ticketHash 给了就必须匹配，否则和"线程不存在"一样返回 nil——调用方对这两种情况
// 给同一个答复，不泄露线程是否存在。传 nil 是内部/owner 路径。
func (s *Store) FeedbackThread(ctx context.Context, threadID string,
	ticketHash *string, messagesPerThread int) (*FeedbackThread, error) {
	thread, found, err := feedbackRowBy(ctx, s.db, "threadId", threadID)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, nil
	}
	if ticketHash != nil && subtle.ConstantTimeCompare([]byte(thread.TicketHash),
		[]byte(*ticketHash)) != 1 {
		return nil, nil
	}
	payload, err := s.feedbackPayload(ctx, s.db, thread, messagesPerThread)
	if err != nil {
		return nil, err
	}
	return &payload, nil
}

// FeedbackThreadsByTickets 读凭据命中的线程；同一个线程只出现一次。
//
// 逐个按主键取：每行的凭据哈希各不相同，没法用一条 IN 查完；接口层已经把对子数
// 限制在 50 以内。
func (s *Store) FeedbackThreadsByTickets(ctx context.Context,
	pairs []TicketPair, messagesPerThread int) ([]FeedbackThread, error) {
	found := make([]FeedbackThread, 0, len(pairs))
	seen := make(map[string]struct{}, len(pairs))
	for _, pair := range pairs {
		if pair.ThreadID == "" || pair.TicketHash == "" {
			continue
		}
		if _, done := seen[pair.ThreadID]; done {
			continue
		}
		thread, err := s.FeedbackThread(ctx, pair.ThreadID, &pair.TicketHash, messagesPerThread)
		if err != nil {
			return nil, err
		}
		if thread == nil {
			continue
		}
		seen[pair.ThreadID] = struct{}{}
		found = append(found, *thread)
	}
	return found, nil
}

// FeedbackThreadsByDevice 读绑定到这台设备**或它所属账号**的线程，最近的在前。
//
// 账号也算命中：重装后重新配对换来一个新的 deviceId，只有账号还是同一个，
// "重装后重新配对即可找回"靠的就是这一条。
func (s *Store) FeedbackThreadsByDevice(ctx context.Context, deviceID string,
	accountID *string, messagesPerThread int) ([]FeedbackThread, error) {
	var account any
	if accountID != nil {
		account = *accountID
	}
	rows, err := s.db.QueryContext(ctx, "SELECT "+feedbackThreadColumns+
		" FROM feedbackThreads WHERE deviceId=?"+
		" OR (accountId IS NOT NULL AND accountId=?) ORDER BY lastMessageAt DESC",
		deviceID, account)
	if err != nil {
		return nil, fmt.Errorf("store: 按设备读反馈线程: %w", err)
	}
	defer rows.Close()

	threads := make([]FeedbackThread, 0, 4)
	for rows.Next() {
		thread, err := scanFeedbackThread(rows)
		if err != nil {
			return nil, fmt.Errorf("store: 读反馈线程行: %w", err)
		}
		threads = append(threads, thread)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读反馈线程行: %w", err)
	}
	for index := range threads {
		payload, err := s.feedbackPayload(ctx, s.db, threads[index], messagesPerThread)
		if err != nil {
			return nil, err
		}
		threads[index] = payload
	}
	return threads, nil
}

// MarkThreadRead 把用户侧的 userReadAt 推到 uptoMS；默认推到最后一条 owner 留言。
//
// 只前进不后退，所以重复调用结果不变（幂等）。线程不存在返回 false；还没有 owner
// 留言时不动——那时未读本来就是 0。
func (s *Store) MarkThreadRead(ctx context.Context, threadID string,
	uptoMS *int64) (bool, error) {
	var exists bool
	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		thread, found, err := feedbackRowBy(ctx, q, "threadId", threadID)
		if err != nil {
			return err
		}
		if !found {
			return nil
		}
		exists = true
		stamp := uptoMS
		if stamp == nil {
			var latest sql.NullInt64
			if err := q.QueryRowContext(ctx,
				"SELECT MAX(createdAt) FROM feedbackMessages WHERE threadId=? AND author='owner'",
				threadID).Scan(&latest); err != nil {
				return fmt.Errorf("store: 读最后一条回信: %w", err)
			}
			if latest.Valid {
				value := latest.Int64
				stamp = &value
			}
		}
		if stamp == nil {
			return nil
		}
		if thread.UserReadAt != nil && *stamp <= *thread.UserReadAt {
			return nil
		}
		if _, err := q.ExecContext(ctx,
			"UPDATE feedbackThreads SET userReadAt=? WHERE threadId=?",
			*stamp, threadID); err != nil {
			return fmt.Errorf("store: 标记反馈已读: %w", err)
		}
		return nil
	})
	return exists, err
}

// NoticesForAccount 读投给这个账号的通知，最近的在前；read 是账号级已读。
func (s *Store) NoticesForAccount(ctx context.Context, accountID string,
	limit int) ([]Notice, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := s.db.QueryContext(ctx,
		"SELECT n.noticeId AS noticeId, n.subject AS subject, n.body AS body,"+
			" n.format AS format, n.createdAt AS createdAt, n.createdBy AS createdBy,"+
			" d.readAt AS readAt"+
			" FROM notices n JOIN noticeDeliveries d ON d.noticeId = n.noticeId"+
			" WHERE d.accountId=? ORDER BY n.createdAt DESC, n.noticeId DESC LIMIT ?",
		accountID, limit)
	if err != nil {
		return nil, fmt.Errorf("store: 读通知: %w", err)
	}
	defer rows.Close()

	notices := make([]Notice, 0, 8)
	for rows.Next() {
		var (
			notice    Notice
			subject   sql.NullString
			format    sql.NullString
			createdBy sql.NullString
			readAt    sql.NullInt64
		)
		if err := rows.Scan(&notice.NoticeID, &subject, &notice.Body, &format,
			&notice.CreatedAt, &createdBy, &readAt); err != nil {
			return nil, fmt.Errorf("store: 读通知行: %w", err)
		}
		notice.Subject = nullString(subject)
		notice.Format = feedbackFormatOr(format, DefaultFeedbackFormat)
		notice.CreatedBy = nullString(createdBy)
		notice.ReadAt = nullInt64(readAt)
		notice.Read = readAt.Valid
		notices = append(notices, notice)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读通知行: %w", err)
	}
	return notices, nil
}

// MarkNoticesRead 把这个账号的这几条通知投递行标已读；返回被改的行数。
//
// 账号下任一设备调用即全账号已读：readAt IS NULL 才写，所以第二台设备再标一次是
// 0 行、不倒退。
func (s *Store) MarkNoticesRead(ctx context.Context, accountID string,
	noticeIDs []string, at int64) (int64, error) {
	ids := dedupeNonEmpty(noticeIDs)
	if len(ids) == 0 {
		return 0, nil
	}
	if at == 0 {
		at = NowMS()
	}
	marks := strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")
	args := make([]any, 0, len(ids)+2)
	args = append(args, at, accountID)
	for _, id := range ids {
		args = append(args, id)
	}

	var changed int64
	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		result, err := q.ExecContext(ctx,
			"UPDATE noticeDeliveries SET readAt=? WHERE accountId=? AND readAt IS NULL"+
				" AND noticeId IN ("+marks+")", args...)
		if err != nil {
			return fmt.Errorf("store: 标记通知已读: %w", err)
		}
		affected, err := result.RowsAffected()
		if err != nil {
			return fmt.Errorf("store: 标记通知已读: %w", err)
		}
		changed = affected
		return nil
	})
	if err != nil {
		return 0, err
	}
	return changed, nil
}

// OwnerUnreadCounts 是 owner 还没看过的用户消息数，按线程。
func (s *Store) OwnerUnreadCounts(ctx context.Context) (map[string]int, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT m.threadId AS threadId, COUNT(*) AS unread FROM feedbackMessages m"+
			" JOIN feedbackThreads t ON t.threadId = m.threadId"+
			" WHERE m.author='user' AND (t.ownerReadAt IS NULL OR m.createdAt > t.ownerReadAt)"+
			" GROUP BY m.threadId")
	if err != nil {
		return nil, fmt.Errorf("store: 读 owner 未读: %w", err)
	}
	defer rows.Close()

	counts := map[string]int{}
	for rows.Next() {
		var (
			threadID string
			unread   int
		)
		if err := rows.Scan(&threadID, &unread); err != nil {
			return nil, fmt.Errorf("store: 读 owner 未读行: %w", err)
		}
		counts[threadID] = unread
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读 owner 未读行: %w", err)
	}
	return counts, nil
}

// TouchOwnerRead 记下 owner 读过这条线程；线程不存在返回 false。
func (s *Store) TouchOwnerRead(ctx context.Context, threadID string, at int64) (bool, error) {
	if at == 0 {
		at = NowMS()
	}
	var changed bool
	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		result, err := q.ExecContext(ctx,
			"UPDATE feedbackThreads SET ownerReadAt=? WHERE threadId=?", at, threadID)
		if err != nil {
			return fmt.Errorf("store: 标记 owner 已读: %w", err)
		}
		affected, err := result.RowsAffected()
		if err != nil {
			return fmt.Errorf("store: 标记 owner 已读: %w", err)
		}
		changed = affected > 0
		return nil
	})
	return changed, err
}

// ListFeedbackThreads 是 owner 清单：按最近活动倒序的线程。
//
// status 只认 open/replied（nil 就是全部），sinceMS 卡 createdAt。默认不带留言
// （messagesPerThread=0）——清单只要摘要，完整往返走 FeedbackThread。
func (s *Store) ListFeedbackThreads(ctx context.Context, status *string, sinceMS *int64,
	limit int, messagesPerThread int) ([]FeedbackThread, error) {
	clauses := make([]string, 0, 2)
	params := make([]any, 0, 4)
	if status != nil && *status != "" {
		clauses = append(clauses, "status=?")
		params = append(params, *status)
	}
	if sinceMS != nil {
		clauses = append(clauses, "createdAt >= ?")
		params = append(params, *sinceMS)
	}
	where := ""
	if len(clauses) > 0 {
		where = " WHERE " + strings.Join(clauses, " AND ")
	}
	params = append(params, limit)

	rows, err := s.db.QueryContext(ctx,
		"SELECT "+feedbackThreadColumns+" FROM feedbackThreads"+where+
			" ORDER BY lastMessageAt DESC LIMIT ?", params...)
	if err != nil {
		return nil, fmt.Errorf("store: 读反馈清单: %w", err)
	}
	defer rows.Close()

	threads := make([]FeedbackThread, 0, 16)
	for rows.Next() {
		thread, err := scanFeedbackThread(rows)
		if err != nil {
			return nil, fmt.Errorf("store: 读反馈清单行: %w", err)
		}
		threads = append(threads, thread)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读反馈清单行: %w", err)
	}
	for index := range threads {
		payload, err := s.feedbackPayload(ctx, s.db, threads[index], messagesPerThread)
		if err != nil {
			return nil, err
		}
		threads[index] = payload
	}
	return threads, nil
}

// DeleteFeedbackThread 连线程带它的留言一起删；返回删掉的留言数。
//
// 线程不存在返回 *NotFound，调用方据此报错而不是默默成功。
func (s *Store) DeleteFeedbackThread(ctx context.Context, threadID string) (int64, error) {
	var removed int64
	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		if _, found, err := feedbackRowBy(ctx, q, "threadId", threadID); err != nil {
			return err
		} else if !found {
			return newNotFound("feedback thread %s does not exist", threadID)
		}
		result, err := q.ExecContext(ctx,
			"DELETE FROM feedbackMessages WHERE threadId=?", threadID)
		if err != nil {
			return fmt.Errorf("store: 删反馈留言: %w", err)
		}
		affected, err := result.RowsAffected()
		if err != nil {
			return fmt.Errorf("store: 删反馈留言: %w", err)
		}
		removed = affected
		if _, err := q.ExecContext(ctx,
			"DELETE FROM feedbackThreads WHERE threadId=?", threadID); err != nil {
			return fmt.Errorf("store: 删反馈线程: %w", err)
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return removed, nil
}

// FeedbackDigest 读每条线程的**首条**留言摘要、主题与首条 owner 回信时间；只读。
//
// 清单默认不带留言，而 owner 要的两个数都在消息表里；一次查完，不逐线程再查。
// excerpt 按字符截（Python 的 body[:80] 数的是码点），不按字节。
func (s *Store) FeedbackDigest(ctx context.Context, threadIDs []string,
	excerptChars int) (map[string]FeedbackDigestEntry, error) {
	ids := dedupeNonEmpty(threadIDs)
	if len(ids) == 0 {
		return map[string]FeedbackDigestEntry{}, nil
	}
	if excerptChars <= 0 {
		excerptChars = 80
	}
	marks := strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")
	args := make([]any, 0, len(ids))
	for _, id := range ids {
		args = append(args, id)
	}

	subjects := make(map[string]*string, len(ids))
	rows, err := s.db.QueryContext(ctx,
		"SELECT threadId, subject FROM feedbackThreads WHERE threadId IN ("+marks+")", args...)
	if err != nil {
		return nil, fmt.Errorf("store: 读反馈主题: %w", err)
	}
	for rows.Next() {
		var (
			threadID string
			subject  sql.NullString
		)
		if err := rows.Scan(&threadID, &subject); err != nil {
			rows.Close()
			return nil, fmt.Errorf("store: 读反馈主题行: %w", err)
		}
		subjects[threadID] = nullString(subject)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, fmt.Errorf("store: 读反馈主题行: %w", err)
	}
	rows.Close()

	digest := make(map[string]FeedbackDigestEntry, len(ids))
	rows, err = s.db.QueryContext(ctx,
		"SELECT threadId, author, body, format, createdAt FROM feedbackMessages"+
			" WHERE threadId IN ("+marks+") ORDER BY threadId, createdAt, rowid", args...)
	if err != nil {
		return nil, fmt.Errorf("store: 读反馈摘要: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var (
			threadID  string
			author    string
			body      string
			format    sql.NullString
			createdAt int64
		)
		if err := rows.Scan(&threadID, &author, &body, &format, &createdAt); err != nil {
			return nil, fmt.Errorf("store: 读反馈摘要行: %w", err)
		}
		entry, seen := digest[threadID]
		if !seen {
			entry = FeedbackDigestEntry{
				Subject: subjects[threadID],
				Excerpt: truncateRunes(body, excerptChars),
				Format:  feedbackFormatOr(format, DefaultFeedbackFormat),
			}
		}
		if author == "owner" && entry.FirstReplyAt == nil {
			value := createdAt
			entry.FirstReplyAt = &value
		}
		digest[threadID] = entry
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读反馈摘要行: %w", err)
	}
	return digest, nil
}

// feedbackPayload 给一行线程补上留言、未读与留言总数。
func (s *Store) feedbackPayload(ctx context.Context, q queryer, thread FeedbackThread,
	messagesPerThread int) (FeedbackThread, error) {
	thread.Messages = []FeedbackMessage{}
	if messagesPerThread > 0 {
		// rowid 兜同一毫秒内的插入顺序：messageId 是随机串，用它排序等于乱排。
		rows, err := q.QueryContext(ctx, "SELECT "+feedbackMessageColumns+
			" FROM feedbackMessages WHERE threadId=?"+
			" ORDER BY createdAt DESC, rowid DESC LIMIT ?", thread.ThreadID, messagesPerThread)
		if err != nil {
			return FeedbackThread{}, fmt.Errorf("store: 读反馈留言: %w", err)
		}
		recent := make([]FeedbackMessage, 0, messagesPerThread)
		for rows.Next() {
			message, err := scanFeedbackMessage(rows)
			if err != nil {
				rows.Close()
				return FeedbackThread{}, fmt.Errorf("store: 读反馈留言行: %w", err)
			}
			recent = append(recent, message)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return FeedbackThread{}, fmt.Errorf("store: 读反馈留言行: %w", err)
		}
		rows.Close()
		for index := len(recent) - 1; index >= 0; index-- {
			thread.Messages = append(thread.Messages, recent[index])
		}
	}

	var readAt any
	if thread.UserReadAt != nil {
		readAt = *thread.UserReadAt
	}
	if err := q.QueryRowContext(ctx,
		"SELECT COUNT(*) FROM feedbackMessages WHERE threadId=? AND author='owner'"+
			" AND (? IS NULL OR createdAt > ?)", thread.ThreadID, readAt, readAt).
		Scan(&thread.Unread); err != nil {
		return FeedbackThread{}, fmt.Errorf("store: 读反馈未读: %w", err)
	}
	if err := q.QueryRowContext(ctx,
		"SELECT COUNT(*) FROM feedbackMessages WHERE threadId=?", thread.ThreadID).
		Scan(&thread.MessageCount); err != nil {
		return FeedbackThread{}, fmt.Errorf("store: 读反馈留言数: %w", err)
	}
	return thread, nil
}

// feedbackRowBy 按线程表上的固定列名取一行；列名只由本文件给出，不是用户输入。
func feedbackRowBy(ctx context.Context, q queryer, column, value string) (FeedbackThread, bool, error) {
	row := q.QueryRowContext(ctx,
		"SELECT "+feedbackThreadColumns+" FROM feedbackThreads WHERE "+column+"=?", value)
	thread, err := scanFeedbackThread(row)
	if errors.Is(err, sql.ErrNoRows) {
		return FeedbackThread{}, false, nil
	}
	if err != nil {
		return FeedbackThread{}, false, fmt.Errorf("store: 读反馈线程: %w", err)
	}
	return thread, true, nil
}

// feedbackMessageRowBy 按 clientRef 取一条已有留言。
func feedbackMessageRowBy(ctx context.Context, q queryer,
	clientRef string) (FeedbackMessage, bool, error) {
	row := q.QueryRowContext(ctx,
		"SELECT "+feedbackMessageColumns+" FROM feedbackMessages WHERE clientRef=?", clientRef)
	message, err := scanFeedbackMessage(row)
	if errors.Is(err, sql.ErrNoRows) {
		return FeedbackMessage{}, false, nil
	}
	if err != nil {
		return FeedbackMessage{}, false, fmt.Errorf("store: 读反馈留言: %w", err)
	}
	return message, true, nil
}

// feedbackSourceMatches 判断这次提交是不是这条线程原来的来源（幂等重试的判据）。
//
// 匿名线程（两个字段都空）没有任何可核对的来源，只认 clientRef 本身；绑定过的
// 线程要求设备或账号对得上，否则不把线程交出去。
func feedbackSourceMatches(thread FeedbackThread, deviceID, accountID *string) bool {
	if thread.DeviceID == nil && thread.AccountID == nil {
		return true
	}
	if deviceID != nil && *deviceID != "" && thread.DeviceID != nil && *thread.DeviceID == *deviceID {
		return true
	}
	return accountID != nil && *accountID != "" && thread.AccountID != nil &&
		*thread.AccountID == *accountID
}

func scanFeedbackThread(row scanner) (FeedbackThread, error) {
	var (
		thread                                 FeedbackThread
		accountID, deviceID                    sql.NullString
		appVersion, deviceModel, systemVersion sql.NullString
		clientRef, subject                     sql.NullString
		ownerReadAt, userReadAt                sql.NullInt64
	)
	if err := row.Scan(&thread.ThreadID, &thread.TicketHash, &accountID, &deviceID,
		&appVersion, &deviceModel, &systemVersion, &thread.CreatedAt, &thread.LastMessageAt,
		&ownerReadAt, &userReadAt, &thread.Status, &clientRef, &subject); err != nil {
		return FeedbackThread{}, err
	}
	thread.AccountID = nullString(accountID)
	thread.DeviceID = nullString(deviceID)
	thread.AppVersion = nullString(appVersion)
	thread.DeviceModel = nullString(deviceModel)
	thread.SystemVersion = nullString(systemVersion)
	thread.OwnerReadAt = nullInt64(ownerReadAt)
	thread.UserReadAt = nullInt64(userReadAt)
	thread.ClientRef = nullString(clientRef)
	thread.Subject = nullString(subject)
	thread.Messages = []FeedbackMessage{}
	return thread, nil
}

func scanFeedbackMessage(row scanner) (FeedbackMessage, error) {
	var (
		message   FeedbackMessage
		clientRef sql.NullString
		format    sql.NullString
	)
	if err := row.Scan(&message.MessageID, &message.ThreadID, &message.Author, &message.Body,
		&message.CreatedAt, &clientRef, &format); err != nil {
		return FeedbackMessage{}, err
	}
	message.ClientRef = nullString(clientRef)
	message.Format = feedbackFormatOr(format, DefaultFeedbackFormat)
	return message, nil
}

// feedbackFormatOr 把可空的 format 列折成契约里的取值：缺列按 text 兜底。
func feedbackFormatOr(value sql.NullString, fallback string) string {
	if !value.Valid || strings.TrimSpace(value.String) == "" {
		return fallback
	}
	return value.String
}

// truncateRunes 按字符截断（Python 的 body[:n] 数的是码点，不是字节）。
func truncateRunes(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit])
}

// dedupeNonEmpty 去掉空串并保序去重（Python 的 list(dict.fromkeys(...))）。
func dedupeNonEmpty(values []string) []string {
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
