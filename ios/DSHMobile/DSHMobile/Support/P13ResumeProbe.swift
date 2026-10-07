#if DEBUG
import CryptoKit
import Foundation
import RelayKit
import UIKit

/// P-13 步骤 0 的探针：**iOS 的网络层认不认中转能给的续传响应**。
///
/// 为什么必须实验而不是推理：`arch-final-guide-v3.md` §4.3 的 plan A 全部建立在
/// "系统的 resume data 能在我们的中转上续传"这个前提上，而中转不是静态文件服务器 ——
/// 它从连接器**流式**转发，拿不到文件总长，只能回
/// `Content-Range: bytes N-*/*`（总长未知）。CFNetwork 接不接受这种响应、
/// 接受之后第二次请求到底发不发 `Range`、发的是什么，只有实测能回答。
/// 三条判据（v3 §4.2）：
///
///   ① 第二次请求带 `Range: bytes=N-`
///   ② relay/连接器侧第二次过网字节 ≈ 总长 − N
///   ③ 最终 sha256 == 源
///
/// 这一版探针回答的是**第 ① 条的 iOS 侧**与"系统到底愿不愿意续"：
/// 它把一个真实的中转下载跑起来、在收到若干字节后 `cancel(byProducingResumeData:)`，
/// 报告有没有拿到 resume data、多大；然后立刻用 `downloadTask(withResumeData:)`
/// 续，把第二次请求实际发出的头、以及最终文件大小与 sha256 记进 `probe.log`。
///
/// 只在带 `-DSHP13ResumeProbe <scopeId>|<path>|<interruptBytes>` 启动时工作。
/// DEBUG-only；Release 包里这段代码不存在，也不会发任何请求。
@MainActor
enum P13ResumeProbe {

