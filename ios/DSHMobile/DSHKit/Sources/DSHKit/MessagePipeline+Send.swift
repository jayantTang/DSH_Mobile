import Foundation

/// MessagePipeline 的上行半边（spec 009 场景 11 / tasks T022；文件按职责拆分，
/// 与 `MessageStore+Records` 同一先例）。状态成员对扩展是 internal（模块内可见）。
extension MessagePipeline {
    // MARK: - 上行：发送五拍（spec 场景 11 / 状态机 draft→pending→sent）

    /// 发送一条用户消息。乐观插入（pending，UUID 身份）→ 落库 → 网络 →
    /// 确认后原地替换（身份不变）。失败标 failed（可重发，不丢身份）。
    /// `steer` 透给网络面（打断当前轮 vs 排队），与乐观行无关。
    @discardableResult
    public func send(text: String, to session: MessageSessionRef, steer: Bool = false) async throws -> UUID {
        _ = await ensurePrimedState(for: session)
        let clientId = UUID()
        guard let row = insertOptimistic(text: text, clientId: clientId, for: session) else {
            return clientId
        }

        // ② 落库队列（按消息去重，先落 pending 再发——重启可见未发出消息）。
        let pipeline = pipeline(for: session)
        await pipeline.enqueueWrite(.upsertPending(
            scope: session.scope, sessionId: session.sessionId,
            clientId: clientId.uuidString, record: row.record), key: row.seq)

        // ③ 网络 → ④ 确认原地替换（sender 回 nil 则等下行 rpcId 确认）/ 失败标 failed。
        do {
            try await dispatch(clientId: clientId, text: text, steer: steer, for: session)
        } catch {
            replacePending(clientId: clientId, with: nil, status: .failed, for: session)
            throw error
        }
        return clientId
    }

    /// 重发一条未发出的消息（failed 行点重发、重启恢复各走这里）。
    ///
    /// 重发前先按 clientId 查重（`confirmationLookup`，T022）：服务端最新页已有
    /// 说明崩溃前其实确认了只是没落库——只原地替换，**不重发**（否则消息发两遍）。
    public func resend(clientId: UUID, for session: MessageSessionRef) async throws {
        _ = await ensurePrimedState(for: session)
        guard let state = states[session],
              let seq = state.pendingSeqs[clientId],
              let row = state.rows[seq],
              let text = row.record.event.data["text"]?.stringValue else { return }
        let pipeline = pipeline(for: session)
        if let lookup = confirmationLookup, let existing = await lookup(session, clientId) {
            replacePending(clientId: clientId, with: existing, status: .sent, for: session)
            await pipeline.enqueueWrite(.confirmPending(
                scope: session.scope, sessionId: session.sessionId,
                clientId: clientId.uuidString, record: existing), key: existing.event.seq)
            return
        }
        markPending(clientId: clientId, for: session)
        do {
            try await dispatch(clientId: clientId, text: text, steer: false, for: session)
        } catch {
            replacePending(clientId: clientId, with: nil, status: .failed, for: session)
            throw error
        }
    }

