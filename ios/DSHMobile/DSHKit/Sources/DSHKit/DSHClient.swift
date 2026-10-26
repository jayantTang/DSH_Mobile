import Foundation

/// Typed access to every DSH capability the phone needs.
///
/// `DSHClient` owns no transport state of its own: hand it an `HTTPCarrier` for
/// a same-LAN connection, or a `LinkCarrier` to reach a machine behind NAT.
/// The method surface mirrors DSH's own endpoint names one-to-one, so the DSH
/// protocol reference doubles as the documentation for this type.
struct DSHClient: Sendable {
    /// 连接器在 `_link/hello` 里声明的能力（连接时才知道，缺省为空表示"还不知道"）。
    public static let sessionDigestCapability = "session-digest"

    public let carrier: any DSHCarrier
    public let capabilities: Set<String>

    public init(carrier: any DSHCarrier, capabilities: Set<String> = []) {
        self.carrier = carrier
        self.capabilities = capabilities
    }

    // MARK: - Sessions

    /// Lists sessions, newest first.
    /// The whole session list, in one call.
    ///
    /// `SessionListRequest.cursor` exists on the wire but is **inert in this
    /// deployment** — a bogus cursor returns the same full list and no
    /// `nextCursor` comes back (documented, with a verification note, in
    /// `docs/DSH-PROTOCOL.md` §"accepted but ignored"). The helper therefore does
    /// not offer a cursor parameter: an unused knob is an invitation to build
    /// pagination that silently pages nothing.
    public func sessions() async throws -> SessionListValue {
        // 连接器会答 `_link/sessionDigest` 时走精简版：同一份数据，少 66% 字节，压缩后少 93%
        // （spec 021）。**失败必须回退**：能力是握手时声明的，但一次调用失败不该让列表打不开，
        // 老连接器、半路升级、压缩格式对不上都要能落到 `session/list` 上。
        if capabilities.contains(Self.sessionDigestCapability) {
            // 回退分级（spec 022 FR-006 / T003）：传输类失败先对摘要通道退避重试（≤2 次），
            // 再败才回退旧通道；`link/unsupported` 与格式类是"这条路不存在/对不上"，
            // 直接回退，不重试——链路最差的时候拿 20 倍大的报文立即重试正是风暴放大器。
            var digestAttempts = 0
            let maxDigestAttempts = 3
            while true {
                digestAttempts += 1
                do {
                    return try await sessionDigest()
                } catch {
                    if Self.isTransportFailure(error), digestAttempts < maxDigestAttempts {
                        // 短暂退避后再打同一通道（FR-006：回退也走退避）。
                        try? await Task.sleep(for: .milliseconds(600))
                        continue
                    }
                    await noteListFallback(error: error)
                    return try await legacySessionList()
                }
            }
        }
        return try await legacySessionList()
    }

    private func legacySessionList() async throws -> SessionListValue {
        try await carrier.unary(
            method: "session/list",
            args: UnderscoreRequestArgs(_request: SessionListRequest()),
            as: SessionListValue.self
        )
    }

    /// 回退原因写进 App 诊断 ring（FR-007）：只有 relay 通道（`LinkCarrier`）有 ring，
    /// direct 通道（`HTTPCarrier`）没有，跳过不算缺口。
    private func noteListFallback(error: any Error) async {
        guard let link = carrier as? LinkCarrier else { return }
        await link.diagnostics.record(kind: "list.fallback", detail: [
            "reason": .string(Self.fallbackReason(error)),
        ])
    }

    /// 传输类失败（通道本身病了，换条通道无济于事，值得原通道退避重试）。
    static func isTransportFailure(_ error: any Error) -> Bool {
        if let failure = error as? DSHRPCFailure {
            return ["link/timeout", "link/closed", "link/busy"].contains(failure.code)
        }
        if let transport = error as? DSHTransportError {
            switch transport {
            case .timedOut, .unreachable, .carrierClosed, .notConnected:
                return true
            default:
                return false
            }
        }
        // 网络栈错误（URLError 等）都算传输类。
        return error is URLError
    }

    /// `list.fallback` 的 reason 分类（plan §5 的三类 + 兜底）。
    static func fallbackReason(_ error: any Error) -> String {
        if let failure = error as? DSHRPCFailure, failure.code == "link/unsupported" {
            return "unsupported"
        }
        if let transport = error as? DSHTransportError, case .malformedResponse = transport {
            return "format"
        }
        if isTransportFailure(error) { return "transport-after-retry" }
        return "other"
    }

