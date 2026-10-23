package store

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// 反馈通道的仓储层用例（014）。
//
// 断言的都是"半年后还成立"的口径：clientRef 幂等与来源核对、线程/留言的状态迁移、
// 账号级通知未读、已读只前进、删除带走留言。时间戳全部显式传入，不依赖墙钟。

func int64Ptr(value int64) *int64 { return &value }

// seedFeedback 建一条线程并返回它的 ID 与取件凭据（明文由调用方给出）。
func seedFeedback(t *testing.T, s *Store, ticket, text string, at int64) string {
	t.Helper()
	created, err := s.CreateFeedbackThread(context.Background(), CreateFeedbackThreadInput{
		TicketHash: SHA256Hex(ticket), Text: text, At: at,
	})
	if err != nil {
		t.Fatalf("CreateFeedbackThread: %v", err)
	}
	return created.ThreadID
}

func TestCreateFeedbackThreadWritesThreadAndFirstMessageInOneTransaction(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()

	created, err := s.CreateFeedbackThread(ctx, CreateFeedbackThreadInput{
		TicketHash: SHA256Hex("fk_one"), Text: "  点了新建会话一直转圈  ",
		AppVersion: stringPtr("9.9.9 (100)"), DeviceModel: stringPtr("iPhone17,1"),
		SystemVersion: stringPtr("26.0"), Subject: stringPtr("  新建会话卡住  "), At: 1_000,
	})
	if err != nil {
		t.Fatalf("CreateFeedbackThread: %v", err)
	}
	if !created.Created || !strings.HasPrefix(created.ThreadID, "th_") {
		t.Fatalf("新建结果不对：%+v", created)
	}

	thread, err := s.FeedbackThread(ctx, created.ThreadID, nil, 50)
	if err != nil || thread == nil {
		t.Fatalf("FeedbackThread: %v %v", thread, err)
	}
	if thread.Status != "open" || thread.CreatedAt != 1_000 || thread.LastMessageAt != 1_000 {
		t.Fatalf("线程字段不对：%+v", thread)
	}
	if thread.Subject == nil || *thread.Subject != "新建会话卡住" {
		t.Fatalf("主题应去首尾空白：%+v", thread.Subject)
	}
	if len(thread.Messages) != 1 || thread.MessageCount != 1 || thread.Unread != 0 {
		t.Fatalf("首条留言/计数不对：%+v", thread)
	}
	message := thread.Messages[0]
	if message.Author != "user" || message.Body != "  点了新建会话一直转圈  " {
		t.Fatalf("用户正文应原样入库（不去空白）：%+v", message)
	}
	if message.Format != "text" {
		t.Fatalf("用户提交的正文永远是 text：%q", message.Format)
	}
}

func TestCreateFeedbackThreadIsIdempotentPerClientRefAndReissuesTheTicket(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()

	first, err := s.CreateFeedbackThread(ctx, CreateFeedbackThreadInput{
		TicketHash: SHA256Hex("fk_one"), Text: "第一次", ClientRef: stringPtr("ref-1"), At: 1_000,
	})
	if err != nil {
		t.Fatalf("第一次提交: %v", err)
	}
	second, err := s.CreateFeedbackThread(ctx, CreateFeedbackThreadInput{
		TicketHash: SHA256Hex("fk_two"), Text: "重试", ClientRef: stringPtr("ref-1"), At: 2_000,
	})
	if err != nil {
		t.Fatalf("重试: %v", err)
	}
	if second.Created || second.ThreadID != first.ThreadID {
		t.Fatalf("同一 clientRef 应返回同一条线程：%+v vs %+v", first, second)
	}
	if second.CreatedAt != 1_000 {
		t.Fatalf("重试不该改 createdAt：%d", second.CreatedAt)
	}

	// 重试带来新凭据：旧凭据作废，新凭据可用；留言不重复写。
	if thread, err := s.FeedbackThread(ctx, first.ThreadID, stringPtr(SHA256Hex("fk_one")), 50); err != nil || thread != nil {
		t.Fatalf("旧凭据应失效：%v %v", thread, err)
	}
	thread, err := s.FeedbackThread(ctx, first.ThreadID, stringPtr(SHA256Hex("fk_two")), 50)
	if err != nil || thread == nil {
		t.Fatalf("新凭据应可用：%v %v", thread, err)
	}
	if thread.MessageCount != 1 {
		t.Fatalf("重试不该再写一条留言：%d", thread.MessageCount)
	}
}