    /// 重启恢复（T022）：磁盘层里 status='pending' 的记录，**先按 clientId 对账**
    /// 再决定是不是「没发出去」。
    ///
    /// 送达的唯一事实是宿主写下的 durable 用户消息（`source.rpcId == clientId`）：
    /// 它在热窗口里，或在磁盘上（还没水合），都说明这条不是没发出去。此时只清掉
    /// 磁盘上残留的 pending 行，不插 failed 行。2026-10-18 的现场就是漏了这一步：
    /// 进程在确认落盘前被杀，重启后把已经回答过的消息显示成「发送失败」。
    ///
    /// 只有对账查无此条时才以 failed（未发出、可点重发）呈现。
    /// **不再自动重发**（2026-10-17）：自动重发会用同一个 requestId 再投一次；
    /// 本机日志里同一 rpcId 因此出现了两条 `agent/inbox/spliced`（12:09 与 12:57），
    /// 而手机端按 rpcId 折成一行，界面上看不出重复。要不要再发一次由读者点重发决定。
    /// 幂等：已跟踪的 clientId 不重复插入。
    public func restorePending(for session: MessageSessionRef) async {
        guard let store,
              let pending = try? await store.pendingRecords(
                  scope: session.scope, sessionId: session.sessionId),
              !pending.isEmpty else { return }
        _ = await ensurePrimedState(for: session)
        // 先把磁盘对账的 await 全部做完，再一次性改状态：这个 actor 在 await
        // 期间是重入的，泵/发送写进来的行会被手里这份旧 state 覆盖。
        var inspected: [(clientId: String, pending: SessionRecord, stored: SessionRecord?)] = []
        for entry in pending.sorted(by: { $0.record.event.seq > $1.record.event.seq }) {
            guard UUID(uuidString: entry.clientId) != nil else { continue }
            // 正式记录已经落进磁盘、只是还没水合进窗口：同样不是「没发出去」。
            let stored = (try? await store.confirmedRecord(
                scope: session.scope, sessionId: session.sessionId,
                clientId: entry.clientId)) ?? nil
            inspected.append((entry.clientId, entry.record, stored))
        }
        guard var state = states[session] else { return }
        let landed = Self.landedRecords(in: state)
        var inserted: [MessageRow] = []
        /// 已经在宿主确认过的 uuid → 正式记录：只清磁盘残留，不进时间线。
        var settled: [(clientId: String, record: SessionRecord)] = []
        for item in inspected {
            guard let clientId = UUID(uuidString: item.clientId),
                  state.pendingSeqs[clientId] == nil else { continue }
            if let confirmed = landed[clientId] ?? item.stored {
                // 窗口里已有（或磁盘上已有）`source.rpcId == clientId` 的正式记录：
                // 这条已经送达，只把磁盘上残留的 pending 行换成正式行。
                settled.append((item.clientId, confirmed))
                continue
            }
            let seq = state.nextSyntheticSeq
            state.nextSyntheticSeq -= 1
            // 合成键每次启动重发（行排序用），记录里的 seq 同步换掉，折叠出的
            // 行 seq 与状态回标的键才一致。
            let event = item.pending.event
            let record = SessionRecord(event: SessionEvent(
                type: event.type, seq: seq, time: event.time,
                data: event.data, surfaceOp: event.surfaceOp))
            let message = MessageRenderedMessage(id: clientId, seq: seq, record: record, status: .failed)
            state.rows[seq] = message
            state.pendingSeqs[clientId] = seq
            inserted.append(.message(message))
        }
        states[session] = state
        if !inserted.isEmpty {
            broadcast(MessageSnapshotDiff(changes: [.insert(inserted)]), to: state.continuations)
        }
        // pending 行留在磁盘上就等于"还没发送"，下次启动还会被当成未发出：
        // 用确认写入把它换成正式行（按 client_id 删除后写入，幂等）。
        for (clientId, record) in settled {
            await pipeline(for: session).enqueueWrite(.confirmPending(
                scope: session.scope, sessionId: session.sessionId,
                clientId: clientId, record: record), key: record.event.seq)
        }
    }

    /// 热窗口里已经确认过的上行记录（clientId → 正式记录）。
    ///
    /// 只认 `.sent`：乐观行自己也带 `source.rpcId == clientId`，把 pending/failed
    /// 一起算进来会把它自己的影子当成"已送达"。
    static func landedRecords(in state: SessionState) -> [UUID: SessionRecord] {
        var result: [UUID: SessionRecord] = [:]
        for row in state.rows.values where row.status == .sent {
            if let clientId = confirmationClientId(of: row.record) {
                result[clientId] = row.record
            }
        }
        return result
    }

    /// 把各会话的批量写队列立即落盘。
    ///
    /// 写队列没有定时器：只在下一次入队时检查 0.5 秒窗口。退到后台/被挂起前不显式
    /// 冲一次，已确认（confirm）的写入可能停在内存里；进程被杀后磁盘上只剩 pending，
    /// 重启就会被恢复逻辑误判成"没发出去"。
    public func flushWrites() async {
        for pipeline in pipelines.values {
            await pipeline.flushPendingWrites()
        }
    }

