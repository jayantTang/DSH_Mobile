@testable import DSHKit
import XCTest

/// MessagePipeline（contracts/memory-pipeline.md / tasks T009）：
/// 快照流的首帧 + 增量广播、多订阅者独立、gap 生灭并入 diff、
/// 发送五拍（pending → 落库 → 网络 → 确认原地替换，身份不变）。
final class MessagePipelineTests: XCTestCase {

    private enum TestError: Error { case sendFailed }

    private var directory: URL!
    private var store: MessageStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-pipeline-tests-\(UUID().uuidString)")
        store = try MessageStore(path: directory.appendingPathComponent("test.sqlite3"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let session = MessageSessionRef(scope: "mac", sessionId: "s1")

    private func record(_ seq: Int, type: String = "assistant/message",
                        text: String = "hello") -> SessionRecord {
        let json = #"{"type":"\#(type)","seq":\#(seq),"time":1789276358732,"data":{"text":"\#(text)"}}"#
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    /// 空取页器（这些用例不走网络水合，只测聚合与上行）。
    private func makePipeline(
        sender: @escaping MessagePipeline.Sender = { _, text, _, _ in
            let json = #"{"type":"user/message","seq":42,"time":1789276358733,"data":{"text":"\#(text)"}}"#
            return SessionRecord(event: try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8)))
        },
        confirmationLookup: MessagePipeline.ConfirmationLookup? = nil,
        unconfirmedGrace: TimeInterval = 20
    ) -> MessagePipeline {
        MessagePipeline(
            store: store,
            fetchFactory: { _ in { _, _ in
                SessionPipeline.FetchPage(records: [], hasMore: false, clamped: false)
            } },
            sender: sender,
            confirmationLookup: confirmationLookup,
            now: { 1000 },
            unconfirmedGrace: unconfirmedGrace)
    }

    // MARK: - 订阅与广播

    func testInitialSnapshotCarriesPrimedRowsThenDiffs() async throws {
        let pipeline = makePipeline()
        // 订阅前已有水合数据：首帧必须带上（不能丢）。
        let sessionPipeline = await pipeline.pipeline(for: session)
        await sessionPipeline.apply(event: record(1).event)
        await sessionPipeline.apply(event: record(2).event)

        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        guard case .insert(let rows)? = initial?.changes.first else {
            return XCTFail("首帧应是全量 insert，实收 \(String(describing: initial))")
        }
        XCTAssertEqual(rows.map(\.id).count, 2)

        // 之后只发增量。
        await sessionPipeline.apply(event: record(3).event)
        let delta = await iterator.next()
        guard case .insert(let inserted)? = delta?.changes.first else {
            return XCTFail("增量应是 insert，实收 \(String(describing: delta))")
        }
        XCTAssertEqual(inserted.count, 1)
        if case .message(let message) = inserted[0] {
            XCTAssertEqual(message.seq, 3)
        } else {
            XCTFail("应是数据行")
        }
    }

    func testMultipleSubscribersEachGetOwnStream() async throws {
        let pipeline = makePipeline()
        let sessionPipeline = await pipeline.pipeline(for: session)

        let streamA = await pipeline.snapshots(for: session)
        await sessionPipeline.apply(event: record(7).event)
        try await Task.sleep(nanoseconds: 100_000_000) // 泵落定：seq=7 进聚合状态
        // B 订阅得晚：它的首帧也要含 seq=7（各自独立快照）。
        let streamB = await pipeline.snapshots(for: session)

        var iteratorA = streamA.makeAsyncIterator()
        var iteratorB = streamB.makeAsyncIterator()

        let initialB = await iteratorB.next()
        guard case .insert(let rowsB)? = initialB?.changes.first else {
            return XCTFail("B 首帧应是全量 insert")
        }
        XCTAssertEqual(rowsB.count, 1)

        // 新事件：A、B 都收到增量（A 先收过 seq=7 的 delta，这里读到 8 为止）。
        await sessionPipeline.apply(event: record(8).event)
        var sawDeltaA = false
        for _ in 0..<3 {
            guard let diff = await iteratorA.next() else { break }
            if case .insert(let rows) = diff.changes.first, rows.count == 1 {
                sawDeltaA = true
                break
            }
        }
        XCTAssertTrue(sawDeltaA)
        let deltaB = await iteratorB.next()
        XCTAssertNotNil(deltaB)
    }

    func testGapRowsAppearInInitialSnapshotAndDieInDiff() async throws {
        // gap 行生灭走 SessionPipeline 的 fetch 合并路径，这里用脚本化取页器。
        let stub = FetchScript()
        let pipeline = MessagePipeline(
            store: store,
            fetchFactory: { _ in { range, priority in try await stub.fetch(range, priority: priority) } },
            sender: { _, _, _, _ in throw TestError.sendFailed },
            now: { 1000 })
        let sessionPipeline = await pipeline.pipeline(for: session)
        // 下行事件预置两段窗口（不经 records()，避免预取提前填洞造成竞态）。
        for seq in 1...50 { await sessionPipeline.apply(event: record(seq).event) }
        for seq in 101...150 { await sessionPipeline.apply(event: record(seq).event) }

        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        let gapIDs = initial?.changes.flatMap { change -> [String] in
            if case .insert(let rows) = change {
                return rows.compactMap { row in
                    if case .gap(let gap) = row { return gap.id }
                    return nil
                }
            }
            return []
        } ?? []
        XCTAssertEqual(gapIDs, ["gap:51-100"])

        // 补齐后：同一 diff 里 gap 行被 remove。
        await stub.set(51...100, records: (51...100).map { record($0) }, hasMore: true)
        _ = try await sessionPipeline.records(in: 55...60)
        var sawGapRemoved = false
        while let diff = await iterator.next() {
            for change in diff.changes {
                if case .remove(let ids) = change, ids.contains("gap:51-100") {
                    sawGapRemoved = true
                }
            }
            if sawGapRemoved { break }
        }
        XCTAssertTrue(sawGapRemoved)
    }

    // MARK: - 上行发送

    func testSendPendingThenConfirmKeepsIdentity() async throws {
        let pipeline = makePipeline()
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // 首帧（空）

        let clientId = try await pipeline.send(text: "你好", to: session)

        // ① 乐观插入：pending，身份 = clientId。
        let insertDiff = await iterator.next()
        guard case .insert(let rows)? = insertDiff?.changes.first,
              case .message(let pending) = rows.first else {
            return XCTFail("应有 pending 插入，实收 \(String(describing: insertDiff))")
        }
        XCTAssertEqual(pending.id, clientId)
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(pending.record.event.data["text"]?.stringValue, "你好")

        // ② 确认：原地替换（身份不变），seq 换成服务端 42，状态 sent。
        let updateDiff = await iterator.next()
        guard case .update(let updated)? = updateDiff?.changes.first,
              case .message(let confirmed) = updated.first else {
            return XCTFail("应有确认 update，实收 \(String(describing: updateDiff))")
        }
        XCTAssertEqual(confirmed.id, clientId) // 身份不变
        XCTAssertEqual(confirmed.seq, 42)
        XCTAssertEqual(confirmed.status, .sent)
    }

    func testSendFailureMarksRowFailedWithSameIdentity() async throws {
        let pipeline = makePipeline { _, _, _, _ in throw TestError.sendFailed }
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        _ = try? await pipeline.send(text: "hi", to: session)
        // pending insert 与失败 update 的身份必须一致（失败不重建行）。
        let insertDiff = await iterator.next()
        guard case .insert(let inserted)? = insertDiff?.changes.first,
              case .message(let pending) = inserted.first else {
            return XCTFail("应有 pending 插入，实收 \(String(describing: insertDiff))")
        }
        let updateDiff = await iterator.next()
        guard case .update(let rows)? = updateDiff?.changes.first,
              case .message(let failed) = rows.first else {
            return XCTFail("应有失败 update，实收 \(String(describing: updateDiff))")
        }
        XCTAssertEqual(failed.id, pending.id)
        XCTAssertEqual(failed.status, .failed)
    }

    func testSendPersistsPendingThenConfirmThroughWriteQueue() async throws {
        let pipeline = makePipeline()
        _ = try await pipeline.send(text: "落库", to: session)
        let sessionPipeline = await pipeline.pipeline(for: session)
        await sessionPipeline.flushPendingWrites()
        try await Task.sleep(nanoseconds: 200_000_000) // 落库是异步批量写
        // confirmPending 落库后：正式记录可读，pending 行已被替换。
        let records = try await store.records(scope: "mac", sessionId: "s1", in: 1...50)
        XCTAssertEqual(records.map(\.event.seq), [42])
        XCTAssertEqual(records.first?.event.data["text"]?.stringValue, "落库") // sender 回包带回原文
    }

    // MARK: - T022 下行确认 / 重发去重 / 重启恢复

    /// 服务端确认走下行：sender 回 nil（已受理，确认等回流），durable 用户消息的
    /// source.rpcId == clientId 到达时 tempId→serverId 原地替换（身份不变）。
    func testDownstreamConfirmationReplacesPendingInPlace() async throws {
        let pipeline = makePipeline(sender: { _, _, _, _ in nil })
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        let clientId = try await pipeline.send(text: "你好", to: session)
        guard case .insert(let inserted)? = await iterator.next()?.changes.first,
              case .message(let pending) = inserted.first else {
            return XCTFail("应有 pending 插入")
        }
        XCTAssertEqual(pending.status, .pending)

        // 下行回流：同一 clientId 的 durable 记录（seq=42）。
        let confirmed = Self.userRecord(seq: 42, text: "你好", rpcId: clientId.uuidString)
        let sessionPipeline = await pipeline.pipeline(for: session)
        await sessionPipeline.apply(events: [confirmed.event])
        guard case .update(let rows)? = await iterator.next()?.changes.first,
              case .message(let sent) = rows.first else {
            return XCTFail("应有确认 update")
        }
        XCTAssertEqual(sent.id, clientId) // 原地替换：身份不变
        XCTAssertEqual(sent.seq, 42)
        XCTAssertEqual(sent.status, .sent)
    }

    /// 重发去重（T022）：clientId 已在服务端最新页（崩溃前确认了没落库）→
    /// 不重发，只原地替换。
    func testResendSkipsNetworkWhenServerAlreadyHasClientId() async throws {
        let sendCount = SendCounter()
        let lookup = LookupStub()
        let pipeline = makePipeline(
            sender: { _, _, _, _ in
                await sendCount.increment()
                throw TestError.sendFailed
            },
            confirmationLookup: { _, _ in await lookup.record })
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        _ = try? await pipeline.send(text: "hi", to: session)
        guard case .insert(let inserted)? = await iterator.next()?.changes.first,
              case .message(let pending) = inserted.first else {
            return XCTFail("应有 pending 插入")
        }
        let clientId = pending.id
        _ = await iterator.next() // failed update
        do { let sends = await sendCount.value; XCTAssertEqual(sends, 1) }

        // 查重命中：服务端其实已有（seq=42）→ 不重发，行直接转 sent。
        await lookup.set(Self.userRecord(seq: 42, text: "hi", rpcId: clientId.uuidString))
        try await pipeline.resend(clientId: clientId, for: session)
        do { let sends = await sendCount.value; XCTAssertEqual(sends, 1) } // 网络没有被再调一次
        guard case .update(let rows)? = await iterator.next()?.changes.first,
              case .message(let sent) = rows.first else {
            return XCTFail("应有查重命中的原地替换")
        }
        XCTAssertEqual(sent.id, clientId)
        XCTAssertEqual(sent.seq, 42)
        XCTAssertEqual(sent.status, .sent)
    }

    /// 查重未命中 → 正常重发：failed 回到 pending，sender 回包后原地替换为 sent。
    func testResendFallsBackToNetworkWhenLookupMisses() async throws {
        let sendCount = SendCounter()
        let pipeline = makePipeline(
            sender: { _, text, _, _ in
                let count = await sendCount.increment()
                if count == 1 { throw TestError.sendFailed } // 第一次失败造 failed 行
                return Self.userRecord(seq: 42, text: text, rpcId: nil)
            },
            confirmationLookup: { _, _ in nil })
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        _ = try? await pipeline.send(text: "hi", to: session)
        guard case .insert(let inserted)? = await iterator.next()?.changes.first,
              case .message(let pending) = inserted.first else {
            return XCTFail("应有 pending 插入")
        }
        let clientId = pending.id
        _ = await iterator.next() // failed update

        try await pipeline.resend(clientId: clientId, for: session)
        do { let sends = await sendCount.value; XCTAssertEqual(sends, 2) } // 重发真走了网络
        var sawPending = false
        var sawSent = false
        for _ in 0..<3 {
            guard case .update(let rows)? = await iterator.next()?.changes.first,
                  case .message(let message) = rows.first else { break }
            XCTAssertEqual(message.id, clientId)
            if message.status == .pending { sawPending = true }
            if message.status == .sent { sawSent = true; break }
        }
        XCTAssertTrue(sawPending) // 重发开始先回标 pending
        XCTAssertTrue(sawSent)
    }

    /// 重启恢复（T022）：磁盘里的 pending 记录以「未发出」（failed）呈现，
    /// **不再自动重发**——磁盘上的 pending 分不清"真没发出去"和"宿主已收下、
    /// 还在队列里"，自动重发会用同一个 requestId 再投一次（本机日志里 12:09 与
    /// 12:57 就因此出现了两条同 rpcId 的 `agent/inbox/spliced`）。
    func testRestorePendingRendersFailedWithoutAutoResending() async throws {
        let clientId = UUID()
        let optimistic = SessionRecord(event: SessionEvent(
            type: "user/message", seq: Int.max, time: 1_789_276_358_000,
            data: .object([
                "text": .string("重启前没发出去"),
                "source": .object(["kind": .string("user"), "rpcId": .string(clientId.uuidString)]),
            ]), surfaceOp: nil))
        try await store.applyWrites([.upsertPending(
            scope: "mac", sessionId: "s1", clientId: clientId.uuidString, record: optimistic)])

        let sendCount = SendCounter()
        let pipeline = makePipeline(
            sender: { _, text, _, _ in
                await sendCount.increment()
                return Self.userRecord(seq: 42, text: text, rpcId: clientId.uuidString)
            },
            confirmationLookup: { _, _ in nil })
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // 首帧（空）

        await pipeline.restorePending(for: session)
        guard case .insert(let rows)? = await iterator.next()?.changes.first,
              case .message(let restored) = rows.first else {
            return XCTFail("应恢复出未发出行")
        }
        XCTAssertEqual(restored.id, clientId)
        XCTAssertEqual(restored.status, .failed) // 未发出、可点重发

        // 不自动重发：网络一次都不该被调；行也不该自己变成 pending/sent。
        try await Task.sleep(nanoseconds: 200_000_000)
        do { let sends = await sendCount.value; XCTAssertEqual(sends, 0) }
    }

    /// 重启恢复不得把**已经送达并被回答**的消息重新标成失败（2026-10-18 现场：
    /// 会话 6c8c611b，宿主 23:44:31 收到 rpcId `CF19EC67` 并回答，手机端到 23:54
    /// 仍显示「发送失败，点击重发」）。
    ///
    /// 冷启动的顺序是「先水合最新页/磁盘 → 再 restorePending」。正式记录
    /// （`source.rpcId == clientId`）已经进了热窗口，而磁盘上还留着上一轮没来得及
    /// 落确认的 pending 行。恢复逻辑只认磁盘，不认窗口里已经存在的正式记录，于是
    /// 又插一条合成 key 的 failed 行；两条记录折叠身份同为 `user-<rpcId>`，后者
    /// （页尾）覆盖前者——屏幕上就是"回答在上面、失败在下面"，而且再也不会有
    /// 下行确认来救它（同 seq 的记录再次到达只会走 update，不进确认分支）。
    func testRestorePendingMustNotMarkAnAlreadyLandedSendAsFailed() async throws {
        let clientId = UUID()
        let pending = SessionRecord(event: SessionEvent(
            type: "user/message", seq: Int.max, time: 1_789_276_358_000,
            data: .object([
                "text": .string("已发出并被回答"),
                "source": .object(["kind": .string("user"), "rpcId": .string(clientId.uuidString)]),
            ]), surfaceOp: nil))
        try await store.applyWrites([.upsertPending(
            scope: "mac", sessionId: "s1", clientId: clientId.uuidString, record: pending)])

        let pipeline = makePipeline(sender: { _, _, _, _ in nil })
        let sessionPipeline = await pipeline.pipeline(for: session)
        // 冷启动先水合出宿主已确认的正式记录（同一 clientId，seq 594）。
        await sessionPipeline.apply(events: [
            Self.userRecord(seq: 594, text: "已发出并被回答", rpcId: clientId.uuidString).event,
        ])

        await pipeline.restorePending(for: session)

        let visible = await messages(pipeline)
        let same = visible.filter {
            $0.record.event.data["source"]?["rpcId"]?.stringValue == clientId.uuidString
        }
        XCTAssertEqual(same.count, 1, "同一 clientId 只能有一行：正式记录已在窗口里，恢复不得再插失败行")
        XCTAssertEqual(same.first?.status, .sent, "已确认并已回答的消息，恢复后不许显示成发送失败")
    }

    /// 确认已经写进内存、但确认落库还在队列里就被杀进程：磁盘上仍是 pending。
    /// 重启恢复必须识别"正式记录已经存在"（同一 rpcId），不能把这条翻回 failed。
    func testRestorePendingMustNotUndoAConfirmationWhoseDiskWriteWasLost() async throws {
        let pipeline = makePipeline(sender: { _, _, _, _ in nil })
        _ = await pipeline.snapshots(for: session) // 建状态

        let clientId = try await pipeline.send(text: "确认写没落盘", to: session)
        let sessionPipeline = await pipeline.pipeline(for: session)
        // pending 已落盘（send 之后那次 flush），确认还没落盘。
        await sessionPipeline.flushPendingWrites()
        try await Task.sleep(nanoseconds: 100_000_000)
        let onDisk = try await store.pendingRecords(scope: "mac", sessionId: "s1")
        XCTAssertEqual(onDisk.count, 1, "前提：pending 行确实已经在磁盘上（确认还没落盘）")
        await sessionPipeline.apply(events: [
            Self.userRecord(seq: 42, text: "确认写没落盘", rpcId: clientId.uuidString).event,
        ])

        await pipeline.restorePending(for: session)

        let visible = await messages(pipeline)
        let same = visible.filter { $0.id == clientId }
        XCTAssertEqual(same.count, 1, "恢复不得在已确认的行之外再造一行")
        XCTAssertEqual(same.first?.status, .sent, "确认已在内存里落地，磁盘 pending 不得把行翻回 failed")
    }

    /// 退后台/被挂起必须把 009 的批量写队列冲干净。写队列只在下一次入队时检查
    /// 0.5 秒窗口，没有定时器；不显式冲，确认写入就停在内存里，进程被杀后磁盘上
    /// 只剩 pending，重启就被恢复逻辑误判成"没发出去"（2026-10-18 现场的前半段）。
    func testFlushWritesPersistsAConfirmationWithoutAnotherEnqueue() async throws {
        let pipeline = makePipeline(sender: { _, _, _, _ in nil })
        _ = await pipeline.snapshots(for: session)
        let clientId = try await pipeline.send(text: "退后台前落盘", to: session)
        let sessionPipeline = await pipeline.pipeline(for: session)
        await sessionPipeline.flushPendingWrites()
        try await Task.sleep(nanoseconds: 100_000_000)

        await sessionPipeline.apply(events: [
            Self.userRecord(seq: 42, text: "退后台前落盘", rpcId: clientId.uuidString).event,
        ])
        // 确认由管道泵异步入队：等它进队列，再模拟退后台直接冲。
        try await Task.sleep(nanoseconds: 100_000_000)
        await pipeline.flushWrites()
        try await Task.sleep(nanoseconds: 200_000_000)

        let pending = try await store.pendingRecords(scope: "mac", sessionId: "s1")
        XCTAssertTrue(pending.isEmpty, "flush 之后磁盘上不许再留 pending 行")
        let records = try await store.records(scope: "mac", sessionId: "s1", in: 42...42)
        XCTAssertEqual(records.count, 1, "确认写入必须已经落成正式行")
    }

    /// 当前快照里的全部数据行（订阅即得全量首帧）。
    private func messages(_ pipeline: MessagePipeline) async -> [MessageRenderedMessage] {
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        guard case .insert(let rows)? = await iterator.next()?.changes.first else { return [] }
        return rows.compactMap { row in
            if case .message(let message) = row { return message }
            return nil
        }
    }

    /// 「已发送，未确认」兜底：轮次结束（含撤回排队项、以错误收尾）后仍停在 pending
    /// 的行，过了宽限期必须翻成 unconfirmed，不能永远挂着"等待开始"。
    /// 本机日志 session-152bb1ac：12:09:12 入队 → 同一秒 `agent/inbox/spliced`
    /// removedCount=1 撤回 → turn/end reason=error(ENOSPC)，之后再无确认帧。
    func testPendingRowBecomesUnconfirmedAfterTurnEndsWithoutConfirmation() async throws {
        let pipeline = makePipeline(sender: { _, _, _, _ in nil }, unconfirmedGrace: 0.05)
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        let clientId = try await pipeline.send(text: "怎么样了", to: session)
        guard case .insert(let inserted)? = await iterator.next()?.changes.first,
              case .message(let pending) = inserted.first else {
            return XCTFail("应有 pending 插入")
        }
        XCTAssertEqual(pending.status, .pending)

        // 轮次结束，但宿主没有提升这条排队项（它是被撤回的那一条）。
        await pipeline.pipeline(for: session).apply(events: [
            Self.turnEndRecord(seq: 1102).event,
        ])
        var unconfirmed: MessageRenderedMessage?
        for _ in 0..<6 {
            guard case .update(let rows)? = await iterator.next()?.changes.first,
                  case .message(let message) = rows.first else { continue }
            if message.status == .unconfirmed { unconfirmed = message; break }
        }
        XCTAssertEqual(unconfirmed?.id, clientId)
        XCTAssertEqual(unconfirmed?.status, .unconfirmed, "轮次结束仍无确认帧：必须降级为未确认")
    }

    /// 降级之后迟到的确认仍然救得回来（pendingSeqs 不被清）：不许因为一次误判
    /// 就把一条其实已入队的消息变成"失败"。
    func testLateConfirmationRescuesUnconfirmedRow() async throws {
        let pipeline = makePipeline(sender: { _, _, _, _ in nil }, unconfirmedGrace: 0.05)
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        let clientId = try await pipeline.send(text: "晚到的确认", to: session)
        _ = await iterator.next() // pending 插入
        await pipeline.pipeline(for: session).apply(events: [Self.turnEndRecord(seq: 9).event])
        var sawUnconfirmed = false
        for _ in 0..<4 {
            guard case .update(let rows)? = await iterator.next()?.changes.first,
                  case .message(let message) = rows.first else { continue }
            if message.status == .unconfirmed { sawUnconfirmed = true; break }
        }
        XCTAssertTrue(sawUnconfirmed)

        await pipeline.pipeline(for: session).apply(events: [
            Self.userRecord(seq: 42, text: "晚到的确认", rpcId: clientId.uuidString).event,
        ])
        var rescued: MessageRenderedMessage?
        for _ in 0..<4 {
            guard case .update(let rows)? = await iterator.next()?.changes.first,
                  case .message(let message) = rows.first else { continue }
            if message.status == .sent { rescued = message; break }
        }
        XCTAssertEqual(rescued?.id, clientId)
        XCTAssertEqual(rescued?.seq, 42)
    }

    /// 「点击核对」：服务端已有这条（确认帧丢了）→ 只原地转 sent，不重发；
    /// 服务端查不到 → 转 failed 等读者决定，不替读者再发一次。
    func testVerifyConfirmsOnServerHitWithoutResending() async throws {
        let sendCount = SendCounter()
        let lookup = LookupStub()
        let pipeline = makePipeline(
            sender: { _, _, _, _ in
                await sendCount.increment()
                return nil
            },
            confirmationLookup: { _, _ in await lookup.record })
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let clientId = try await pipeline.send(text: "核对", to: session)
        _ = await iterator.next() // pending 插入

        await lookup.set(Self.userRecord(seq: 77, text: "核对", rpcId: clientId.uuidString))
        await pipeline.verify(clientId: clientId, for: session)
        var confirmed: MessageRenderedMessage?
        for _ in 0..<3 {
            guard case .update(let rows)? = await iterator.next()?.changes.first,
                  case .message(let message) = rows.first else { continue }
            if message.status == .sent { confirmed = message; break }
        }
        XCTAssertEqual(confirmed?.seq, 77)
        do { let sends = await sendCount.value; XCTAssertEqual(sends, 1, "核对不许再发一次") }
    }

    func testVerifyFallsBackToFailedWhenServerHasNothing() async throws {
        let pipeline = makePipeline(
            sender: { _, _, _, _ in nil },
            confirmationLookup: { _, _ in nil })
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let clientId = try await pipeline.send(text: "查不到", to: session)
        _ = await iterator.next() // pending 插入

        await pipeline.verify(clientId: clientId, for: session)
        var failed: MessageRenderedMessage?
        for _ in 0..<3 {
            guard case .update(let rows)? = await iterator.next()?.changes.first,
                  case .message(let message) = rows.first else { continue }
            if message.status == .failed { failed = message; break }
        }
        XCTAssertEqual(failed?.id, clientId)
    }

    /// 轮次结束记录（`turn/end`），驱动「未确认」扫描。
    private static func turnEndRecord(seq: Int) -> SessionRecord {
        let json = #"{"type":"turn/end","seq":\#(seq),"time":1789276358740,"data":{"turn":2,"reason":{"kind":"error"}}}"#
        return SessionRecord(event: try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8)))
    }

    /// durable 用户消息（带 source.rpcId），模拟服务端确认回流的记录。
    private static func userRecord(seq: Int, text: String, rpcId: String?) -> SessionRecord {
        var source: [String: JSONValue] = ["kind": .string("user")]
        if let rpcId { source["rpcId"] = .string(rpcId) }
        let data: JSONValue = .object([
            "text": .string(text),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "source": .object(source),
        ])
        return SessionRecord(event: SessionEvent(
            type: "user/message", seq: seq, time: 1_789_276_358_733, data: data, surfaceOp: nil))
    }

    private actor SendCounter {
        private(set) var value = 0
        @discardableResult
        func increment() -> Int { value += 1; return value }
    }

    private actor LookupStub {
        private(set) var record: SessionRecord?
        func set(_ record: SessionRecord) { self.record = record }
    }

    // MARK: - 假件

    /// 对齐页脚本化取页器（本文件自用，行为同 SessionPipelineTests 的 stub）。
    private actor FetchScript {
        private var pages: [Int: SessionPipeline.FetchPage] = [:]

        func set(_ range: ClosedRange<Int>, records: [SessionRecord], hasMore: Bool) {
            pages[range.lowerBound] = SessionPipeline.FetchPage(records: records, hasMore: hasMore)
        }

        func fetch(_ range: ClosedRange<Int>, priority: SessionPipeline.FetchPriority) throws -> SessionPipeline.FetchPage {
            pages[range.lowerBound] ?? SessionPipeline.FetchPage(records: [], hasMore: true)
        }
    }
}