func TestCreateFeedbackThreadRefusesAClientRefFromAnotherSource(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()

	if _, err := s.CreateFeedbackThread(ctx, CreateFeedbackThreadInput{
		TicketHash: SHA256Hex("fk_one"), Text: "我的", ClientRef: stringPtr("shared-1"),
		DeviceID: stringPtr("dev_1"), AccountID: stringPtr("acc_1"), At: 1_000,
	}); err != nil {
		t.Fatalf("第一次提交: %v", err)
	}
	_, err := s.CreateFeedbackThread(ctx, CreateFeedbackThreadInput{
		TicketHash: SHA256Hex("fk_two"), Text: "偷的", ClientRef: stringPtr("shared-1"), At: 2_000,
	})
	var conflict *Conflict
	if !errors.As(err, &conflict) {
		t.Fatalf("别的来源复用 clientRef 应报 Conflict，实际 %v", err)
	}
	var count int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM feedbackThreads").Scan(&count); err != nil {
		t.Fatalf("查线程数: %v", err)
	}
	if count != 1 {
		t.Fatalf("冲突时不该新建线程：%d", count)
	}
}

func TestAppendFeedbackMessageFlipsStatusAndMovesLastMessageAt(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	threadID := seedFeedback(t, s, "fk_one", "原文", 1_000)

	reply, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: threadID, Body: "回信", Author: "owner", At: 2_000,
	})
	if err != nil || reply == nil || !reply.Created {
		t.Fatalf("回信: %+v %v", reply, err)
	}
	thread, _ := s.FeedbackThread(ctx, threadID, nil, 50)
	if thread.Status != "replied" || thread.LastMessageAt != 2_000 || thread.Unread != 1 {
		t.Fatalf("回信后的线程状态不对：%+v", thread)
	}

	if _, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: threadID, Body: "补充", Author: "user", At: 3_000,
	}); err != nil {
		t.Fatalf("用户补充: %v", err)
	}
	thread, _ = s.FeedbackThread(ctx, threadID, nil, 50)
	if thread.Status != "open" || thread.LastMessageAt != 3_000 {
		t.Fatalf("用户补充后应回到 open：%+v", thread)
	}
}

func TestAppendFeedbackMessageIsIdempotentPerClientRef(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	threadID := seedFeedback(t, s, "fk_one", "原文", 1_000)

	first, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: threadID, Body: "补充", ClientRef: stringPtr("a-1"), At: 2_000,
	})
	if err != nil {
		t.Fatalf("第一次补充: %v", err)
	}
	second, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: threadID, Body: "补充", ClientRef: stringPtr("a-1"), At: 3_000,
	})
	if err != nil {
		t.Fatalf("重试补充: %v", err)
	}
	if second.Created || second.MessageID != first.MessageID || second.CreatedAt != 2_000 {
		t.Fatalf("同一 clientRef 应返回同一条留言：%+v vs %+v", first, second)
	}
	thread, _ := s.FeedbackThread(ctx, threadID, nil, 50)
	if thread.MessageCount != 2 {
		t.Fatalf("重试不该再写一条：%d", thread.MessageCount)
	}
}

func TestAppendFeedbackMessageToAMissingThreadReturnsNil(t *testing.T) {
	s := newRepoStore(t)
	message, err := s.AppendFeedbackMessage(context.Background(), AppendFeedbackInput{
		ThreadID: "th_nope", Body: "补充",
	})
	if err != nil {
		t.Fatalf("缺线程应返回 (nil, nil)：%v", err)
	}
	if message != nil {
		t.Fatalf("缺线程不该有留言：%+v", message)
	}
}

