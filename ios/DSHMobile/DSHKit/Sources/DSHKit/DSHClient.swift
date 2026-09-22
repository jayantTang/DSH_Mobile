import Foundation

/// Typed access to every DSH capability the phone needs.
///
/// `DSHClient` owns no transport state of its own: hand it an `HTTPCarrier` for
/// a same-LAN connection, or a `LinkCarrier` to reach a machine behind NAT.
/// The method surface mirrors DSH's own endpoint names one-to-one, so the DSH
/// protocol reference doubles as the documentation for this type.
public struct DSHClient: Sendable {
    public let carrier: any DSHCarrier

    public init(carrier: any DSHCarrier) {
        self.carrier = carrier
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
        try await carrier.unary(
            method: "session/list",
            args: UnderscoreRequestArgs(_request: SessionListRequest()),
            as: SessionListValue.self
        )
    }

    /// Reads one page of backwards history.
    public func sessionPage(_ request: SessionPageRequest) async throws -> SessionPage {
        try await carrier.unary(
            method: "session/page",
            args: RequestArgs(request: request),
            as: SessionPage.self
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
    public func sessionControl() async -> AsyncThrowingStream<JSONValue, any Error> {
        await carrier.stream(endpoint: "session/control", args: EmptyArgs())
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

    public func searchSessions(query: String) async throws -> JSONValue {
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

    public func updateQueue(sessionId: String, itemId: String, action: QueueAction) async throws {
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

    public func skills(sessionId: String) async throws -> SkillListValue {
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
    public func workspaceFollow() async -> AsyncThrowingStream<WorkspaceFrame, any Error> {
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

    public func renameWorkspace(id: String, title: String) async throws {
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
    public func workspaceFileReadAll(scopeId: String, path: String) async throws -> JSONValue {
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

    public func workspaceFileReadRelated(scopeId: String, path: String, relativePath: String) async throws -> JSONValue {
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

    public func mutateSettings(namespace: String, ops: JSONValue) async throws {
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
    public func pickDirectory() async throws -> JSONValue {
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
    public let clientTimeZone: String?

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

public struct SessionCancelRequest: Encodable, Sendable {
    public let sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}

public struct SessionRenameRequest: Encodable, Sendable {
    public let sessionId: String
    public let title: String
    public init(sessionId: String, title: String) {
        self.sessionId = sessionId
        self.title = title
    }
}

public struct SessionForkRequest: Encodable, Sendable {
    public let sessionId: String
    public let atSeq: Int?
    public init(sessionId: String, atSeq: Int? = nil) {
        self.sessionId = sessionId
        self.atSeq = atSeq
    }
}

public struct SessionSearchRequest: Encodable, Sendable {
    public let query: String
    public init(query: String) { self.query = query }
}

public struct SessionSelectModelRequest: Encodable, Sendable {
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
    public let itemId: String
    public let action: QueueAction

    public init(sessionId: String, itemId: String, action: QueueAction) {
        self.sessionId = sessionId
        self.itemId = itemId
        self.action = action
    }
}

public struct SessionAttachmentRequest: Encodable, Sendable {
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

public struct FileReferenceArgs: Encodable, Sendable {
    public let agentId: String
    public let query: String
}

public struct WorkspaceCreateRequest: Encodable, Sendable {
    public let path: String
}

public struct WorkspaceDeleteRequest: Encodable, Sendable {
    public let workspaceId: String
}

public struct WorkspaceRenameRequest: Encodable, Sendable {
    public let workspaceId: String
    /// The host calls this field `title`, not `name`; sending the wrong key
    /// fails the whole rename with a schema error.
    public let title: String
}

public struct WorkspaceArchiveRequest: Encodable, Sendable {
    public let sessionId: String
    /// False puts the session back. Archiving is a filing decision, not a
    /// deletion, so the phone offers it as a swipe with an undo.
    public let archived: Bool?

    public init(sessionId: String, archived: Bool? = nil) {
        self.sessionId = sessionId
        self.archived = archived
    }
}

public struct WorkspaceScopeArgs: Encodable, Sendable {
    public let workspaceFileScopeId: String
}

public struct WorkspaceFileArgs: Encodable, Sendable {
    public let workspaceFileScopeId: String
    public let path: String
}

public struct WorkspaceFileRangeArgs: Encodable, Sendable {
    public let workspaceFileScopeId: String
    public let path: String
    public let range: JSONValue?
}

public struct WorkspaceFileRelatedArgs: Encodable, Sendable {
    public let workspaceFileScopeId: String
    public let path: String
    public let relativePath: String
}

public struct SettingsUpdateArgs: Encodable, Sendable {
    public let ns: String
    public let patch: JSONValue
    /// Omitted when nil, because the host treats an absent revision as
    /// unconditional and a present-but-null one as invalid.
    public let expectedRevision: Int?
}

public struct SettingsReplaceArgs: Encodable, Sendable {
    public let ns: String
    public let section: JSONValue
    public let expectedRevision: Int?
}

public struct SettingsMutateArgs: Encodable, Sendable {
    public let ns: String
    public let ops: JSONValue
}

public struct CredentialsDescribeArgs: Encodable, Sendable {
    public let refs: [JSONValue]
}

public struct CredentialsSetArgs: Encodable, Sendable {
    public let ref: JSONValue
    public let value: String
}

public struct CredentialsUnsetArgs: Encodable, Sendable {
    public let ref: JSONValue
}
