import DSHFoundation
import DSHKit
import Foundation

/// 单条步骤正文的按需取数（概要 v2 的步骤卡）。
///
/// 概要把过程正文全部省掉了展开成本，代价是"点开单条"要取一次正文。这里只管
/// 这一件事：按 `bodySeq`（工具取结果 seq、思考取自身 seq）取一条记录，解析成
/// 正文，写进 `stepBodies`；成功的正文进磁盘 meta，二次打开先读缓存、不再请求。
///
/// 三态（加载/成功/失败）都落在模型上，卡片只渲染；失败只影响这一张卡，
/// 重试也只重发这一条。
public extension ChatModel {

    /// 步骤卡是不是展开着（会话级显示状态，与轮次/分组同一套归属）。
    func isProcessStepExpanded(_ stepId: String) -> Bool {
        foldState.expandedSteps.contains(stepId)
    }

    /// 点一下步骤卡：展开时按需取正文，收起时只改状态。
    @MainActor
    func toggleProcessStep(_ stepId: String) {
        guard let step = processStep(for: stepId) else { return }
        if foldState.expandedSteps.contains(stepId) {
            foldState.expandedSteps.remove(stepId)
            return
        }
        foldState.expandedSteps.insert(stepId)
        if stepBodies[stepId] == .tooLarge { return }
        // 概要已经给了大小：超限的当场落终态，视图下一帧就写「输出过大」。
        if let bytes = step.bytes, bytes > TimelineProcessStep.detailMaxBytes {
            stepBodies[stepId] = .tooLarge
            return
        }
        guard stepBodies[stepId] == nil else { return }
        stepBodyTasks[stepId] = Task { [weak self] in
            await self?.loadProcessStepBody(step)
        }
    }

    /// 卡片里的「点按重试」：只重发这一条。
    @MainActor
    func retryProcessStepBody(_ stepId: String) {
        // 终态不重试：超出上限的结果再取一次也是同一个结果。
        guard stepBodies[stepId] != .tooLarge else { return }
        guard let step = processStep(for: stepId) else { return }
        stepBodyTasks[stepId] = Task { [weak self] in
            await self?.loadProcessStepBody(step, force: true)
        }
    }

    /// 计划里的步骤行（含所属分组/轮次），拿不到就什么都不做。
    func processStep(for stepId: String) -> TimelineProcessStep? {
        for turn in processPlan().turns {
            for group in turn.groups {
                if let step = group.steps.first(where: { $0.id == stepId }) { return step }
            }
        }
        return nil
    }

