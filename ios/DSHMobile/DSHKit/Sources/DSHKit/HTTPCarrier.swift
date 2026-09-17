import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Carrier that talks to a DSH host directly.
///
/// Used for same-LAN connections, where it needs no relay at all, and as the
/// reference implementation of the wire protocol that `LinkCarrier` mirrors.
///
/// Authentication mirrors the browser exactly: the process launch token is
/// exchanged once for a signed `dsh-auth-*` cookie, and every later `/api`
/// request carries that cookie. The cookie is bound to the host authority, so
/// the base URL must be reached under the same `host:port` DSH was configured
/// with — that is what `--trusted-host` is for when a LAN address or a relay
/// domain is used.
public actor HTTPCarrier: DSHCarrier {
    /// How the launch token is supplied.
    public enum Credential: Sendable {
        /// A launch token collected from the user, a QR code, or a file.
        case launchToken(String)
        /// An already-minted `dsh-auth-*` cookie, reused across launches.
        case cookie(name: String, value: String)
    }

    private let baseURL: URL
    private let cookieStorage: HTTPCookieStorage
    private var credential: Credential
    private let session: URLSession
    private let ids = CorrelationIds(prefix: "http")
    private let timeout: TimeInterval

    private var cookieHeader: String?
    private var mux: MuxConnection?
    private var didAuthenticate = false
    /// Set by `close()`. A closed carrier must fail fast rather than reach for a
    /// session that has already been invalidated, which aborts the process.
    private var isClosed = false

    /// - Parameters:
    ///   - baseURL: origin of the DSH host, e.g. `http://127.0.0.1:54499`.
    ///   - credential: the launch token or an existing cookie.
    ///   - session: an optional pre-configured session. When supplied it must
    ///     already accept cookies, since the mux WebSocket depends on the URL
    ///     loading system attaching them.
    ///   - timeout: per-request deadline for unary calls.
    public init(
        baseURL: URL,
        credential: Credential,
        session: URLSession? = nil,
        timeout: TimeInterval = 60
    ) {
        self.baseURL = baseURL
        self.credential = credential
        self.timeout = timeout

        if let session {
            self.session = session
            self.cookieStorage = session.configuration.httpCookieStorage ?? HTTPCookieStorage()
        } else {
            // The URL loading system only attaches cookies from the shared
            // storage to WebSocket upgrades; a privately constructed
            // `HTTPCookieStorage` is accepted as configuration but is not
            // consulted, which shows up as a handshake that never
            // authenticates. Cookies are host-scoped, so sharing the process
            // store cannot leak a credential to another authority.
            let storage = HTTPCookieStorage.shared
            let configuration = URLSessionConfiguration.ephemeral
            // Cookies must be attached by the URL loading system rather than as
            // a literal `Cookie` header. `URLSessionWebSocketTask` silently
            // drops a hand-set `Cookie` header on the upgrade request, which
            // surfaces as an unexplained socket failure rather than a 401.
            configuration.httpShouldSetCookies = true
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpCookieStorage = storage
            configuration.timeoutIntervalForRequest = timeout
            configuration.waitsForConnectivity = false
            self.cookieStorage = storage
            self.session = URLSession(
                configuration: configuration,
                delegate: RedirectBlocker(),
                delegateQueue: nil
            )
        }

        if case .cookie(let name, let value) = credential {
            Self.store(cookie: (name, value), for: baseURL, in: cookieStorage)
            self.cookieHeader = "\(name)=\(value)"
            self.didAuthenticate = true
        }
    }

    // MARK: - Authentication

    /// Exchanges the launch token for a session cookie.
    ///
    /// Idempotent: later calls are no-ops unless `force` is set, which is how
    /// the retry path recovers after DSH restarts and rotates its token.
    public func authenticate(force: Bool = false) async throws {
        guard !isClosed else { throw DSHTransportError.carrierClosed }
        if didAuthenticate && !force { return }
        guard case .launchToken(let token) = credential else { return }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw DSHTransportError.unreachable("invalid base URL \(baseURL)")
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            throw DSHTransportError.unreachable("could not build the token exchange URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // The handler answers with a 303 carrying Set-Cookie; capturing it
        // requires that the redirect itself is not followed.
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DSHTransportError.malformedResponse("token exchange returned a non-HTTP response")
        }
        guard let header = http.value(forHTTPHeaderField: "Set-Cookie") else {
            // A rejected token still answers with the ordinary redirect status
            // but mints no cookie, so the *absence* of Set-Cookie is the signal
            // rather than the status code alone.
            if (300..<400).contains(http.statusCode) || http.statusCode == 401 || http.statusCode == 403 {
                throw DSHTransportError.notAuthenticated(
                    "启动令牌无效或已失效（HTTP \(http.statusCode) 且未下发 Cookie）"
                )
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DSHTransportError.malformedResponse(
                "token exchange returned no cookie (HTTP \(http.statusCode)) \(body.prefix(200))"
            )
        }
        guard let parsed = Self.firstCookie(in: header) else {
            throw DSHTransportError.malformedResponse("could not parse Set-Cookie: \(header)")
        }

        // Installing it in the cookie storage is what makes the mux WebSocket
        // authenticated as well as plain HTTP calls.
        Self.store(cookie: parsed, for: baseURL, in: cookieStorage)
        cookieHeader = "\(parsed.name)=\(parsed.value)"
        credential = .cookie(name: parsed.name, value: parsed.value)
        didAuthenticate = true
    }

    /// The minted cookie, so a caller can persist it and skip the handshake.
    public var cookie: (name: String, value: String)? {
        guard let cookieHeader, let separator = cookieHeader.firstIndex(of: "=") else { return nil }
        return (String(cookieHeader[cookieHeader.startIndex..<separator]),
                String(cookieHeader[cookieHeader.index(after: separator)...]))
    }

    // MARK: - DSHCarrier

    public func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
        method: String,
        args: Args,
        as valueType: Value.Type
    ) async throws -> Value {
        do {
            return try await performUnary(method: method, args: args, as: valueType)
        } catch let failure as DSHRPCFailure where failure.isAuthenticationFailure {
            // DSH rotated its launch token underneath us: re-authenticate once.
            try await authenticate(force: true)
            await resetMux(reason: "re-authenticated")
            return try await performUnary(method: method, args: args, as: valueType)
        }
    }

    public func stream<Args: Encodable & Sendable>(
        endpoint: String,
        args: Args
    ) async -> AsyncThrowingStream<JSONValue, any Error> {
        do {
            try await authenticate()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        guard let argsData = try? JSONEncoder().encode(args) else {
            return AsyncThrowingStream {
                $0.finish(throwing: DSHTransportError.malformedResponse("stream args could not be encoded"))
            }
        }
        do {
            let connection = try await muxConnection()
            return await connection.open(endpoint: endpoint, args: argsData)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    /// Answers a host waterfall.
    ///
    /// The result *is* the argument object: the gateway validates it with
    /// `exactKeys(["clientId", "eventId", "outcome"])` and rejects anything
    /// else with "api gateway: invalid Remote event result". This used to wrap
    /// the three fields in a `result` envelope, so every answer the phone sent
    /// — options, free text, and "let the computer handle it" — came back as
    /// that error and the host stayed blocked.
    public func eventResult(_ result: JSONValue) async throws {
        try await unary(method: "$events/result", args: result)
    }

    public func close() async {
        isClosed = true
        await mux?.shutdown()
        mux = nil
        session.invalidateAndCancel()
    }

    // MARK: - Internals

    private func performUnary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
        method: String,
        args: Args,
        as valueType: Value.Type
    ) async throws -> Value {
        try await authenticate()

        let rpcId = await ids.next()
        let envelope = RPCRequestEnvelope(rpcId: rpcId, method: method, payload: .init(args: args))
        let body = try JSONEncoder().encode(envelope)

        // The endpoint name is path-significant: `session/list` maps onto
        // `/api/session/list`, and each segment is escaped independently.
        let url = method.split(separator: "/", omittingEmptySubsequences: false)
            .reduce(baseURL.appendingPathComponent("api")) { partial, segment in
                partial.appendingPathComponent(String(segment))
            }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut {
                throw DSHTransportError.timedOut(method: method)
            }
            throw DSHTransportError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DSHTransportError.malformedResponse("response was not HTTP")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw DSHTransportError.notAuthenticated("HTTP \(http.statusCode) from \(method)")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw DSHTransportError.httpStatus(http.statusCode, body: text)
        }

        let decoded: RPCResponseEnvelope<Value>
        do {
            decoded = try JSONDecoder().decode(RPCResponseEnvelope<Value>.self, from: data)
        } catch {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            throw DSHTransportError.malformedResponse(
                "\(method): \(error) — body: \(text.prefix(400))"
            )
        }
        return try decoded.result.unwrapped()
    }

    private func muxConnection() async throws -> MuxConnection {
        // A screen can still be holding this client after the store replaced or
        // closed the carrier — a refresh in flight during a reconnect, say. It
        // has to hear "closed" rather than be handed a mux over a dead session.
        guard !isClosed else { throw DSHTransportError.carrierClosed }
        if let mux { return mux }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/api/remote.mux"
        components?.query = nil
        let url = components?.url ?? baseURL.appendingPathComponent("api/remote.mux")
        // No explicit Cookie header: the session's cookie storage supplies it,
        // and on an upgrade request a hand-set header would be dropped.
        let connection = MuxConnection(url: url, headers: [:], session: session)
        mux = connection
        return connection
    }

    private func resetMux(reason: String) async {
        await mux?.reset(reason: reason)
        mux = nil
    }

    /// Extracts the first cookie pair from a `Set-Cookie` header value.
    static func firstCookie(in header: String) -> (name: String, value: String)? {
        guard let pair = header.split(separator: ";").first else { return nil }
        let trimmed = pair.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(of: "=") else { return nil }
        let name = String(trimmed[trimmed.startIndex..<separator])
        let value = String(trimmed[trimmed.index(after: separator)...])
        guard !name.isEmpty, !value.isEmpty else { return nil }
        return (name, value)
    }

    /// Installs a cookie so the URL loading system attaches it to every request.
    static func store(cookie: (name: String, value: String), for baseURL: URL, in storage: HTTPCookieStorage) {
        guard let host = baseURL.host else { return }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: host,
            .path: "/",
            .name: cookie.name,
            .value: cookie.value,
        ]
        // DSH mints the cookie without `Secure`, but mark it when the transport
        // is TLS so the URL loading system applies the usual protections.
        if baseURL.scheme == "https" {
            properties[.secure] = "TRUE"
        }
        if let httpCookie = HTTPCookie(properties: properties) {
            storage.setCookie(httpCookie)
        }
    }
}

/// Prevents `URLSession` from following redirects.
///
/// The launch-token exchange signals success with a `303` whose `Set-Cookie`
/// is the payload; following it would discard exactly what we need.
final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