    /// `-DSHP13ResumeProbe <scopeId>|<workspacePath>|<bytes>`
    ///
    /// A fourth field is optional and is the **measurement control**: an absolute
    /// URL to fetch instead of the relay. It exists so the experiment can
    /// separate "iOS will not produce resume data" from "iOS will not produce it
    /// *for this relay's response shape*" — the second is a fixable relay
    /// problem, the first is not. See `probes/p13-static-server.py`.
    private static var request: (
        scopeId: String, path: String, interruptAfter: Int,
        directURL: URL?, useForegroundSession: Bool
    )? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHP13ResumeProbe"),
              index + 1 < arguments.count
        else { return nil }
        let parts = arguments[index + 1].split(separator: "|", maxSplits: 4).map(String.init)
        guard parts.count >= 3, let bytes = Int(parts[2]) else { return nil }
        let direct = parts.count > 3 && parts[3] != "-" ? URL(string: parts[3]) : nil
        let foreground = parts.count > 4 && parts[4] == "fg"
        return (parts[0], parts[1], bytes, direct, foreground)
    }

    static let isOn = request != nil

    /// Whether this run measures a **direct URL** rather than the relay.
    ///
    /// The control exists to answer a question about iOS's network layer, not
    /// about our connection: gating it behind a live relay session would mean the
    /// measurement could not be taken without one, and any relay state would leak
    /// into the reading. A direct run therefore needs no connection at all.
    static var isControlRun: Bool { request?.directURL != nil }

    private static var lines: [String] = []

    static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("probe.log")
    }

    static func note(_ kind: String, _ fields: [String: String] = [:]) {
        guard isOn else { return }
        var text = kind
        for key in fields.keys.sorted() { text += " \(key)=\(fields[key] ?? "")" }
        lines.append(text)
        flush()
    }

    private static func flush() {
        guard !lines.isEmpty else { return }
        let body = lines.joined(separator: "\n") + "\n"
        lines.removeAll(keepingCapacity: true)
        guard let data = body.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Whether this launch has already started its one run.
    ///
    /// The probe is driven from a `.task(id:)` keyed on the connection state, so
    /// every reconnect starts it again — and a run that interrupts a 40 MB
    /// transfer is long enough to span several. The second start re-downloaded
    /// from zero while the first was still unwinding, and the log filled with
    /// interleaved `attempt1` lines and **no** `attempt2`: the resume it was
    /// supposed to demonstrate never got to run.
    nonisolated(unsafe) private static var started = false

    /// Runs the whole experiment once, on launch.
    static func run(relayURL: URL, deviceToken: String) {
        guard let request else { return }
        guard !started else { return }
        started = true
        note("p13.start", [
            "scopeId": request.scopeId,
            "path": request.path,
            "interruptAfter": String(request.interruptAfter),
            "relay": relayURL.absoluteString,
        ])
        if request.scopeId.hasPrefix(Self.productMode) {
            // P-13c: drive the **product** `download` and its resume store, rather
            // than a probe-owned session. The step-0 probe answers "does iOS give
            // resume data at all"; this answers "does our own path keep it and use
            // it", which is the part the app now depends on.
            guard let scope = Self.productScope(request.scopeId) else {
                note("p13c.error", ["why": "expected product@<sessionId>"])
                return
            }
            // **Detached on purpose.** `run` is called from a SwiftUI `.task`
            // keyed on the connection state, so an inherited `Task {}` is
            // cancelled the moment the app reconnects — and the run is long enough
            // (an interruption plus a resume of tens of MB) to span a reconnect.
            // When that happened the log showed `attempt1.end storedBlob=9955` and
            // then simply stopped: the blob was on disk, the second attempt never
            // ran, and the evidence for "it resumes" was lost to an unrelated
            // teardown. Nothing here touches UI state, so detaching is safe.
            Task.detached { await self.driveProduct(relayURL: relayURL, deviceToken: deviceToken,
                                                    scopeId: scope, request: request) }
            return
        }
        Task.detached { await self.drive(relayURL: relayURL, deviceToken: deviceToken,
                                         request: request) }
    }

    /// The marker that selects the product-path run.
    ///
    /// The first field carries `<marker>@<real session id>`: the marker picks the
    /// run, and the session id is what the connector needs as a workspace scope.
    /// Passing the marker as the scope (the first attempt) made the Host answer
    /// `gateway/lookup-not-found` — the scope is a session identity, not a name
    /// this probe gets to choose.
    static let productMode = "product"

    /// The real workspace scope for a product run.
    static func productScope(_ raw: String) -> String? {
        let parts = raw.split(separator: "@", maxSplits: 1).map(String.init)
        return parts.count == 2 && !parts[1].isEmpty ? parts[1] : nil
    }

    /// Interrupts a real `RelayFileTransfer.download`, then resumes it.
    ///
    /// Both halves go through the shipping code: the interruption is a task
    /// cancellation (which is what the cancel button does), and the second
    /// attempt is a plain `download` call that finds the stored blob and replays
    /// it. Nothing here reaches into the store directly — if the store were not
    /// wired into `download`, this would download from zero and the byte count
    /// would show it.
    private static func driveProduct(
        relayURL: URL, deviceToken: String, scopeId: String, request: (
            scopeId: String, path: String, interruptAfter: Int,
            directURL: URL?, useForegroundSession: Bool
        )
    ) async {
        // **产品那一个 delegate**，不是探针自己的观测 delegate：`download` 的答案
        // 走 `RelayDownloadSink`（按 task 登记等待者），而 `P13ResumeObserver.Delegate`
        // 不认识那套登记 —— 用它会永远等不到结果。观测第二次请求的 `Range` 由产品
        // 自己的会话日志负责，这里要验的是"续传有没有发生"。
        let transfer = RelayFileTransfer(relayURL: relayURL, deviceToken: deviceToken,
                                         session: P13ResumeProbeSession.makeProduct())
        let version = "probe-version-1"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p13c-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("attempt.bin")

        // ── 第一次：跑到目标字节数就取消（= 用户点暂停 / 系统挂起） ──
        //
        // 计时器与下载**并发**跑：`download` 的 `onProgress` 只在结束时回调一次
        // （F-3，本批未修），所以"已经收了多少"不能靠它来判断。这里按文件大小
        // 与一个粗略的速率算取消时刻 —— 探针要的是"传了一半"，不是精确字节数。
        note("p13c.attempt1.start", ["after": String(request.interruptAfter)])
        let total = (try? FileManager.default.attributesOfItem(atPath: request.path))?[.size] as? Int
        let first = Task {
            try await transfer.download(
                scopeId: scopeId, path: request.path, to: destination,
                version: version, bid: UUID().uuidString
            ) { _ in }
        }
        // 目标：**传了一半左右**再取消。取消已经完成的任务什么也证明不了
        // （resume data 只对"还没传完"的传输有意义），所以这个时刻必须按文件
        // 实际大小算，并且留出足够的余量 —— 中转从连接器流式转发，比本机直连慢。
        //
        // **不要用「文件大小 ÷ 估计吞吐」来算这个时刻。** 那个估算猜错过两次：
        // 一次是估慢了（40 MB 传完还没取消，`cancelled=none`），一次是估快了
        // （0.3 s 就取消，一个字节都没走，系统当然没有 resume data 可给，
        // `storedBlob=-1` —— 那个读数很容易被误读成"产品把 resume data 丢了"）。
        //
        // 后台会话把在途字节写在 `Caches/com.apple.nsurlsessiond/Downloads/<bundle>/`
        // 下的 `CFNetworkDownload_*.tmp`，所以进度是**可读的**：等这次自己的那个
        // 文件（按修改时间取最新的，旧轮的残留不会混进来）长到目标字节数再取消。
        // 上限存在是为了让"传不动"表现成一条读数，而不是把整轮时间吃掉。
        let inFlightDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.apple.nsurlsessiond/Downloads", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.jayanttang.dsh",
                                    isDirectory: true)
        var waited = 0
        while waited < 60_000 {
            if Self.newestInFlightBytes(in: inFlightDir) >= request.interruptAfter { break }
            try? await Task.sleep(for: .milliseconds(50))
            waited += 50
        }
        note("p13c.attempt1.timer", [
            "targetBytes": String(request.interruptAfter),
            "total": String(total ?? -1),
            "waitedMs": String(waited),
            "inFlightBytes": String(Self.newestInFlightBytes(in: inFlightDir)),
        ])
        first.cancel()
        let outcome = await first.result
        note("p13c.attempt1.end", [
            "cancelled": String(describing: errorKind(outcome)),
            "storedBlob": String(RelayResumeStore.load(
                scopeId: scopeId, path: request.path, version: version)?.count ?? -1),
        ])

        // ── 第二次：同一个 version 再下一次，必须续 ──
        note("p13c.attempt2.begin", [
            "blob": String(RelayResumeStore.load(
                scopeId: scopeId, path: request.path, version: version)?.count ?? -1),
        ])
        let resumed: RelayFileTransfer.Fetched?
        do {
            // Bounded: this is the step that stalled, and a probe that hangs
            // reports nothing. A timeout here is a reading ("attempt 2 never
            // finished"), which is exactly what the acceptance needs to see.
            resumed = try await Self.withTimeout(seconds: 90) {
                try await transfer.download(
                scopeId: scopeId, path: request.path, to: destination,
                version: version, expectedBytes: total, bid: UUID().uuidString
                ) { received in Self.receivedBytes = received }
            }
        } catch {
            // The failure's text is the evidence: a relay JSON error
            // (`DSHRPCFailure`) means the request never reached the connector,
            // while a transport error means the bytes did not flow.
            note("p13c.attempt2.error", ["error": "\(error)"])
            note("p13c.done", [:])
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int
        note("p13c.attempt2.done", [
            "bytes": String(size ?? -1),
            "sha256": sha256(of: destination) ?? "(unreadable)",
        ])
        _ = resumed
        note("p13c.done", [:])
    }


    /// A probe step that did not finish in time.
    ///
    /// Its own type rather than a transport error: "the probe's clock ran out" is
    /// not "the transfer failed", and conflating them would make a hang read as a
    /// network result.
    struct ProbeTimeout: Error, CustomStringConvertible {
        let seconds: Double
        var description: String { "probe step timed out after \(Int(seconds))s" }
    }

    /// Runs `work`, failing with a timeout instead of hanging.
    ///
    /// The probe's worst failure mode is silence: a step that never returns
    /// writes no line, so the log simply stops and the run looks like "no
    /// evidence was collected" rather than "this step hung". A cap turns it into
    /// a reading.
    private static func withTimeout<T: Sendable>(
        seconds: Double, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ProbeTimeout(seconds: seconds)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private static func errorKind<T>(_ result: Result<T, any Error>) -> String {
        switch result {
        case .success: return "none"
        case .failure(let error): return "\(type(of: error))"
        }
    }

    /// The size of the most recently written in-flight body in `directory`.
    ///
    /// A background session writes a running download's partial body to
    /// `CFNetworkDownload_*.tmp` there, so the newest of those is **this**
    /// attempt's file — earlier runs leave theirs behind, and taking the largest
    /// or the sum would let a stale 40 MB leftover satisfy the wait instantly.
    private static func newestInFlightBytes(in directory: URL) -> Int {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return 0 }
        let newest = items
            .filter { $0.lastPathComponent.hasPrefix("CFNetworkDownload_") }
            .max { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return leftDate < rightDate
            }
        guard let newest else { return 0 }
        return (try? newest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// The last byte count a product download reported, for the cancel timing.
    nonisolated(unsafe) static var receivedBytes = 0

    private static func drive(
        relayURL: URL,
        deviceToken: String,
        request: (scopeId: String, path: String, interruptAfter: Int, directURL: URL?, useForegroundSession: Bool)
    ) async {
        let transfer = RelayFileTransfer(relayURL: relayURL, deviceToken: deviceToken)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p13-probe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("attempt1.bin")

        // ── 第一次：跑起来，收到足够字节后按「暂停」的方式取消，拿 resume data ──
        P13ResumeObserver.reset()
        // 探针用**自己的**会话与 delegate：它要观测"这次请求真的发了什么"，
        // 复用产品的 waiter 机制会把观测绑在产品实现上，答不出"iOS 认不认 206"。
        //
        // 第五个字段是 `fg` 时换用普通（前台）会话：那是"到底是仿真器不行，
        // 还是后台会话不行"的对照组。
        let session = request.useForegroundSession
            ? P13ResumeProbeSession.makeControl()
            : P13ResumeProbeSession.make()
        note("p13.session", ["kind": request.useForegroundSession ? "default" : "background"])
        let request1: URLRequest?
        if let direct = request.directURL {
            // 对照组：一个能给完整 `Content-Length`/`Content-Range` 的静态服务器。
            request1 = URLRequest(url: direct)
        } else {
            request1 = transfer.downloadRequest(
                scopeId: request.scopeId, path: request.path, offset: 0, bid: UUID().uuidString
            )
        }
        guard let request1 else { note("p13.error", ["why": "bad relay url"]); return }
        note("p13.attempt1.request", ["url": request1.url?.absoluteString ?? "?"])
        let task = session.downloadTask(with: request1)
        P13ResumeObserver.watch(task)
        task.resume()

        // 等它真的过了 line，再取消 —— 太早取消拿不到可续的 resume data。
        var waited = 0
        while P13ResumeObserver.bytesWritten < request.interruptAfter, waited < 60_000 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 100
        }
        note("p13.attempt1.progress", [
            "bytesWritten": String(P13ResumeObserver.bytesWritten),
            "waitedMs": String(waited),
        ])

        // `cancel(byProducingResumeData:)` 是"暂停"的语义；普通 `cancel()` 只丢任务。
        let resumeData: Data? = await withCheckedContinuation { continuation in
            task.cancel(byProducingResumeData: { data in continuation.resume(returning: data) })
        }
        note("p13.resumeData", [
            "present": resumeData == nil ? "no" : "yes",
            "bytes": String(resumeData?.count ?? 0),
        ])
        // 对照组：`didCompleteWithError` 的 userInfo 是 resume data 的**另一个**来源。
        // 两条都空才是真的拿不到；只查一条会把"回调顺序不同"误判成"系统不支持"。
        note("p13.cancelError", [
            "error": P13ResumeObserver.lastError ?? "(none)",
            "userInfoHasResumeData": P13ResumeObserver.lastErrorHadResumeData ? "yes" : "no",
        ])
        _ = destination

        guard let resumeData else {
            note("p13.verdict", ["result": "NO_RESUME_DATA"])
            note("p13.done", [:])
            return
        }

        // ── 第二次：用 resume data 续，看它实际发出什么请求、最终多大 ──
        P13ResumeObserver.reset()
        let second = session.downloadTask(withResumeData: resumeData)
        P13ResumeObserver.watch(second)
        let finalURL = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            P13ResumeObserver.onFinish = { url in continuation.resume(returning: url) }
            second.resume()
        }
        note("p13.attempt2.headers", [
            "range": P13ResumeObserver.lastRangeHeader ?? "(none)",
            "url": P13ResumeObserver.lastURL ?? "(none)",
        ])
        note("p13.attempt2.progress", [
            "bytesWritten": String(P13ResumeObserver.bytesWritten),
            "totalBytesWritten": String(P13ResumeObserver.totalBytesWritten),
        ])
        guard let finalURL else {
            note("p13.verdict", ["result": "SECOND_ATTEMPT_FAILED", "error": P13ResumeObserver.lastError ?? "?"])
            note("p13.done", [:])
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path))?[.size] as? Int
        let digest = sha256(of: finalURL)
        note("p13.attempt2.file", [
            "bytes": String(size ?? -1),
            "sha256": digest ?? "(unreadable)",
            "path": finalURL.lastPathComponent,
        ])
        note("p13.verdict", [
            "result": "SECOND_ATTEMPT_DONE",
            "rangeSent": P13ResumeObserver.lastRangeHeader == nil ? "no" : "yes",
        ])
        note("p13.done", [:])
    }

    private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 探针自己的后台会话（P-13 步骤 0 专用）。