    /// 取一条步骤的正文。
    ///
    /// 顺序：内存 → 磁盘 meta 缓存 → 一次小窗口请求（`limit: 1`，只取 `bodySeq`
    /// 那一条）。取回的那条记录必须正好是 `bodySeq`，否则按失败处理（宿主裁剪
    /// 过日志时 `limit: 1` 会还回更早的一条，那不是这一条的内容）。
    @MainActor
    func loadProcessStepBody(_ step: TimelineProcessStep, force: Bool = false) async {
        if stepBodies[step.id] == .tooLarge { return }
        // 概要已经给了正文大小：超过单条上限的直接落终态，不发请求
        //（也不会掉进「点重试还是失败」的死循环）。
        if let bytes = step.bytes, bytes > TimelineProcessStep.detailMaxBytes {
            stepBodies[step.id] = .tooLarge
            return
        }
        if !force {
            if let state = stepBodies[step.id], state.text != nil { return }
            if let cached = await cachedStepBody(step) {
                stepBodies[step.id] = cached
                return
            }
        }
        guard let client = store?.chatHost, let address else {
            stepBodies[step.id] = .failed
            return
        }
        if case .loading = stepBodies[step.id], !force { return }
        stepBodies[step.id] = .loading
        #if DEBUG
        FoldPerfProbe.begin(.stepBody, fold: nil, limit: 1,
                            maxBytes: TimelineProcessStep.detailMaxBytes)
        #endif
        do {
            let request = step.detailRequest(address: address,
                                             encoding: client.historyWindowEncoding)
            let page: HistoryWindowValue
            #if DEBUG
            page = try await FoldPerfProbe.withActiveKind(.stepBody) {
                try await client.historyWindow(request)
            }
            let landedStarted = CFAbsoluteTimeGetCurrent()
            #else
            page = try await client.historyWindow(request)
            #endif
            guard let record = page.records.first(where: { $0.event.seq == step.bodySeq }),
                  let text = ProcessStepBodyReader.text(for: step.kind, in: record, seq: step.bodySeq)
            else {
                stepBodies[step.id] = .failed
                return
            }
            let bytes = text.utf8.count
            stepBodies[step.id] = .loaded(text: text, bytes: bytes)
            #if DEBUG
            let adoptionMs = (CFAbsoluteTimeGetCurrent() - landedStarted) * 1000
            FoldPerfProbe.finished(
                .stepBody, records: 1, bytes: bytes,
                parseMs: FoldPerfProbe.parseMs(.stepBody, adoptionMs: adoptionMs))
            #endif
            await storeStepBody(step, text: text, bytes: bytes)
            ChatProbe.shared.probeNote?("step.body", [
                "step": step.id, "bytes": String(bytes), "kind": step.kind.rawValue,
            ], true)
        } catch is CancellationError {
            stepBodies[step.id] = nil
        } catch let failure as DSHRPCFailure where failure.code == "link/too-large" {
            #if DEBUG
            FoldPerfProbe.failed(.stepBody, error: failure)
            #endif
            // 2 MB 都装不下一条：落终态，卡片写「输出过大」，不再提供重试。
            stepBodies[step.id] = .tooLarge
            ChatProbe.shared.probeNote?("step.bodyTooLarge", ["step": step.id], true)
        } catch {
            #if DEBUG
            FoldPerfProbe.failed(.stepBody, error: error)
            #endif
            stepBodies[step.id] = .failed
            ChatProbe.shared.probeNote?("step.bodyFailed", [
                "step": step.id, "reason": String(describing: error),
            ], true)
        }
    }

    // MARK: - 磁盘缓存（现有本地库的 meta 表；按会话一份，LRU + 总字节上限）

    /// 正文缓存的总预算（8 MB）。DEBUG 测试可以临时压小。
    static var stepBodyCacheLimitBytes = StepBodyCache.defaultLimitBytes

    private static func cacheKey(sessionId: String) -> String {
        TranscriptLocalCacheKeys.stepBodies(sessionId: sessionId)
    }

    private func loadBodyCache() async -> StepBodyCache {
        guard let layer = messageBacking, let scope = sessionScope,
              let sessionId = session?.sessionId,
              let raw = try? await layer.meta(Self.cacheKey(sessionId: sessionId), scope: scope),
              let data = raw.data(using: .utf8),
              let cache = try? JSONDecoder().decode(StepBodyCache.self, from: data)
        else { return StepBodyCache() }
        return cache
    }

    private func saveBodyCache(_ cache: StepBodyCache) async {
        guard let layer = messageBacking, let scope = sessionScope,
              let sessionId = session?.sessionId,
              let data = try? JSONEncoder().encode(cache),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        try? await layer.setMeta(Self.cacheKey(sessionId: sessionId), raw, scope: scope)
    }

    private func cachedStepBody(_ step: TimelineProcessStep) async -> ProcessStepBodyState? {
        var cache = await loadBodyCache()
        guard let text = cache.text(for: step.id) else { return nil }
        // 命中即算一次使用：挪到 LRU 最新端（下一次写入时落库）。
        cache.touch(step.id, at: Date())
        await saveBodyCache(cache)
        return .loaded(text: text, bytes: text.utf8.count)
    }

    private func storeStepBody(_ step: TimelineProcessStep, text: String, bytes: Int) async {
        var cache = await loadBodyCache()
        guard cache.record(step.id, text: text, bytes: bytes, at: Date(),
                           limitBytes: Self.stepBodyCacheLimitBytes) else { return }
        await saveBodyCache(cache)
    }
}
