import Foundation

/// One logical stream carried by the DSH mux WebSocket.
///
/// DSH multiplexes every stream — session follow, session control, workspace
/// follow, and the forwarded host event feed — over the single route
/// `/api/remote.mux`. This actor owns that one socket and routes frames to the
/// stream that opened them.
actor MuxConnection {
    typealias Stream = AsyncThrowingStream<JSONValue, any Error>

    /// Wire shape of one host-to-client mux frame.
    private struct ServerFrame: Decodable {
        let type: String
        let streamId: String
        let value: JSONValue?
        let error: DSHRPCFailure?
    }

    /// Wire shape of one client-to-host `open` frame.
    private struct OpenFrame<Args: Encodable & Sendable>: Encodable {
        let type = "open"
        let streamId: String
        let endpoint: String
        let payload: Payload

        struct Payload: Encodable { let args: Args }
    }

    private struct CancelFrame: Encodable {
        let type = "cancel"
        let streamId: String
    }

    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let heartbeatInterval: Duration

    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var heartbeatLoop: Task<Void, Never>?
    private var streams: [String: Stream.Continuation] = [:]
    private var counter: UInt64 = 0
    private var isShutDown = false

    init(url: URL, headers: [String: String], session: URLSession, heartbeatInterval: Duration = .seconds(20)) {
        self.url = url
        self.headers = headers
        self.session = session
        self.heartbeatInterval = heartbeatInterval
    }

    // MARK: - Public surface

    /// Opens a logical stream, connecting the mux socket on first use.
    ///
    /// The returned stream finishes when the host sends `end`, when the host
    /// reports an error, when the caller cancels, or when the socket drops.
    func open(endpoint: String, args: Data) -> Stream {
        guard !isShutDown else {
            return Stream { $0.finish(throwing: DSHTransportError.carrierClosed) }
        }

        counter += 1
        let streamId = "s\(counter)"

        let (stream, continuation) = Stream.makeStream(of: JSONValue.self)
        streams[streamId] = continuation
        continuation.onTermination = { [weak self] reason in
            guard let self else { return }
            Task {
                if case .cancelled = reason {
                    await self.cancel(streamId: streamId, notifyHost: true)
                } else {
                    await self.cancel(streamId: streamId, notifyHost: false)
                }
            }
        }

        Task {
            do {
                let socket = try await connectedSocket()
                // `RawJSONArgs` splices the caller's already-encoded argument
                // object into the frame without a decode/re-encode round trip.
                let frame = OpenFrame(
                    streamId: streamId,
                    endpoint: endpoint,
                    payload: .init(args: RawJSONArgs(data: args))
                )
                let data = try JSONEncoder().encode(frame)
                // DSH's mux accepts text frames only and closes the socket with
                // 1003 otherwise, so frames are sent as UTF-8 text.
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            } catch {
                self.fail(streamId: streamId, error: error)
            }
        }

        return stream
    }

    /// Sends a cancel for one logical stream and drops it locally.
    func cancel(streamId: String, notifyHost: Bool) {
        guard let continuation = streams.removeValue(forKey: streamId) else { return }
        continuation.finish()
        guard notifyHost, let socket = task else { return }
        Task {
            let data = try? JSONEncoder().encode(CancelFrame(streamId: streamId))
            if let data {
                try? await socket.send(.string(String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Tears the socket down and fails every outstanding stream.
    func shutdown() {
        isShutDown = true
        receiveLoop?.cancel()
        heartbeatLoop?.cancel()
        receiveLoop = nil
        heartbeatLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        let outstanding = streams
        streams.removeAll()
        for (_, continuation) in outstanding {
            continuation.finish(throwing: DSHTransportError.carrierClosed)
        }
    }

    /// Drops the socket and fails outstanding streams, staying reusable.
    ///
    /// Called when DSH restarts or the link reconnects: the next `open`
    /// re-establishes the socket instead of every caller seeing a dead carrier.
    func reset(reason: String) {
        receiveLoop?.cancel()
        heartbeatLoop?.cancel()
        receiveLoop = nil
        heartbeatLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        let outstanding = streams
        streams.removeAll()
        for (_, continuation) in outstanding {
            continuation.finish(throwing: DSHTransportError.unreachable(reason))
        }
    }

    // MARK: - Socket lifecycle

    private func connectedSocket() async throws -> URLSessionWebSocketTask {
        if let task, task.state == .running { return task }
        // Creating a WebSocket task on an invalidated `URLSession` does not throw
        // in Swift: CFNetwork raises an Objective-C exception, which nothing here
        // can catch and which aborts the process. A stream opened just before the
        // carrier was closed is exactly how that happens — a link drop or a
        // reconnect while a screen is still refreshing — so the state is checked
        // here, in the same actor-isolated step as the call itself.
        guard !isShutDown else { throw DSHTransportError.carrierClosed }

        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let socket = session.webSocketTask(with: request)
        // A `session/follow` opening snapshot carries the whole visible history
        // in a single frame and is routinely several hundred kilobytes, well
        // past the 1 MiB default. Without this the stream dies with an opaque
        // "Message too long" and the transcript never loads.
        socket.maximumMessageSize = Self.maximumMessageSize
        socket.resume()
        task = socket
        startReceiveLoop(on: socket)
        startHeartbeat(on: socket)
        return socket
    }

    /// The largest single frame accepted on the mux.
    ///
    /// Matches the relay's frame cap so a session that works directly also
    /// works through the relay.
    static let maximumMessageSize = 32 * 1024 * 1024

    private func startReceiveLoop(on socket: URLSessionWebSocketTask) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self else { return }
                    switch message {
                    case .data(let data):
                        await self.handle(data)
                    case .string(let text):
                        await self.handle(Data(text.utf8))
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self else { return }
                    if await self.isShutDown { return }
                    await self.reset(reason: "mux socket closed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    private func startHeartbeat(on socket: URLSessionWebSocketTask) {
        heartbeatLoop?.cancel()
        heartbeatLoop = Task { [weak self] in
            guard let interval = self?.heartbeatInterval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                socket.sendPing { _ in }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let frame = try? JSONDecoder().decode(ServerFrame.self, from: data) else { return }
        guard let continuation = streams[frame.streamId] else { return }

        switch frame.type {
        case "item":
            continuation.yield(frame.value ?? .null)
        case "end":
            streams.removeValue(forKey: frame.streamId)
            continuation.finish()
        case "error":
            streams.removeValue(forKey: frame.streamId)
            continuation.finish(
                throwing: DSHTransportError.streamFailed(
                    frame.error ?? DSHRPCFailure(code: "stream/failed", message: "stream failed")
                )
            )
        default:
            break
        }
    }

    private func fail(streamId: String, error: any Error) {
        guard let continuation = streams.removeValue(forKey: streamId) else { return }
        continuation.finish(throwing: error)
    }
}

/// Encodes a pre-encoded JSON object verbatim.
///
/// Stream arguments are already `Encodable` at the call site; wrapping the
/// encoded form avoids decoding and re-encoding on every stream open.
private struct RawJSONArgs: Encodable, Sendable {
    let data: Data

    func encode(to encoder: any Encoder) throws {
        // Re-enter the encoder through a JSON value so the encoded bytes are
        // spliced in structurally rather than emitted as a base64 string.
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        try value.encode(to: encoder)
    }
}