func TestAppendFeedbackMessageBindsAnAnonymousThreadToTheDevice(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	threadID := seedFeedback(t, s, "fk_one", "匿名提交", 1_000)

	if _, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: threadID, Body: "配对之后补充",
		BindDeviceID: stringPtr("dev_1"), BindAccountID: stringPtr("acc_1"), At: 2_000,
	}); err != nil {
		t.Fatalf("补充: %v", err)
	}
	thread, _ := s.FeedbackThread(ctx, threadID, nil, 50)
	if thread.DeviceID == nil || *thread.DeviceID != "dev_1" ||
		thread.AccountID == nil || *thread.AccountID != "acc_1" {
		t.Fatalf("匿名线程应补上设备绑定：%+v", thread)
	}
	threads, err := s.FeedbackThreadsByDevice(ctx, "dev_1", stringPtr("acc_1"), 50)
	if err != nil || len(threads) != 1 || threads[0].ThreadID != threadID {
		t.Fatalf("按设备应能找到这条线程：%v %v", threads, err)
	}
}

func TestFeedbackThreadsAreFoundByTicketOrByDeviceAndAccount(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()

	anonymous, err := s.CreateFeedbackThread(ctx, CreateFeedbackThreadInput{
		TicketHash: SHA256Hex("fk_one"), Text: "匿名", At: 1_000,
	})
	if err != nil {
		t.Fatalf("匿名线程: %v", err)
	}
	paired, err := s.CreateFeedbackThread(ctx, CreateFeedbackThreadInput{
		TicketHash: SHA256Hex("fk_two"), Text: "已配对", DeviceID: stringPtr("dev_1"),
		AccountID: stringPtr("acc_1"), At: 2_000,
	})
	if err != nil {
		t.Fatalf("已配对线程: %v", err)
	}

	hits, err := s.FeedbackThreadsByTickets(ctx, []TicketPair{
		{ThreadID: anonymous.ThreadID, TicketHash: SHA256Hex("fk_one")},
		{ThreadID: anonymous.ThreadID, TicketHash: SHA256Hex("fk_one")}, // 重复只算一次
		{ThreadID: paired.ThreadID, TicketHash: SHA256Hex("fk_wrong")},  // 凭据不匹配
		{ThreadID: "th_nope", TicketHash: SHA256Hex("fk_one")},
	}, 50)
	if err != nil {
		t.Fatalf("按凭据读: %v", err)
	}
	if len(hits) != 1 || hits[0].ThreadID != anonymous.ThreadID {
		t.Fatalf("凭据命中不对：%+v", hits)
	}

	byDevice, err := s.FeedbackThreadsByDevice(ctx, "dev_1", stringPtr("acc_1"), 50)
	if err != nil || len(byDevice) != 1 || byDevice[0].ThreadID != paired.ThreadID {
		t.Fatalf("按设备读不对：%v %v", byDevice, err)
	}
	// 重装后重新配对会换 deviceId，靠 accountId 也要找得回来。
	repaired, err := s.FeedbackThreadsByDevice(ctx, "dev_other", stringPtr("acc_1"), 50)
	if err != nil || len(repaired) != 1 || repaired[0].ThreadID != paired.ThreadID {
		t.Fatalf("按账号读不对：%v %v", repaired, err)
	}
	none, err := s.FeedbackThreadsByDevice(ctx, "dev_nope", stringPtr("acc_nope"), 50)
	if err != nil || len(none) != 0 {
		t.Fatalf("不相干设备不该看到：%v %v", none, err)
	}
}

func TestFeedbackThreadReturnsTheRecentMessagesInTimeOrder(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	threadID := seedFeedback(t, s, "fk_one", "原文", 1_000)
	for index := 0; index < 4; index++ {
		if _, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
			ThreadID: threadID, Body: "第 " + string(rune('0'+index)) + " 条",
			At: int64(2_000 + index),
		}); err != nil {
			t.Fatalf("补充 %d: %v", index, err)
		}
	}

	full, _ := s.FeedbackThread(ctx, threadID, stringPtr(SHA256Hex("fk_one")), 50)
	if len(full.Messages) != 5 || full.Messages[0].Body != "原文" ||
		full.Messages[4].Body != "第 3 条" {
		t.Fatalf("全部留言顺序不对：%+v", full.Messages)
	}
	recent, _ := s.FeedbackThread(ctx, threadID, stringPtr(SHA256Hex("fk_one")), 2)
	if len(recent.Messages) != 2 || recent.Messages[0].Body != "第 2 条" ||
		recent.Messages[1].Body != "第 3 条" {
		t.Fatalf("最近 N 条应升序：%+v", recent.Messages)
	}
	headless, _ := s.FeedbackThread(ctx, threadID, stringPtr(SHA256Hex("fk_one")), 0)
	if len(headless.Messages) != 0 || headless.MessageCount != 5 {
		t.Fatalf("0 条留言时只给计数：%+v", headless)
	}
}