    /// 精简版会话列表（`_link/sessionDigest`，spec 021）。
    ///
    /// 调用方一般不需要直接用它：`sessions()` 会按能力自动选通道。留成公开方法是给
    /// 诊断/测试一条"强制走精简版"的路。
    public func sessionDigest(since: String? = nil) async throws -> SessionListValue {
        let envelope = try await carrier.unary(
            method: "_link/sessionDigest",
            args: SessionDigestRequest(_request: SessionListRequest(), encoding: "deflate-raw",
                                       since: since),
            as: SessionDigestEnvelope.self
        )
        return try decodeSessionDigest(envelope)
    }

    /// Reads one page of backwards history.
    public func sessionPage(_ request: SessionPageRequest) async throws -> SessionPage {
        try await carrier.unary(
            method: "session/page",
            args: RequestArgs(request: request),
            as: SessionPage.self
        )
    }

    /// Reads one **exact** backward window from the connector (spec 007).
    ///
    /// The caller must have seen `history-window` in the link handshake's
    /// capabilities; on a connector without it the call comes back as
    /// `link/unsupported`, and the caller keeps using `session/page`. Nothing here
    /// retries or falls back: which channel a session uses is the pager's
    /// decision, not a property of one request.
    /// 本连接该不该请求压缩：只在连接器声明了 `history-compression` 时。
    ///
    /// 放在这里而不是每个调用点各判一次：取页有三条路径（精确窗口、管道、灌库），
    /// 少判一处就会在弱网上多传一倍字节，而且很难从症状上看出来。
    public var historyWindowEncoding: String? {
        capabilities.contains(HistoryWindowWire.compressionCapability) ? "deflate-raw" : nil
    }

    /// 本连接该不该要求折叠感知下发：只在连接器声明了 `history-fold-summary` 时。
    ///
    /// 只用于**浏览翻页**（无 `roles`）。角色过滤的页可能从一轮中间开始，折叠判定
    /// 不可靠，调用方传 `fold: false`/不传。
    public var historyFoldEnabled: Bool {
        capabilities.contains(HistoryWindowWire.foldCapability)
    }

    /// 概要 v2（`history-fold-summary-v2`）：首屏只取讲话 + 概要 + 回答，
    /// `limit` 按轮数算。老连接器没有它，调用方继续用 v1 / 原事件。
    public var historySummaryFoldEnabled: Bool {
        capabilities.contains(HistoryWindowWire.summaryFoldCapability)
    }

    /// 覆盖信息（已知为空 + 版本）是否可用。
    public var historyCoverageEnabled: Bool {
        capabilities.contains(HistoryWindowWire.coverageCapability)
    }

    /// `history-window` 是连接器能力，不是所有部署都有；取页必须按它选通道。
    public var supportsExactHistoryWindow: Bool {
        capabilities.contains("history-window")
    }

    public func historyWindow(_ request: HistoryWindowRequest) async throws -> HistoryWindowValue {
        // 先按未类型化的 JSON 取回：连接器可能回纯 JSON，也可能回压缩信封
        // （`history-compression`）。按 `encoding` 字段识别，两种形态都能解；
        // 直接按 `HistoryWindowValue` 解会在压缩回包上失败。
        let raw = try await carrier.unary(
            method: "_link/sessionWindow",
            args: request,
            as: JSONValue.self
        )
        #if DEBUG
        let parseStarted = CFAbsoluteTimeGetCurrent()
        let value = try HistoryWindowWire.decode(raw)
        FoldPerfProbe.noteDecodeMs((CFAbsoluteTimeGetCurrent() - parseStarted) * 1000)
        return value
        #else
        return try HistoryWindowWire.decode(raw)
        #endif
    }

    /// Searches inside one session through the connector (spec 007).
    ///
    /// Caller must have seen `session-search` in the handshake; without it the
    /// connector answers `link/unsupported` and the caller keeps the on-device
    /// search over what is already loaded. Nothing here falls back on its own:
    /// which search a session offers is the sheet's decision (FR-015/FR-036).
    public func sessionFind(_ request: HistorySearchRequest) async throws -> HistorySearchValue {
        try await carrier.unary(
            method: "_link/sessionFind",
            args: request,
            as: HistorySearchValue.self
        )
    }

