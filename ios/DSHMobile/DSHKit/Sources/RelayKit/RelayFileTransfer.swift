import Foundation
import DSHKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends a large file through the relay with a **background** URL session.
///
/// Why this exists next to `FileUploader`: the WebSocket path is fine for a few
/// megabytes, but the system suspends the app (and its socket) once it leaves the
/// foreground, and `URLSessionWebSocketTask` cannot be carried by a background
/// session at all. Apple's answer is a *file-based* background task, which the
/// system finishes on the app's behalf — so a large upload survives the app being
/// backgrounded, and that is what lets the silent-audio keep-alive go away.
///
/// The relay is the endpoint because the phone cannot reach the computer (the
/// connector dials out and listens on loopback only). The relay writes nothing:
/// it pumps the bytes straight out over the connector's socket, and the connector
/// stages the file where the agent can read it.
///
/// Two rules this type is built around:
///
/// * the task is **file-based** (`uploadTask(with:fromFile:)`), because only a
///   file task is continued in the background. Callers hand over a URL in the
///   app's own container, never `Data`.
/// * `isDiscretionary` stays **false**. Left true the system batches transfers
///   for "a good moment" (typically charging, on Wi-Fi) and the user concludes
///   the app simply did not send anything.
public struct RelayFileTransfer: Sendable {

    /// Relay origin in HTTP form, including any mount prefix.
    public let relayURL: URL
    /// This phone's device credential.
    public let deviceToken: String

    private let session: URLSession
    private let ownsSession: Bool

    /// The background session identifier.
    ///
    /// Fixed rather than per-call: iOS keeps one session per identifier for the
    /// life of the app, and a fresh identifier per upload would leak a session
    /// each time (and orphan its tasks across launches).
    public static let sessionIdentifier = "com.jayanttang.dsh.relay-file-transfer"

    /// A background configuration, or `nil` where there is no such thing.
    ///
    /// `URLSessionConfiguration.background` does not exist on macOS, and the
    /// package builds for both (the test suite runs on macOS). Callers that need
    /// the real thing must be on iOS; on macOS this reads as "cannot".
    public static func backgroundConfiguration() -> URLSessionConfiguration? {
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        // The system relaunches the app into the background when the transfer
        // finishes; without this the delegate is never told and the completion
        // handler never runs.
        configuration.sessionSendsLaunchEvents = true
        // Deliberately default (false): see the note on the type.
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpShouldSetCookies = false
        return configuration
        #else
        return nil
        #endif
    }

    /// - Parameter session: injected for tests. Production callers pass `nil` and
    ///   get the background session; the unit tests must not open one (macOS can
    ///   not exercise iOS background semantics, so a test that opened one would
    ///   be proving nothing about the real behaviour).
    public init(relayURL: URL, deviceToken: String, session: URLSession? = nil) {
        self.relayURL = relayURL
        self.deviceToken = deviceToken
        if let session {
            self.session = session
            self.ownsSession = false
        } else if let configuration = Self.backgroundConfiguration() {
            self.session = URLSession(configuration: configuration)
            self.ownsSession = true
        } else {
            // No background sessions here (macOS): a plain session still performs
            // the request correctly, it just will not survive suspension.
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
            self.ownsSession = true
        }
    }

    /// The connector capability that turns this path on.
    ///
    /// Feature detection, not a version comparison: an older connector simply
    /// does not list the word, and the app then keeps using the WSS path.
    public static let capability = "background-transfer"

    /// Where one upload landed.
    public struct Staged: Decodable, Sendable {
        public let path: String
        public let bytes: Int

        /// The same shape the WSS path returns, so callers do not branch on which
        /// transport actually carried the file.
        public var asStaged: FileUploader.Staged {
            FileUploader.Staged(path: path, bytes: bytes)
        }
    }

    private struct ErrorEnvelope: Decodable {
        let ok: Bool?
        let error: DSHRPCFailure?
    }

    /// The upload's request, built but not started (tests inspect it; the caller
    /// hands it to the session).
    ///
    /// `bid` is the relay's correlation id and is **stable across retries** of the
    /// same attempt: the connector overwrites by `bid`, so a retried upload is
    /// idempotent instead of leaving a second file behind.
    public func request(fileURL: URL, name: String, sessionId: String, bid: String) -> URLRequest? {
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        components?.path = LinkConfiguration.appending(path: "/files/up", to: relayURL)
        components?.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "bytes", value: String(Self.fileSize(fileURL))),
            URLQueryItem(name: "bid", value: bid),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Starts an upload and returns a task the caller can await.
    ///
    /// Throws before anything is sent when the request cannot be built — the
    /// caller treats that the same way as any other failure and falls back.
    public func upload(
        fileURL: URL,
        name: String,
        sessionId: String,
        bid: String = UUID().uuidString
    ) async throws -> Staged {
        guard let request = request(fileURL: fileURL, name: name, sessionId: sessionId, bid: bid) else {
            throw DSHTransportError.unreachable("中转地址无效")
        }
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw DSHTransportError.malformedResponse("中转响应无效")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.failure(status: http.statusCode, body: data)
        }
        do {
            return try JSONDecoder().decode(Staged.self, from: data)
        } catch {
            throw DSHTransportError.malformedResponse("中转没有返回落盘路径")
        }
    }

    /// Whether a failure means "this path is not usable here — use the WSS one".
    ///
    /// * `501` — the connector does not speak the bridge frames (too old).
    /// * `413` — the relay refused the body size.
    /// * `404`/`501` from a relay that predates the route at all.
    ///
    /// Everything else (a timeout, a dropped connection) is worth reporting as a
    /// failure rather than silently re-sending the whole file over a socket that
    /// is about to be suspended anyway.
    public static func shouldFallBack(status: Int) -> Bool {
        status == 501 || status == 413 || status == 404 || status == 405
    }

    /// Whether the connector can serve this path at all.
    ///
    /// Feature detection, not a version comparison: a connector that lacks the
    /// capability does not list it, and an older app that does not know the word
    /// simply never asks.
    public static func supportsBackgroundTransfer(capabilities: [String]) -> Bool {
        capabilities.contains("background-transfer")
    }

    /// The size above which the background path is used.
    ///
    /// The threshold is a risk switch, not an optimisation: small files, which
    /// finish long before the app is suspended, stay on the already-proven WSS
    /// path, and setting it very high is the kill switch that restores today's
    /// behaviour exactly. It is a build setting on purpose — a user-visible knob
    /// would buy nothing and cost a decision.
    public static func thresholdBytes(value: String?) -> Int {
        let fallback = 8 * 1024 * 1024
        guard let value, let megabytes = Double(value.trimmingCharacters(in: .whitespaces)),
              megabytes >= 0 else { return fallback }
        return Int(megabytes * 1024 * 1024)
    }

    public static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func failure(status: Int, body: Data) -> any Error {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body),
           let failure = envelope.error {
            return failure
        }
        return DSHTransportError.httpStatus(status, body: String(data: body, encoding: .utf8))
    }
}