func TestMarkThreadReadOnlyMovesForwardAndCountsOwnerMessages(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	threadID := seedFeedback(t, s, "fk_one", "原文", 1_000)

	if _, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: threadID, Body: "回信一", Author: "owner", At: 2_000,
	}); err != nil {
		t.Fatalf("回信一: %v", err)
	}
	thread, _ := s.FeedbackThread(ctx, threadID, nil, 50)
	if thread.Unread != 1 {
		t.Fatalf("一条 owner 留言应算 1 条未读：%d", thread.Unread)
	}

	if ok, err := s.MarkThreadRead(ctx, threadID, nil); err != nil || !ok {
		t.Fatalf("标已读: %v %v", ok, err)
	}
	thread, _ = s.FeedbackThread(ctx, threadID, nil, 50)
	if thread.Unread != 0 || thread.UserReadAt == nil || *thread.UserReadAt != 2_000 {
		t.Fatalf("已读应推进到最后一条回信：%+v", thread)
	}

	// 再标一次不倒退；新回信之后未读重新出现。
	if _, err := s.MarkThreadRead(ctx, threadID, nil); err != nil {
		t.Fatalf("重复标记: %v", err)
	}
	if _, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: threadID, Body: "回信二", Author: "owner", At: 3_000,
	}); err != nil {
		t.Fatalf("回信二: %v", err)
	}
	thread, _ = s.FeedbackThread(ctx, threadID, nil, 50)
	if thread.Unread != 1 || *thread.UserReadAt != 2_000 {
		t.Fatalf("新回信应重新计未读：%+v", thread)
	}

	if ok, err := s.MarkThreadRead(ctx, "th_nope", nil); err != nil || ok {
		t.Fatalf("缺线程应返回 false：%v %v", ok, err)
	}
}

func TestNoticesAreDeliveredOncePerAccountAndReadPerAccount(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()

	created, err := s.CreateNotice(ctx, CreateNoticeInput{
		Body: "今晚 23:00 维护", Subject: stringPtr("维护通知"),
		AccountIDs: []string{"acc_1", "acc_1", "", "acc_2"}, At: 5_000,
	})
	if err != nil {
		t.Fatalf("CreateNotice: %v", err)
	}
	if created.Recipients != 2 {
		t.Fatalf("收件账号应去重：%d", created.Recipients)
	}

	notices, err := s.NoticesForAccount(ctx, "acc_1", 200)
	if err != nil || len(notices) != 1 {
		t.Fatalf("账号收件箱：%v %v", notices, err)
	}
	notice := notices[0]
	if notice.NoticeID != created.NoticeID || notice.Body != "今晚 23:00 维护" ||
		notice.Format != "text" || notice.Read || notice.ReadAt != nil {
		t.Fatalf("通知字段不对：%+v", notice)
	}
	if notice.Subject == nil || *notice.Subject != "维护通知" {
		t.Fatalf("通知主题不对：%+v", notice.Subject)
	}

	changed, err := s.MarkNoticesRead(ctx, "acc_1", []string{created.NoticeID, ""}, 6_000)
	if err != nil || changed != 1 {
		t.Fatalf("标已读：%d %v", changed, err)
	}
	// 第二台设备（同账号）再标一次是 0 行，不倒退。
	again, err := s.MarkNoticesRead(ctx, "acc_1", []string{created.NoticeID}, 7_000)
	if err != nil || again != 0 {
		t.Fatalf("重复标已读不该改行：%d %v", again, err)
	}
	notices, _ = s.NoticesForAccount(ctx, "acc_1", 200)
	if !notices[0].Read || notices[0].ReadAt == nil || *notices[0].ReadAt != 6_000 {
		t.Fatalf("账号级已读应生效：%+v", notices[0])
	}
	other, _ := s.NoticesForAccount(ctx, "acc_2", 200)
	if len(other) != 1 || other[0].Read {
		t.Fatalf("别的账号不该被标已读：%+v", other)
	}
}

