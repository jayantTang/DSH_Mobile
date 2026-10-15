#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// A throwaway HTTP/1.1 server on loopback, for tests that must drive a **real**
/// `URLSession` because the code under test builds its own session.
///
/// Why this exists instead of a fake transport: `RelayFeedbackClient` takes an
/// optional `URLSession`, but `FeedbackCenter` does not pass one — it constructs
/// the client from a relay URL alone and lets `RelayFeedbackClient` create an
/// ephemeral session internally. Nothing short of an HTTP address reaches that
/// code:
///
/// * `URLProtocol.registerClass` does **not** apply to a session built from a
///   fresh `URLSessionConfiguration.ephemeral` (measured: the request still went
///   to the real network), so the protocol-class trick cannot see it;
/// * cleartext `http://127.0.0.1:<port>` does work from a test process, so the
///   stub listens on an ephemeral loopback port and the case points the endpoint
///   provider at it.
///
/// Answers are queued **per path** and replayed in order; every request is
/// recorded (method, path, headers, body) so a case can assert what went out —
/// which is what makes "the second call inside the window sent nothing"
/// observable.
///
/// Two knobs keep it deterministic:
///
/// * `stop()` closes the listening socket and waits for the accept loop to exit,
///   so later requests fail with a connection error. That is the offline path;
///   it never leaves a connection hanging in the backlog.
/// * with no queued answer for a path the stub replies `404` with the relay's
///   own envelope, so a case that forgets to stub reads as a failure rather than
///   as a timeout.
///
/// Test-only: no product target depends on `DSHTestingSupport`.
public final class LoopbackHTTPStub: @unchecked Sendable {

    /// One canned HTTP answer.
    public struct Answer: Sendable, Equatable {
        public let status: Int
        public let body: String

        public init(status: Int = 200, body: String) {
            self.status = status
            self.body = body
        }

        /// A `200` answer whose body is the given JSON text.
        public static func json(_ raw: String, status: Int = 200) -> Answer {
            Answer(status: status, body: raw)
        }
    }

    /// One request the stub received.
    public struct Recorded: Sendable {
        public let method: String
        /// Path only, query string stripped (the feedback endpoints never send one).
        public let path: String
        /// Header names lowercased.
        public let headers: [String: String]
        public let body: Data

        public var bodyText: String { String(decoding: body, as: UTF8.self) }

        public var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    public enum StubError: Error, CustomStringConvertible {
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
        case port

        public var description: String {
            switch self {
            case .socket(let code): return "loopback stub: socket() failed (errno \(code))"
            case .bind(let code): return "loopback stub: bind() failed (errno \(code))"
            case .listen(let code): return "loopback stub: listen() failed (errno \(code))"
            case .port: return "loopback stub: could not read the bound port"
            }
        }
    }

    /// `http://127.0.0.1:<port>` — the origin the code under test should be pointed at.
    public let baseURL: URL
    /// The ephemeral port the kernel handed out.
    public let port: UInt16

    private let listenFD: Int32
    private let lock = NSLock()
    private var queued: [String: [Answer]] = [:]
    private var fallback: [Answer] = []
    private var log: [Recorded] = []
    private var stopped = false
    private let exitSignal = DispatchSemaphore(value: 0)

    public init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StubError.socket(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw StubError.bind(errno)
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw StubError.listen(errno)
        }

        // A receive timeout on the *listening* socket is what lets `stop()` end
        // the accept loop on Darwin, where closing the fd does not always wake a
        // blocked accept().
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw StubError.port
        }

        port = UInt16(bigEndian: actual.sin_port)
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        listenFD = fd

        let thread = Thread { [self] in acceptLoop() }
        thread.name = "LoopbackHTTPStub"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    deinit { stop() }

    // MARK: - Answers

    /// Replaces the answer queue for one path. The last answer repeats once the
    /// queue has been consumed, so a case that refreshes twice does not have to
    /// queue the same answer twice.
    public func on(_ path: String, answer: Answer) {
        lock.lock()
        defer { lock.unlock() }
        queued[path] = [answer]
    }

    /// Queues answers for one path, replayed in order.
    public func enqueue(_ answers: [Answer], for path: String) {
        lock.lock()
        defer { lock.unlock() }
        queued[path] = answers
    }