///
/// 必须是**后台**会话：plan A 的全部意义在于"系统在 App 被挂起后还能续"，
/// 用一个前台会话测出来的 resume data 行为不能代表产品那条路。
/// identifier 与产品那个**不同**，免得探针的任务混进产品的 delegate 通路。
@MainActor
enum P13ResumeProbeSession {
    static let identifier = "com.jayanttang.dsh.p13-resume-probe"
    /// The control session's identifier — a **foreground** configuration.
    static let controlIdentifier = "com.jayanttang.dsh.p13-resume-control"

    private static var held: URLSession?
    private static var control: URLSession?
    private static var product: URLSession?
    private static let delegate = P13ResumeObserver.Delegate()

    static func make() -> URLSession {
        if let held { return held }
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = false
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        held = session
        return session
    }

    /// The probe's background session, built with the **product** delegate.
    ///
    /// `make()` uses the observer so the step-0 experiment can see what the
    /// request actually carried. The product-path run (`scopeId=product`) needs
    /// the opposite: its answers have to reach `RelayDownloadSink`, and only
    /// `RelayFileTransfer.sessionDelegate` does that.
    static func makeProduct() -> URLSession {
        if let product { return product }
        let configuration = URLSessionConfiguration.background(
            withIdentifier: identifier + ".product"
        )
        configuration.sessionSendsLaunchEvents = false
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration,
                                 delegate: RelayFileTransfer.sessionDelegate,
                                 delegateQueue: nil)
        product = session
        return session
    }

    /// A plain (`default`) session, for the "is it the simulator or is it
    /// background sessions?" question.
    ///
    /// If resume data appears here but not on the background one, the finding is
    /// about background semantics (and a device may still differ). If it appears
    /// nowhere, the simulator cannot answer this experiment at all — which is
    /// itself the answer the guide's step 0 needs, because it decides whether
    /// the plan can be chosen at all in this environment.
    static func makeControl() -> URLSession {
        if let control { return control }
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        control = session
        return session
    }
}
#endif