func TestOwnerUnreadCountsAndTouchOwnerRead(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	threadID := seedFeedback(t, s, "fk_one", "第一个问题", 1_000)

	counts, err := s.OwnerUnreadCounts(ctx)
	if err != nil || counts[threadID] != 1 {
		t.Fatalf("owner 未读：%v %v", counts, err)
	}
	if ok, err := s.TouchOwnerRead(ctx, threadID, 1_500); err != nil || !ok {
		t.Fatalf("touch owner read: %v %v", ok, err)
	}
	counts, _ = s.OwnerUnreadCounts(ctx)
	if counts[threadID] != 0 {
		t.Fatalf("看过之后 owner 未读应清零：%v", counts)
	}
	if ok, err := s.TouchOwnerRead(ctx, "th_nope", 1_500); err != nil || ok {
		t.Fatalf("缺线程应返回 false：%v %v", ok, err)
	}
}

func TestDeleteFeedbackThreadTakesItsMessagesWithIt(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	threadID := seedFeedback(t, s, "fk_one", "原文", 1_000)
	if _, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: threadID, Body: "回信", Author: "owner", At: 2_000,
	}); err != nil {
		t.Fatalf("回信: %v", err)
	}

	removed, err := s.DeleteFeedbackThread(ctx, threadID)
	if err != nil || removed != 2 {
		t.Fatalf("删除应带走 2 条留言：%d %v", removed, err)
	}
	if thread, err := s.FeedbackThread(ctx, threadID, nil, 50); err != nil || thread != nil {
		t.Fatalf("删除后应读不到：%v %v", thread, err)
	}
	if _, err := s.DeleteFeedbackThread(ctx, threadID); err == nil {
		t.Fatalf("重复删除应报 NotFound")
	} else {
		var missing *NotFound
		if !errors.As(err, &missing) {
			t.Fatalf("重复删除的错误类型不对：%v", err)
		}
	}
}

func TestFeedbackSubjectIsTrimmedCappedAndStoredAsNullWhenBlank(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()

	created, err := s.CreateFeedbackThread(ctx, CreateFeedbackThreadInput{
		TicketHash: SHA256Hex("fk_one"), Text: "没有主题", Subject: stringPtr("   "), At: 1_000,
	})
	if err != nil {
		t.Fatalf("空主题不该报错：%v", err)
	}
	thread, _ := s.FeedbackThread(ctx, created.ThreadID, nil, 50)
	if thread.Subject != nil {
		t.Fatalf("全空白主题应存 NULL：%+v", thread.Subject)
	}

	atLimit := strings.Repeat("题", MaxSubjectChars)
	ok, err := s.SetFeedbackSubject(ctx, created.ThreadID, &atLimit)
	if err != nil || !ok {
		t.Fatalf("80 字符主题应接受：%v %v", ok, err)
	}
	tooLong := atLimit + "题"
	if _, err := s.SetFeedbackSubject(ctx, created.ThreadID, &tooLong); err == nil {
		t.Fatalf("81 字符主题应拒绝")
	}
	thread, _ = s.FeedbackThread(ctx, created.ThreadID, nil, 50)
	if thread.Subject == nil || len([]rune(*thread.Subject)) != MaxSubjectChars {
		t.Fatalf("超长主题被拒后不该改动原值：%+v", thread.Subject)
	}
	// 改主题不碰 lastMessageAt/status。
	if thread.LastMessageAt != 1_000 || thread.Status != "open" {
		t.Fatalf("改主题不该动线程状态：%+v", thread)
	}
}