    /// Answer used for any path without its own queue.
    public func answerEverything(with answer: Answer) {
        lock.lock()
        defer { lock.unlock() }
        fallback = [answer]
    }

    // MARK: - Requests

    /// Every request the stub received, in arrival order.
    public var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    /// Requests that hit one path.
    public func requests(_ path: String) -> [Recorded] {
        requests.filter { $0.path == path }
    }

    /// How many requests hit one path — the number the throttle cases assert on.
    public func count(_ path: String) -> Int {
        requests(path).count
    }

    // MARK: - Lifecycle

    /// Closes the listener and waits for the accept loop to exit, so a request
    /// made afterwards fails to connect instead of sitting in the backlog.
    /// Idempotent; also called from `deinit`.
    public func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        close(listenFD)
        _ = exitSignal.wait(timeout: .now() + 2)
    }

    // MARK: - Server

    private func acceptLoop() {
        while true {
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { break }

            var peer = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &peer, &length)
            if client < 0 {
                lock.lock()
                let stopping = stopped
                lock.unlock()
                if stopping { break }
                continue
            }
            let thread = Thread { [self] in serve(client) }
            thread.stackSize = 512 * 1024
            thread.start()
        }
        exitSignal.signal()
    }

    private func serve(_ fd: Int32) {
        defer {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let head = readHead(fd) else { return }
        guard let split = head.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headerData = head.subdata(in: head.startIndex ..< split.upperBound)
        var body = Data(head[split.upperBound...])

        let lines = String(decoding: headerData, as: UTF8.self)
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
        guard let requestLine = lines.first else { return }
        let parts = requestLine.components(separatedBy: " ")
        let method = parts.first ?? "GET"
        let target = parts.count > 1 ? parts[1] : "/"
        let path = target.components(separatedBy: "?").first ?? target

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex ..< colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if headers["expect"]?.lowercased().contains("100-continue") == true {
            write(fd, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }

        let wanted = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < wanted {
            guard let chunk = readChunk(fd), !chunk.isEmpty else { break }
            body.append(chunk)
        }

        let recorded = Recorded(method: method, path: path, headers: headers, body: body)
        lock.lock()
        log.append(recorded)
        let answer = take(headers: headers, path: path)
        lock.unlock()

        send(fd, answer)
    }

    /// Pops the next answer for this request. Must be called with `lock` held.
    private func take(headers: [String: String], path: String) -> Answer {
        if var queue = queued[path], !queue.isEmpty {
            let answer = queue.removeFirst()
            // Keep the last one so repeat calls (a refresh that runs twice) do
            // not fall through to the 404 envelope.
            queued[path] = queue.isEmpty ? [answer] : queue
            return answer
        }
        if let answer = fallback.first { return answer }
        return .json(#"{"ok":false,"error":{"code":"feedback/not-found","message":"loopback stub: no answer for \#(path)"}}"#,
                     status: 404)
    }

    private func readHead(_ fd: Int32) -> Data? {
        var buffer = Data()
        let marker = Data("\r\n\r\n".utf8)
        while buffer.count < 64 * 1024 {
            guard let chunk = readChunk(fd), !chunk.isEmpty else { return buffer.isEmpty ? nil : buffer }
            buffer.append(chunk)
            if buffer.range(of: marker) != nil { return buffer }
        }
        return buffer
    }

    private func readChunk(_ fd: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        let read = recv(fd, &bytes, bytes.count, 0)
        guard read > 0 else { return nil }
        return Data(bytes[0 ..< read])
    }

    private func send(_ fd: Int32, _ answer: Answer) {
        let payload = Data(answer.body.utf8)
        let reason = answer.status == 200 ? "OK" : "Error"
        var head = Data("HTTP/1.1 \(answer.status) \(reason)\r\n".utf8)
        head.append(Data("Content-Type: application/json\r\n".utf8))
        head.append(Data("Content-Length: \(payload.count)\r\n".utf8))
        head.append(Data("Connection: close\r\n\r\n".utf8))
        write(fd, head)
        write(fd, payload)
    }

    private func write(_ fd: Int32, _ data: Data) {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let sent = bytes.withUnsafeBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.send(fd, base + offset, bytes.count - offset, 0)
            }
            guard sent > 0 else { return }
            offset += sent
        }
    }
}