    /// Follows a session live, yielding an opening snapshot then durable events.
    public func follow(_ request: SessionFollowRequest) async -> AsyncThrowingStream<SessionFollowFrame, any Error> {
        let raw = await carrier.stream(endpoint: "session/follow", args: RequestArgs(request: request))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in raw {
                        let data = try JSONEncoder().encode(value)
                        do {
                            continuation.yield(try JSONDecoder().decode(SessionFollowFrame.self, from: data))
                        } catch {
                            // A frame this build cannot decode must not end the
                            // stream: `for try await` would terminate it and the
                            // transcript would freeze for good. Surface it as
                            // unknown so the rest of the turn still arrives.
                            continuation.yield(.unknown(type: "undecodable", raw: value))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Subscribes to the host's live control stream: queued messages, jobs, and
    /// projection updates for one session.
    func sessionControl() async -> AsyncThrowingStream<JSONValue, any Error> {
        await carrier.stream(endpoint: "session/control", args: EmptyArgs())
    }

    // MARK: - Jobs and subagents (spec 018)

    /// 连接器自己回答的活动名单方法名（`contracts/link-job-roster.md` §2）。
    public static let jobsRosterMethod = "_link/jobRoster"

    /// Follows one session's job list. Every frame is the **whole** list
    /// (`host-job-surface.md` §1); there is no natural end.
    ///
    /// A frame this build cannot decode is skipped rather than ending the
    /// stream: the next `rows` frame still replaces the list wholesale.
    public func jobList(sessionId: String) async -> AsyncThrowingStream<JobListFrame, any Error> {
        let raw = await carrier.stream(
            endpoint: "job/list",
            args: RequestArgs(request: JobListRequest(sessionId: sessionId))
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in raw {
                        guard let frame = Self.decode(JobListFrame.self, from: value) else { continue }
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Follows one job's output (`host-job-surface.md` §2).
    ///
    /// `sessionId` may be omitted for an unowned job; `from` is a byte offset and
    /// means "from the oldest byte the host still keeps".
    ///
    /// Three frame types arrive in order — `opened`, then `output` chunks, then
    /// `status` — and then the host closes the stream normally. A frame this
    /// build cannot decode becomes ``JobFollowFrame/unknown(type:raw:)``: ending
    /// the stream there would tell the user the job vanished.
    ///
    /// A frame whose `type` is `error` is **not** a frame this build can ignore:
    /// it means the host/connector refused or aborted the stream, so the stream
    /// ends by throwing instead of degrading to `.unknown` and reading on
    /// (`specs/018-mobile-activity-visibility/test-coverage.md` G8).
    public func jobFollow(
        sessionId: String? = nil,
        jobId: String,
        from: Int? = nil
    ) async -> AsyncThrowingStream<JobFollowFrame, any Error> {
        let raw = await carrier.stream(
            endpoint: "job/follow",
            args: RequestArgs(request: JobFollowRequest(sessionId: sessionId, jobId: jobId, from: from))
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in raw {
                        if let frame = Self.decode(JobFollowFrame.self, from: value) {
                            if case .unknown(let type, let frameRaw) = frame, type == "error" {
                                throw DSHTransportError.streamFailed(Self.streamFailure(from: frameRaw))
                            }
                            continuation.yield(frame)
                        } else {
                            continuation.yield(.unknown(type: "undecodable", raw: value))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads a stream's own `error` frame into the same failure type the
    /// carriers throw, so callers only need one branch ("the stream failed").
    ///
    /// Two shapes are accepted, because the error may come from the host or be
    /// wrapped by `$events`-style forwarding: `{"type":"error","error":{…}}`
    /// and the fields spread on the frame itself (`{"type":"error","code":…}`).
    static func streamFailure(from raw: JSONValue) -> DSHRPCFailure {
        let object = raw["error"]?.objectValue ?? raw.objectValue ?? [:]
        let code = object["code"]?.stringValue ?? "stream/error"
        let message = object["message"]?.stringValue ?? "the stream reported an error"
        return DSHRPCFailure(code: code, message: message, details: object["details"] ?? .object([:]))
    }

    /// Asks the host to stop one job (`host-job-surface.md` §3).
    ///
    /// `requested` only means "accepted": the row must wait for the roster to
    /// come back with the terminal status. `already-finished` is not a failure.
    public func jobKill(sessionId: String, jobId: String) async throws -> JobKillValue {
        try await carrier.unary(
            method: "job/kill",
            args: RequestArgs(request: JobKillRequest(sessionId: sessionId, jobId: jobId)),
            as: JobKillValue.self
        )
    }

    /// Stops a continuable subagent from its parent (`host-job-surface.md` §5).
    ///
    /// The host's schema pins `mode` to the literal `continuable`, so one-shot
    /// subagents have no independent stop; the UI must not offer one.
    public func subagentInterrupt(
        childSessionId: String,
        parentSessionId: String
    ) async throws -> SubagentInterruptValue {
        try await carrier.unary(
            method: "subagents/interruptByParent",
            args: SubagentInterruptRequest(
                childSessionId: childSessionId,
                parentSessionId: parentSessionId
            ),
            as: SubagentInterruptValue.self
        )
    }

    /// Reads the connector's aggregated activity roster (`link-job-roster.md` §2).
    ///
    /// Caller must have seen `jobs-roster` in the handshake; without it an older
    /// connector answers `link/unsupported` and every activity surface stays
    /// hidden. Nothing falls back: a per-session `job/list` stream per session is
    /// exactly the design this roster exists to avoid.
    public func activityRoster() async throws -> ActivityRoster {
        try await carrier.unary(
            method: Self.jobsRosterMethod,
            args: EmptyArgs(),
            as: ActivityRoster.self
        )
    }

    /// Decodes one stream frame without letting a decode bug end the stream.
    private static func decode<Frame: Decodable & Sendable>(
        _ type: Frame.Type,
        from value: JSONValue
    ) -> Frame? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(Frame.self, from: data)
    }

    public func createSession(_ request: SessionCreateRequest) async throws -> JSONValue {
        try await carrier.unary(method: "session/create", args: RequestArgs(request: request), as: JSONValue.self)
    }

    /// Submits a prompt, either queued behind the current turn or steered into it.
    public func prompt(_ request: SessionPromptRequest) async throws {
        try await carrier.unary(method: "session/prompt", args: RequestArgs(request: request))
    }

    public func cancel(sessionId: String) async throws {
        try await carrier.unary(
            method: "session/cancel",
            args: RequestArgs(request: SessionCancelRequest(sessionId: sessionId))
        )
    }

    public func rename(sessionId: String, title: String) async throws {
        try await carrier.unary(
            method: "session/rename",
            args: RequestArgs(request: SessionRenameRequest(sessionId: sessionId, title: title))
        )
    }

    public func forkSession(sessionId: String, atSeq: Int? = nil) async throws -> JSONValue {
        try await carrier.unary(
            method: "session/fork",
            args: RequestArgs(request: SessionForkRequest(sessionId: sessionId, atSeq: atSeq)),
            as: JSONValue.self
        )
    }

    func searchSessions(query: String) async throws -> JSONValue {
        try await carrier.unary(
            method: "session/search",
            args: RequestArgs(request: SessionSearchRequest(query: query)),
            as: JSONValue.self
        )
    }

    public func selectModel(sessionId: String, selection: ModelSelection) async throws {
        try await carrier.unary(
            method: "session/selectModel",
            args: RequestArgs(
                request: SessionSelectModelRequest(
                    sessionId: sessionId,
                    provider: selection.provider,
                    model: selection.model,
                    reasoningEffort: selection.reasoningEffort
                )
            )
        )
    }

    func updateQueue(sessionId: String, itemId: String, action: QueueAction) async throws {
        try await carrier.unary(
            method: "session/updateQueue",
            args: RequestArgs(
                request: SessionUpdateQueueRequest(sessionId: sessionId, itemId: itemId, action: action)
            )
        )
    }

    /// Fetches an uploaded attachment (image bytes) as base64.
    public func attachment(sessionId: String, attachmentId: String) async throws -> JSONValue {
        try await carrier.unary(
            method: "session/attachment",
            args: RequestArgs(
                request: SessionAttachmentRequest(sessionId: sessionId, attachmentId: attachmentId)
            ),
            as: JSONValue.self
        )
    }

    public func modelCatalog() async throws -> ModelCatalog {
        try await carrier.unary(method: "session/modelCatalog", as: ModelCatalog.self)
    }

    // MARK: - Skills and references

    func skills(sessionId: String) async throws -> SkillListValue {
        try await carrier.unary(
            method: "skills/list",
            args: RequestArgs(request: SkillListRequest(sessionId: sessionId)),
            as: SkillListValue.self
        )
    }

    /// Autocomplete candidates for `@` file references in the composer.
    public func fileReferences(agentId: String, query: String) async throws -> [FileReferenceCandidate] {
        try await carrier.unary(
            method: "fileReferences/list",
            args: FileReferenceArgs(agentId: agentId, query: query),
            as: [FileReferenceCandidate].self
        )
    }

    // MARK: - Workspace

    /// The workspace inventory arrives on the `workspace/follow` baseline
    /// rather than a dedicated list endpoint.
    func workspaceFollow() async -> AsyncThrowingStream<WorkspaceFrame, any Error> {
        let raw = await carrier.stream(endpoint: "workspace/follow", args: EmptyArgs())
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in raw {
                        let data = try JSONEncoder().encode(value)
                        if let frame = try? JSONDecoder().decode(WorkspaceFrame.self, from: data) {
                            continuation.yield(frame)
                        } else {
                            continuation.yield(.unknown(type: nil, raw: value))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads the workspace baseline, then hangs up.
    ///
    /// The stream is the only way to ask for workspaces; the baseline is its
    /// first frame, so there is no reason to hold the subscription open just to
    /// render a list.
    public func workspaces(timeout: Duration = .seconds(15)) async throws -> WorkspaceBaseline {
        let stream = await workspaceFollow()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        for try await frame in stream {
            if let baseline = frame.baseline { return baseline }
            if ContinuousClock.now > deadline { break }
        }
        throw DSHTransportError.timedOut(method: "workspace/follow")
    }

    /// Registers an existing directory as a Workspace, or resolves the one that
    /// already covers it.
    ///
    /// Idempotent on the host, which is what makes it safe to call before every
    /// new session: the host canonicalizes the path (symlinks included) and
    /// returns the registration that already exists rather than a second one.
    /// That is also why the phone does not try to match a directory to a
    /// workspace itself — it would have to reproduce `realpath` to be right.
    public func createWorkspace(path: String) async throws -> WorkspaceCreateValue {
        try await carrier.unary(
            method: "workspace/create",
            args: RequestArgs(request: WorkspaceCreateRequest(path: path)),
            as: WorkspaceCreateValue.self
        )
    }

    public func deleteWorkspace(id: String) async throws {
        try await carrier.unary(
            method: "workspace/delete",
            args: RequestArgs(request: WorkspaceDeleteRequest(workspaceId: id))
        )
    }

    func renameWorkspace(id: String, title: String) async throws {
        try await carrier.unary(
            method: "workspace/rename",
            args: RequestArgs(request: WorkspaceRenameRequest(workspaceId: id, title: title))
        )
    }

    /// Files a session out of the workspace surfaces, or puts it back.
    ///
    /// Returns the full archived set, which is what the list is filtered by.
    @discardableResult
    public func archiveSession(_ sessionId: String, archived: Bool = true) async throws -> [String] {
        let raw = try await carrier.unary(
            method: "workspace/archiveSession",
            args: RequestArgs(request: WorkspaceArchiveRequest(sessionId: sessionId, archived: archived)),
            as: JSONValue.self
        )
        return (raw["archivedSessionIds"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    // MARK: - Workspace files

    public func workspaceFiles(scopeId: String, path: String) async throws -> JSONValue {
        try await carrier.unary(
            method: "workspaceFiles/list",
            args: WorkspaceFileArgs(workspaceFileScopeId: scopeId, path: path),
            as: JSONValue.self
        )
    }

    /// 连电脑本机补过 mtime 的目录清单（连接器自答方法，设计 20261024）。
    ///
    /// 与 `workspaceFiles/list` 同形，条目可多一个 `mtimeMs`（Unix 纪元毫秒）。
    /// `root` 是工作区根的**本机绝对路径**——宿主不把根路径给出来，连接器要把条目名
    /// 解析成本机路径才能 `stat`，所以由 App 带上（它持有 `SessionSummary.cwd`）。
    /// 走哪条通道由 `LinkGateway.workspaceFiles` 决定，调用方不感知能力。
    public func dirListing(scopeId: String, path: String, root: String) async throws -> JSONValue {
        try await carrier.unary(
            method: "_link/dirListing",
            args: DirListingArgs(workspaceFileScopeId: scopeId, path: path, root: root),
            as: JSONValue.self
        )
    }

    public func workspaceFileRead(scopeId: String, path: String, range: JSONValue? = nil) async throws -> JSONValue {
        try await carrier.unary(
            method: "workspaceFiles/read",
            args: WorkspaceFileRangeArgs(workspaceFileScopeId: scopeId, path: path, range: range),
            as: JSONValue.self
        )
    }

    public func workspaceFileStat(scopeId: String, path: String) async throws -> JSONValue {
        try await carrier.unary(
            method: "workspaceFiles/stat",
            args: WorkspaceFileArgs(workspaceFileScopeId: scopeId, path: path),
            as: JSONValue.self
        )
    }

    /// The whole file in one call, base64 in `data`.
    ///
    /// `workspaceFiles/read` pages by line and is the right call for reading
    /// code; this one exists for the files that are fetched to be *rendered*
    /// rather than scrolled — an HTML report and the pictures beside it — where
    /// paging would mean a round trip per page for a file the client is about to
    /// hand to a web view anyway.
    func workspaceFileReadAll(scopeId: String, path: String) async throws -> JSONValue {
        try await carrier.unary(
            method: "workspaceFiles/readAll",
            args: WorkspaceFileArgs(workspaceFileScopeId: scopeId, path: path),
            as: JSONValue.self
        )
    }

    /// A byte range of a binary file, base64 in `data`.
    ///
    /// The host wants an explicit range and names its two fields `offset` and
    /// `length` — **not** the `limit` that `workspaceFiles/read` uses for lines.
    /// The names are not interchangeable: an unknown field is ignored, so sending
    /// `limit` here silently gets the deployment's default window instead of the
    /// one asked for. A window larger than the host's `maxBytes` (2 MiB by
    /// default) is refused with `workspace-file/too-large` rather than shortened,
    /// so a caller wanting a whole file pages until `eof` and shrinks its window
    /// if a deployment has a smaller cap.
    public func workspaceFileReadBytes(
        scopeId: String,
        path: String,
        offset: Int,
        length: Int
    ) async throws -> JSONValue {
        try await carrier.unary(
            method: "workspaceFiles/readBytes",
            args: WorkspaceFileRangeArgs(
                workspaceFileScopeId: scopeId,
                path: path,
                range: .object(["offset": .int(offset), "length": .int(length)])
            ),
            as: JSONValue.self
        )
    }

    /// The working-tree change feed.
    ///
    /// Despite taking a simple scope argument, the host declares this a **stream
    /// Remote**: it is served on the mux carrier and refuses a unary call with
    /// `gateway/signature-invalid`. The stream opens with a `ready` frame and
    /// then reports change observations.
    public func workspaceChanges(scopeId: String) async -> AsyncThrowingStream<JSONValue, any Error> {
        await carrier.stream(
            endpoint: "workspaceFiles/changes",
            args: WorkspaceScopeArgs(workspaceFileScopeId: scopeId)
        )
    }

    func workspaceFileReadRelated(scopeId: String, path: String, relativePath: String) async throws -> JSONValue {
        try await carrier.unary(
            method: "workspaceFiles/readRelated",
            args: WorkspaceFileRelatedArgs(
                workspaceFileScopeId: scopeId,
                path: path,
                relativePath: relativePath
            ),
            as: JSONValue.self
        )
    }

    // MARK: - Settings

    public func settings() async throws -> JSONValue {
        try await carrier.unary(method: "settings/describe", args: EmptyArgs(), as: JSONValue.self)
    }

    /// Applies a partial settings patch.
    ///
    /// `expectedRevision` is the revision the caller last observed. Passing it
    /// makes the host reject a concurrent edit with `settings/conflict` instead
    /// of silently overwriting someone else's change; omitting it is
    /// last-write-wins.
    public func updateSettings(namespace: String, patch: JSONValue, expectedRevision: Int? = nil) async throws {
        try await carrier.unary(
            method: "settings/update",
            args: SettingsUpdateArgs(ns: namespace, patch: patch, expectedRevision: expectedRevision)
        )
    }

    /// Replaces a whole settings section.
    public func replaceSettings(namespace: String, section: JSONValue, expectedRevision: Int? = nil) async throws {
        try await carrier.unary(
            method: "settings/replace",
            args: SettingsReplaceArgs(ns: namespace, section: section, expectedRevision: expectedRevision)
        )
    }

    func mutateSettings(namespace: String, ops: JSONValue) async throws {
        try await carrier.unary(
            method: "settings/mutate",
            args: SettingsMutateArgs(ns: namespace, ops: ops)
        )
    }

    // MARK: - Credentials

    public func describeCredentials(refs: [JSONValue]) async throws -> JSONValue {
        try await carrier.unary(
            method: "credentials/describe",
            args: CredentialsDescribeArgs(refs: refs),
            as: JSONValue.self
        )
    }

    public func setCredential(ref: JSONValue, value: String) async throws {
        try await carrier.unary(
            method: "credentials/set",
            args: CredentialsSetArgs(ref: ref, value: value)
        )
    }

    public func unsetCredential(ref: JSONValue) async throws {
        try await carrier.unary(method: "credentials/unset", args: CredentialsUnsetArgs(ref: ref))
    }

    // MARK: - Directory picker

    /// Opens the host's own OS directory chooser, for a host whose picker is
    /// the `native` backend.
    ///
    /// Useless from a phone: the dialog opens on the host's display, where
    /// nobody is sitting. Kept because the endpoint exists and a host on the
    /// same LAN may be attended; the phone's own browser uses
    /// ``directoryListing(path:)`` instead.
    func pickDirectory() async throws -> JSONValue {
        try await carrier.unary(method: "directoryPicker/pick", args: EmptyArgs(), as: JSONValue.self)
    }

    /// Lists one directory level on the host, for the in-app browser.
    ///
    /// Served by the host's **browse** picker backend, which is the one that
    /// works for remote clients — nothing renders on the host's display. A host
    /// composed with the `native` backend answers `directory-picker/unavailable`
    /// rather than listing anything, so the phone must be able to say "this
    /// computer cannot be browsed" instead of looking empty.
    ///
    /// - Parameter path: an absolute directory; `nil` lists the host account's
    ///   home directory.
    public func directoryListing(path: String? = nil) async throws -> HostDirectoryListing {
        try await carrier.unary(
            method: "directoryPicker/list",
            args: DirectoryListArgs(path: path),
            as: HostDirectoryListing.self
        )
    }

    /// Creates one child directory under an existing parent and returns its
    /// absolute path.
    ///
    /// Non-recursive by contract: a missing parent is a failure, not a level to
    /// invent, and `name` must be a single path segment.
    public func createDirectory(parent: String, name: String) async throws -> String {
        try await carrier.unary(
            method: "directoryPicker/createDirectory",
            args: DirectoryCreateArgs(path: parent, name: name),
            as: String.self
        )
    }

    // MARK: - Host events

    /// Opens the forwarded host event stream.
    ///
    /// The first frame is always `ready` and carries the `clientId` that any
    /// subsequent waterfall answer must quote.
    public func hostEvents() async -> AsyncThrowingStream<HostEvent, any Error> {
        let raw = await carrier.stream(endpoint: "$events", args: EmptyArgs())
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in raw {
                        let data = try JSONEncoder().encode(value)
                        continuation.yield(try JSONDecoder().decode(HostEvent.self, from: data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Answers a host waterfall, releasing the host's pending continuation.
    public func answer(_ result: EventAnswer) async throws {
        let value = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: value)
        try await carrier.eventResult(decoded)
    }
}

// MARK: - Argument carriers

/// The wire shape of `session/list`'s args.
///
/// `cursor` is part of the protocol but inert in this deployment (no `nextCursor`
/// comes back), so nothing in the app sets it — it is modelled only so the
/// request keeps matching the descriptor the host validates against.
struct SessionListRequest: Encodable, Sendable {
    var cursor: String?

    init(cursor: String? = nil) {
        self.cursor = cursor
    }
}

/// `_link/sessionDigest` 的 args（spec 021）。
///
/// `_request` 与 `session/list` 同形（宿主目前忽略其中的选择器）；
/// `encoding` 只认 `deflate-raw`，连接器对别的值按不压缩处理，不会报错。
struct SessionDigestRequest: Encodable, Sendable {
    var _request: SessionListRequest
    var encoding: String
    /// 上一次收到的覆盖版本；带上则只回变化项，不带回全量。
    var since: String?
}

public struct SessionCreateRequest: Encodable, Sendable {
    public var workspaceId: String?
    public var cwd: String?
    public var sessionId: String?
    public var agentPreset: String?

    public init(workspaceId: String? = nil, cwd: String? = nil, sessionId: String? = nil, agentPreset: String? = nil) {
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.sessionId = sessionId
        self.agentPreset = agentPreset
    }
}

public struct SessionPromptRequest: Encodable, Sendable {
    public enum Mode: String, Encodable, Sendable {
        /// Queue behind the running turn.
        case queue
        /// Interrupt and steer the running turn.
        case steer
    }

    public let requestId: String
    public let sessionId: String
    public let mode: Mode
    public let content: [PromptContentPart]
    let clientTimeZone: String?

    public init(
        requestId: String = UUID().uuidString,
        sessionId: String,
        mode: Mode,
        content: [PromptContentPart],
        clientTimeZone: String? = TimeZone.current.identifier
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.mode = mode
        self.content = content
        self.clientTimeZone = clientTimeZone
    }
}

struct SessionCancelRequest: Encodable, Sendable {
    public let sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}

struct SessionRenameRequest: Encodable, Sendable {
    public let sessionId: String
    public let title: String
    public init(sessionId: String, title: String) {
        self.sessionId = sessionId
        self.title = title
    }
}

struct SessionForkRequest: Encodable, Sendable {
    public let sessionId: String
    let atSeq: Int?
    public init(sessionId: String, atSeq: Int? = nil) {
        self.sessionId = sessionId
        self.atSeq = atSeq
    }
}

struct SessionSearchRequest: Encodable, Sendable {
    public let query: String
    public init(query: String) { self.query = query }
}

struct SessionSelectModelRequest: Encodable, Sendable {
    public let sessionId: String
    public let provider: String
    public let model: String
    public let reasoningEffort: String?

    public init(sessionId: String, provider: String, model: String, reasoningEffort: String?) {
        self.sessionId = sessionId
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public struct SessionUpdateQueueRequest: Encodable, Sendable {
    public let sessionId: String
    let itemId: String
    public let action: QueueAction

    public init(sessionId: String, itemId: String, action: QueueAction) {
        self.sessionId = sessionId
        self.itemId = itemId
        self.action = action
    }
}

struct SessionAttachmentRequest: Encodable, Sendable {
    public let sessionId: String
    public let attachmentId: String
}

/// A queued-message mutation.
public enum QueueAction: Sendable, Encodable {
    case remove
    case steer

    private enum CodingKeys: String, CodingKey { case kind }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .remove: try container.encode("remove", forKey: .kind)
        case .steer: try container.encode("steer", forKey: .kind)
        }
    }
}

public struct SkillListRequest: Encodable, Sendable {
    public let sessionId: String
}

struct FileReferenceArgs: Encodable, Sendable {
    public let agentId: String
    public let query: String
}

public struct WorkspaceCreateRequest: Encodable, Sendable {
    public let path: String
}

struct WorkspaceDeleteRequest: Encodable, Sendable {
    public let workspaceId: String
}

struct WorkspaceRenameRequest: Encodable, Sendable {
    public let workspaceId: String
    /// The host calls this field `title`, not `name`; sending the wrong key
    /// fails the whole rename with a schema error.
    public let title: String
}

struct WorkspaceArchiveRequest: Encodable, Sendable {
    public let sessionId: String
    /// False puts the session back. Archiving is a filing decision, not a
    /// deletion, so the phone offers it as a swipe with an undo.
    public let archived: Bool?

    public init(sessionId: String, archived: Bool? = nil) {
        self.sessionId = sessionId
        self.archived = archived
    }
}

struct WorkspaceScopeArgs: Encodable, Sendable {
    public let workspaceFileScopeId: String
}

struct WorkspaceFileArgs: Encodable, Sendable {
    public let workspaceFileScopeId: String
    public let path: String
}

/// `_link/dirListing` 的参数：与 `workspaceFiles/list` 同语法，多一个本机工作区根。
struct DirListingArgs: Encodable, Sendable {
    public let workspaceFileScopeId: String
    public let path: String
    let root: String
}

struct WorkspaceFileRangeArgs: Encodable, Sendable {
    public let workspaceFileScopeId: String
    public let path: String
    public let range: JSONValue?
}

struct WorkspaceFileRelatedArgs: Encodable, Sendable {
    public let workspaceFileScopeId: String
    public let path: String
    let relativePath: String
}

struct SettingsUpdateArgs: Encodable, Sendable {
    public let ns: String
    public let patch: JSONValue
    /// Omitted when nil, because the host treats an absent revision as
    /// unconditional and a present-but-null one as invalid.
    let expectedRevision: Int?
}

struct SettingsReplaceArgs: Encodable, Sendable {
    public let ns: String
    public let section: JSONValue
    let expectedRevision: Int?
}

struct SettingsMutateArgs: Encodable, Sendable {
    public let ns: String
    let ops: JSONValue
}

struct CredentialsDescribeArgs: Encodable, Sendable {
    public let refs: [JSONValue]
}

struct CredentialsSetArgs: Encodable, Sendable {
    public let ref: JSONValue
    public let value: String
}

struct CredentialsUnsetArgs: Encodable, Sendable {
    public let ref: JSONValue
}