    /// 「已发送，未确认，点击核对」（2026-10-17）：先按 clientId 对服务端最新页查一次。
    /// 命中说明其实已确认（只是确认帧没到），只原地替换成 sent；没命中才退回
    /// failed（「发送失败，点击重发」），由读者决定是否真的再发一次——不替读者决定。
    public func verify(clientId: UUID, for session: MessageSessionRef) async {
        _ = await ensurePrimedState(for: session)
        guard let state = states[session],
              let seq = state.pendingSeqs[clientId],
              state.rows[seq] != nil else { return }
        if let lookup = confirmationLookup, let existing = await lookup(session, clientId) {
            replacePending(clientId: clientId, with: existing, status: .sent, for: session)
            await pipeline(for: session).enqueueWrite(.confirmPending(
                scope: session.scope, sessionId: session.sessionId,
                clientId: clientId.uuidString, record: existing), key: existing.event.seq)
            return
        }
        replacePending(clientId: clientId, with: nil, status: .failed, for: session)
    }

    /// ① 乐观插入：稳定 UUID + 合成 seq（排在当前尾部之后）。记录按 durable
    /// 用户消息的形状构造（content + source.rpcId=clientId），折叠身份
    /// `user-<clientId>` 与确认行一致——身份只有这一套，没有第二套 requestId。
    private func insertOptimistic(
        text: String, clientId: UUID, for session: MessageSessionRef
    ) -> MessageRenderedMessage? {
        guard var state = states[session] else { return nil }
        let syntheticSeq = state.nextSyntheticSeq
        state.nextSyntheticSeq -= 1
        let pending = SessionRecord(event: SessionEvent(
            type: "user/message", seq: syntheticSeq, time: now() * 1000,
            data: .object([
                "id": .string(clientId.uuidString),
                "text": .string(text),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "source": .object(["kind": .string("user"), "rpcId": .string(clientId.uuidString)]),
            ]), surfaceOp: nil))
        let message = MessageRenderedMessage(id: clientId, seq: syntheticSeq, record: pending, status: .pending)
        state.rows[syntheticSeq] = message
        state.pendingSeqs[clientId] = syntheticSeq
        states[session] = state
        broadcast(MessageSnapshotDiff(changes: [.insert([.message(message)])]), to: state.continuations)
        return message
    }

    /// ③④：调网络面；回包非 nil 立即原地替换 + 落库确认，nil 则等下行 rpcId 确认。
    private func dispatch(clientId: UUID, text: String, steer: Bool, for session: MessageSessionRef) async throws {
        guard let confirmed = try await sender(session, text, clientId, steer) else { return }
        replacePending(clientId: clientId, with: confirmed, status: .sent, for: session)
        await pipeline(for: session).enqueueWrite(.confirmPending(
            scope: session.scope, sessionId: session.sessionId,
            clientId: clientId.uuidString, record: confirmed), key: confirmed.event.seq)
    }

    /// failed → pending（重发开始的视觉回标，身份与位置都不动）。
    private func markPending(clientId: UUID, for session: MessageSessionRef) {
        guard var state = states[session],
              let seq = state.pendingSeqs[clientId],
              let old = state.rows[seq], old.status != .pending else { return }
        let message = MessageRenderedMessage(id: clientId, seq: seq, record: old.record, status: .pending)
        state.rows[seq] = message
        states[session] = state
        broadcast(MessageSnapshotDiff(changes: [.update([.message(message)])]), to: state.continuations)
    }

    /// pending → sent/failed 原地替换：同一 UUID、同一行位置语义，只换内容与状态。
    private func replacePending(
        clientId: UUID, with confirmed: SessionRecord?,
        status: MessageSendStatus, for session: MessageSessionRef
    ) {
        guard var state = states[session],
              let syntheticSeq = state.pendingSeqs[clientId],
              let old = state.rows[syntheticSeq]
        else { return }
        state.rows.removeValue(forKey: syntheticSeq)
        // 只有确认才摘除跟踪：failed 留着，等重发或下行确认救回。
        if confirmed != nil { state.pendingSeqs.removeValue(forKey: clientId) }
        let record = confirmed ?? old.record
        let seq = confirmed?.event.seq ?? syntheticSeq
        let message = MessageRenderedMessage(id: clientId, seq: seq, record: record, status: status)
        state.rows[seq] = message
        if confirmed != nil { state.identities[seq] = clientId }
        states[session] = state
        broadcast(MessageSnapshotDiff(changes: [.update([.message(message)])]), to: state.continuations)
    }
}