func TestFeedbackFormatsAreValidatedBeforeWriting(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()

	if _, err := CleanFeedbackFormat("  HTML  "); err == nil {
		t.Fatalf("大小写不是合法取值")
	}
	if got, err := CleanFeedbackFormat("  html "); err != nil || got != FeedbackFormatHTML {
		t.Fatalf("应去空白取 html：%q %v", got, err)
	}
	if got, err := CleanFeedbackFormat("   "); err != nil || got != DefaultFeedbackFormat {
		t.Fatalf("空白应按默认 text：%q %v", got, err)
	}

	threadID := seedFeedback(t, s, "fk_one", "原文", 1_000)
	if _, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: threadID, Body: "非法格式", Format: "rtf", At: 2_000,
	}); err == nil {
		t.Fatalf("非法格式应拒绝")
	}
	thread, _ := s.FeedbackThread(ctx, threadID, nil, 50)
	if thread.MessageCount != 1 {
		t.Fatalf("非法格式不写半条留言：%d", thread.MessageCount)
	}

	if _, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: threadID, Body: "<h1>报告</h1>", Author: "owner", Format: "html", At: 3_000,
	}); err != nil {
		t.Fatalf("html 回信：%v", err)
	}
	thread, _ = s.FeedbackThread(ctx, threadID, nil, 50)
	if thread.Messages[1].Format != "html" {
		t.Fatalf("回信的格式应入库：%+v", thread.Messages[1])
	}
}

func TestListFeedbackThreadsFiltersSortsAndLimits(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()

	early := seedFeedback(t, s, "fk_one", "早的", 1_000)
	late := seedFeedback(t, s, "fk_two", "晚的", 2_000)
	if _, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: early, Body: "刚补充的", At: 3_000,
	}); err != nil {
		t.Fatalf("补充: %v", err)
	}

	all, err := s.ListFeedbackThreads(ctx, nil, nil, 50, 0)
	if err != nil || len(all) != 2 || all[0].ThreadID != early {
		t.Fatalf("应最近活动在前：%v %v", all, err)
	}
	if len(all[0].Messages) != 0 {
		t.Fatalf("清单默认不带留言")
	}

	openOnly, err := s.ListFeedbackThreads(ctx, stringPtr("open"), nil, 50, 0)
	if err != nil || len(openOnly) != 2 {
		t.Fatalf("open 过滤：%v %v", openOnly, err)
	}
	replied, err := s.ListFeedbackThreads(ctx, stringPtr("replied"), nil, 50, 0)
	if err != nil || len(replied) != 0 {
		t.Fatalf("replied 过滤：%v %v", replied, err)
	}

	since := int64(1_500)
	recentRows, err := s.ListFeedbackThreads(ctx, nil, &since, 50, 0)
	if err != nil || len(recentRows) != 1 || recentRows[0].ThreadID != late {
		t.Fatalf("since 过滤：%v %v", recentRows, err)
	}

	limited, err := s.ListFeedbackThreads(ctx, nil, nil, 1, 0)
	if err != nil || len(limited) != 1 || limited[0].ThreadID != early {
		t.Fatalf("limit 应生效：%v %v", limited, err)
	}
}

func TestFeedbackDigestUsesTheFirstMessageAndTheFirstOwnerReply(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()

	body := strings.Repeat("中", 100)
	threadID := seedFeedback(t, s, "fk_one", body, 1_000)
	if _, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: threadID, Body: "回信", Author: "owner", Format: "html", At: 2_000,
	}); err != nil {
		t.Fatalf("回信: %v", err)
	}
	if _, err := s.AppendFeedbackMessage(ctx, AppendFeedbackInput{
		ThreadID: threadID, Body: "第二封回信", Author: "owner", At: 3_000,
	}); err != nil {
		t.Fatalf("第二封回信: %v", err)
	}

	digest, err := s.FeedbackDigest(ctx, []string{threadID, "th_nope"}, 80)
	if err != nil {
		t.Fatalf("FeedbackDigest: %v", err)
	}
	entry, ok := digest[threadID]
	if !ok {
		t.Fatalf("摘要缺少线程：%v", digest)
	}
	if got := len([]rune(entry.Excerpt)); got != 80 {
		t.Fatalf("摘要应按字符截到 80，实际 %d", got)
	}
	if !strings.HasPrefix(body, entry.Excerpt) {
		t.Fatalf("摘要应来自首条留言：%q", entry.Excerpt)
	}
	if entry.Format != "text" {
		t.Fatalf("摘要格式取自首条留言：%q", entry.Format)
	}
	if entry.FirstReplyAt == nil || *entry.FirstReplyAt != 2_000 {
		t.Fatalf("firstReplyAt 应是第一封回信：%v", entry.FirstReplyAt)
	}
	if _, ok := digest["th_nope"]; ok {
		t.Fatalf("不存在的线程应被跳过")
	}
}
