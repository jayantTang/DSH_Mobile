// DSH.app — a minimal, dependency-free macOS shell for the DSH web GUI.
//
// Design contract (keep this file boring so it survives DSH upgrades):
//   * The one and only coupling to DSH is: run `dsh web --no-open` and read the
//     URL it prints on stdout/stderr. Everything else is optional.
//   * If a healthy instance is already running (endpoint.json written by the
//     dsh-plugin-desktop-shell plugin, pid alive), attach to it instead of
//     spawning a second server.
//   * All knobs live in ~/.dsh/desktop-shell/app.json so a future repair never
//     needs a recompile.
//
// Build: scripts/build-app.sh   (swiftc, no package manager)

import AppKit
import WebKit
import Foundation
import Darwin
import CoreGraphics

// MARK: - Paths

enum ShellPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let dir = home.appendingPathComponent(".dsh/desktop-shell", isDirectory: true)
    static let config = dir.appendingPathComponent("app.json")
    static let endpoint = dir.appendingPathComponent("endpoint.json")
    static let lease = dir.appendingPathComponent("app.pid")
    static let log = dir.appendingPathComponent("dsh-shell.log")

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func appendLog(_ text: String) {
        ensureDir()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(text)\n"
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: log)
        }
    }

    /// Whether something is listening on 127.0.0.1:<port>.
    ///
    /// A pid that is alive is not the same thing as a server that answers: the
    /// socket is the truth. Non-blocking connect + poll keeps this cheap enough
    /// to run from a watchdog every few seconds.
    static func isListening(port: Int) -> Bool {
        guard port > 0, port < 65_536 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&event, 1, 2_000) > 0 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }
}

// MARK: - Config (user-editable, no recompile needed)

struct ShellConfig {
    var appTitle = "DSH"
    var dshBin = "dsh"
    // A random free port by default so the app never collides with a DSH the
    // user already started in a terminal.
    var extraArgs: [String] = ["--port", "0"]
    var initialURL: String? = nil
    var attachToRunning = true
    var checkUpdates = true
    // Reminder policy: follow only this dist-tag (default `latest`).
    var tag = "latest"
    // When false (default), prerelease channels (next/alpha) never raise a nudge.
    var showPrereleases = false
    // Deployment-level permission override for sessions this app launches.
    // "" disables the override and leaves DSH's own default in charge.
    var permissionMode = "danger-full-access"
    // Legacy alias for `tag`; still read so older app.json files keep working.
    var channel = "latest"
    var npmBin = "npm"
    var registry = "https://registry.npmjs.org/@deepseek-ai/dsh"
    var startupTimeoutSeconds = 60.0
    // Keep the (expensive to boot, ~3 s) DSH server around after quitting so the
    // next launch attaches instantly. 0 = stop on quit; -1 = keep until stopped
    // by hand; N > 0 = keep for N minutes, then a watchdog reaps it.
    var lingerMinutes = 30

    static func load() -> ShellConfig {
        var cfg = ShellConfig()
        guard let data = try? Data(contentsOf: ShellPaths.config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return cfg
        }
        if let v = obj["appTitle"] as? String { cfg.appTitle = v }
        if let v = obj["dshBin"] as? String { cfg.dshBin = v }
        if let v = obj["extraArgs"] as? [String] { cfg.extraArgs = v }
        if let v = obj["initialURL"] as? String, !v.isEmpty { cfg.initialURL = v }
        if let v = obj["attachToRunning"] as? Bool { cfg.attachToRunning = v }
        if let v = obj["checkUpdates"] as? Bool { cfg.checkUpdates = v }
        if let v = obj["tag"] as? String { cfg.tag = v }
        if let v = obj["showPrereleases"] as? Bool { cfg.showPrereleases = v }
        if let v = obj["permissionMode"] as? String { cfg.permissionMode = v }
        if let v = obj["channel"] as? String { cfg.channel = v; if obj["tag"] == nil { cfg.tag = v } }
        if let v = obj["npmBin"] as? String { cfg.npmBin = v }
        if let v = obj["registry"] as? String { cfg.registry = v }
        if let v = obj["startupTimeoutSeconds"] as? Double { cfg.startupTimeoutSeconds = v }
        if let v = obj["lingerMinutes"] as? Int { cfg.lingerMinutes = v }
        return cfg
    }
}

// MARK: - Endpoint handoff written by the DSH plugin

struct EndpointInfo {
    var url: String?
    var port: Int?
    var pid: Int32?
    var version: String?
    /// True when the running server was started by DSH.app itself (the plugin
    /// records the DSH_DESKTOP_SHELL env it was launched with). A server the
    /// user started in a terminal reports false/absent and is never killed by us.
    var desktopShell: Bool?

    static func load() -> EndpointInfo? {
        guard let data = try? Data(contentsOf: ShellPaths.endpoint),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var info = EndpointInfo()
        info.url = obj["url"] as? String
        info.port = obj["port"] as? Int
        info.pid = (obj["pid"] as? NSNumber)?.int32Value
        info.version = obj["version"] as? String
        info.desktopShell = obj["desktopShell"] as? Bool
        return info
    }

    var isAlive: Bool {
        guard let pid = pid, pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// Alive *and* still holding a socket. This is what the attach path needs:
    /// a stale record can name a dead pid, or a live pid whose server is gone.
    var isServing: Bool {
        guard isAlive, let port, port > 0 else { return false }
        return ShellPaths.isListening(port: port)
    }
}

// MARK: - Version helpers (semver precedence, tolerant of rc/alpha tags)

enum Version {
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let l = parse(lhs), r = parse(rhs)
        for i in 0..<3 {
            if l.core[i] != r.core[i] { return l.core[i] < r.core[i] ? -1 : 1 }
        }
        // A release outranks any prerelease of the same core version.
        if l.pre.isEmpty && r.pre.isEmpty { return 0 }
        if l.pre.isEmpty { return 1 }
        if r.pre.isEmpty { return -1 }
        for i in 0..<max(l.pre.count, r.pre.count) {
            if i >= l.pre.count { return -1 }
            if i >= r.pre.count { return 1 }
            let a = l.pre[i], b = r.pre[i]
            let an = Int(a), bn = Int(b)
            switch (an, bn) {
            case let (x?, y?): if x != y { return x < y ? -1 : 1 }
            case (_?, nil): return -1          // numeric < alphanumeric
            case (nil, _?): return 1
            default: if a != b { return a < b ? -1 : 1 }
            }
        }
        return 0
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) > 0
    }

    private static func parse(_ raw: String) -> (core: [Int], pre: [String]) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") { s.removeFirst() }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = String(s[s.index(after: dash)...]).split(separator: ".").map(String.init)
            s = String(s[..<dash])
        }
        // Drop build metadata.
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        let core = s.split(separator: ".").prefix(3).map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        return (Array(core) + [0, 0, 0], pre)
    }
}

// MARK: - Command runner

enum Shell {
    /// Runs a login shell so the app inherits the user's PATH (brew, nvm, ...).
    static func run(_ command: String,
                    completion: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"].map { "\($0):" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var output = Data()
            do {
                try process.run()
            } catch {
                completion(127, "failed to launch /bin/zsh: \(error.localizedDescription)")
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output.append(data)
            process.waitUntilExit()
            completion(process.terminationStatus, String(decoding: output, as: UTF8.self))
        }
    }
}

// MARK: - DSH server process

final class DSHServer {
    private(set) var url: URL?
    private(set) var attached = false
    /// True when the attached server was started by this app (endpoint flag).
    private(set) var attachedOwned = false
    private(set) var spawnedPid: Int32?
    private(set) var attachedPid: Int32?
    private var process: Process?
    private var buffer = ""
    private var urlFound = false
    /// When we started looking for a server, so a slow boot is never mistaken
    /// for a dead one.
    private(set) var startedAt = Date()

    var onURL: ((URL) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    var onLog: ((String) -> Void)?

    private static let maxLogBytes = 64 * 1024

    /// The server this app may manage: either our own child, or a background
    /// server this app started on an earlier run. A terminal-launched server is
    /// deliberately excluded.
    var ownsServer: Bool { spawnedPid != nil || (attached && attachedOwned) }
    var serverPid: Int32? { spawnedPid ?? attachedPid }
    var port: Int? { url?.port }

    func start(config: ShellConfig) {
        startedAt = Date()
        if config.attachToRunning,
           let info = EndpointInfo.load(), info.isServing,
           let raw = info.url, let url = URL(string: raw) {
            attached = true
            attachedPid = info.pid
            attachedOwned = info.desktopShell == true
            self.url = url
            ShellPaths.appendLog("attached to running dsh (pid \(info.pid ?? -1), owned=\(attachedOwned)) at \(raw)")
            DispatchQueue.main.async { [weak self] in self?.onURL?(url) }
            return
        }
        if let initial = config.initialURL, let url = URL(string: initial) {
            self.url = url
            ShellPaths.appendLog("using configured initialURL \(initial)")
            DispatchQueue.main.async { [weak self] in self?.onURL?(url) }
            return
        }

        let extra = config.extraArgs.isEmpty ? "" : " " + config.extraArgs.joined(separator: " ")
        let command = "exec \(config.dshBin) web --no-open\(extra)"
        ShellPaths.appendLog("spawning: \(command)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { "\($0):" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["DSH_DESKTOP_SHELL"] = "1"
        env["DSH_DESKTOP_SHELL_CLIENT"] = "dsh.app"
        // Deployment override understood by dsh-base: drives both the composed
        // sandbox mode and the approval policy for sessions created later.
        // Empty string means "do not override"; the settings default applies.
        if !config.permissionMode.isEmpty {
            env["DSH_PERMISSION_MODE"] = config.permissionMode
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.ingest(text) }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                ShellPaths.appendLog("dsh exited with status \(proc.terminationStatus)")
                self.onExit?(proc.terminationStatus, self.buffer)
            }
        }
        do {
            try process.run()
        } catch {
            let message = "无法启动 dsh：\(error.localizedDescription)"
            ShellPaths.appendLog(message)
            DispatchQueue.main.async { [weak self] in self?.onExit?(127, message) }
            return
        }
        self.process = process
        self.spawnedPid = process.processIdentifier
    }

    private func ingest(_ text: String) {
        buffer += text
        if buffer.utf8.count > Self.maxLogBytes {
            buffer = String(buffer.suffix(Self.maxLogBytes / 2))
        }
        onLog?(text)
        guard !urlFound, let found = Self.extractURL(from: buffer) else { return }
        urlFound = true
        url = found
        ShellPaths.appendLog("discovered url \(found.absoluteString)")
        onURL?(found)
    }

    /// Tolerant URL extraction: prefer a token-carrying loopback URL, else the
    /// first loopback http URL in the captured output.
    static func extractURL(from text: String) -> URL? {
        let pattern = #"https?://[^\s"'<>\\)\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let r = Range(match.range, in: text) else { return nil }
            return String(text[r])
        }
        guard !matches.isEmpty else { return nil }
        let loopback = matches.filter { $0.contains("127.0.0.1") || $0.contains("localhost") || $0.contains("[::1]") }
        let pool = loopback.isEmpty ? matches : loopback
        if let withToken = pool.first(where: { $0.contains("token=") }) { return URL(string: withToken) }
        return URL(string: pool[0])
    }

    /// Stop the child process this app spawned, if any.
    func stopSpawned() {
        guard let process, process.isRunning else { return }
        ShellPaths.appendLog("terminating spawned dsh pid \(process.processIdentifier)")
        process.terminate()
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        self.process = nil
        self.spawnedPid = nil
        self.url = nil
    }

    /// Stop a background server this app started on an earlier run. Never
    /// touches a server the user launched in a terminal.
    func stopAttachedIfOwned() {
        guard attached, attachedOwned, let pid = attachedPid, pid > 0 else { return }
        ShellPaths.appendLog("stopping background dsh pid \(pid)")
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(4)
        while kill(pid, 0) == 0 && Date() < deadline {
            usleep(100_000)
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        attachedPid = nil
        // Leave no half-state behind: "attached but nothing running" is what
        // let a dead backend look owned for the rest of the session.
        attached = false
        attachedOwned = false
        url = nil
    }

    /// Can the backend this app is bound to still serve?
    ///
    /// The supervisor asks this every few seconds. A live pid with no socket
    /// (crashed worker, half-dead process) must read as unhealthy, because that
    /// is exactly the state that used to leave an open window with no server.
    func isHealthy() -> Bool {
        if let process {
            guard process.isRunning else { return false }
        } else if attached, let pid = attachedPid, pid > 0 {
            guard kill(pid, 0) == 0 else { return false }
        } else {
            return false
        }
        guard let port else { return false }
        return ShellPaths.isListening(port: port)
    }

    /// True while a freshly spawned child is inside its startup window and has
    /// not printed a URL yet — not a failure, just not ready.
    func isBooting(within seconds: Double) -> Bool {
        guard url == nil, let process, process.isRunning else { return false }
        return Date().timeIntervalSince(startedAt) < seconds
    }

    /// Stop everything this app owns (used by restart and after an upgrade).
    func stopAll() {
        stopSpawned()
        stopAttachedIfOwned()
    }

    /// Backwards-compatible alias.
    func stop() { stopAll() }
}

// MARK: - Update checking (independent of the DSH plugin on purpose)

final class UpdateChecker {
    struct Status {
        var installed: String?
        var latest: String?
        var tag: String?
        var channel: String
        var updateAvailable: Bool
    }

    static func installedVersion(config: ShellConfig, completion: @escaping (String?) -> Void) {
        Shell.run("\(config.npmBin) root -g 2>/dev/null") { code, out in
            let root = out.split(separator: "\n").map(String.init)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty })
            if code == 0, let root {
                let pkg = URL(fileURLWithPath: root).appendingPathComponent("@deepseek-ai/dsh/package.json")
                if let data = try? Data(contentsOf: pkg),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let version = obj["version"] as? String {
                    completion(version)
                    return
                }
            }
            Shell.run("\(config.dshBin) --version 2>/dev/null") { _, versionOut in
                let token = versionOut.split(whereSeparator: { $0 == " " || $0 == "\n" })
                    .map(String.init)
                    .first(where: { $0.first?.isNumber == true })
                completion(token)
            }
        }
    }

    static func check(config: ShellConfig, completion: @escaping (Status) -> Void) {
        installedVersion(config: config) { installed in
            var request = URLRequest(url: URL(string: config.registry)!)
            request.timeoutInterval = 20
            request.setValue("application/vnd.npm.install-v1+json, application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: request) { data, _, _ in
                var latest: String?
                var tags: [String: String] = [:]
                if let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let dist = obj["dist-tags"] as? [String: String] { tags = dist }
                    else if let dist = obj["dist-tags"] as? [String: Any] {
                        tags = dist.compactMapValues { $0 as? String }
                    }
                }
                // Reminder policy: only the followed tag (default `latest`) may
                // raise a nudge. Prerelease channels stay hidden unless
                // `showPrereleases` is explicitly enabled in app.json.
                let followedTag = config.tag.isEmpty ? "latest" : config.tag
                latest = tags[followedTag] ?? tags["latest"]
                var tag = followedTag
                if config.showPrereleases, let installed,
                   !(latest.map { Version.isNewer($0, than: installed) } ?? false) {
                    let newer = tags.filter { Version.isNewer($0.value, than: installed) }
                    if let best = newer.max(by: { Version.isNewer($1.value, than: $0.value) }) {
                        latest = best.value
                        tag = best.key
                    }
                }
                let available: Bool = {
                    guard let installed, let latest else { return false }
                    return Version.isNewer(latest, than: installed)
                }()
                let status = Status(installed: installed, latest: latest, tag: tag,
                                    channel: config.channel, updateAvailable: available)
                DispatchQueue.main.async { completion(status) }
            }.resume()
        }
    }

    static func upgrade(config: ShellConfig, to version: String, progress: @escaping (String) -> Void,
                        completion: @escaping (Bool, String) -> Void) {
        let target = version == "latest" ? "" : "@\(version)"
        let command = "\(config.npmBin) install -g @deepseek-ai/dsh\(target) 2>&1"
        progress("$ \(command)")
        Shell.run(command) { code, out in
            DispatchQueue.main.async { completion(code == 0, out) }
        }
    }
}

// MARK: - App delegate

// MARK: Screen recording permission

/// Screen Recording is a TCC grant owned by macOS: an app cannot grant it to
/// itself, and — the part that keeps biting — a grant only reaches a process
/// started *after* the grant was made. So this type reports and requests; the
/// user's one job is to allow it once and let the app restart.
///
/// The grant is keyed to the app's code identity. An ad-hoc signature has no
/// stable identity, so every rebuild of DSH.app invalidates the grant and
/// `screencapture` starts failing again. build-app.sh signs with a real
/// certificate precisely so this stays a one-time step.
enum ScreenRecording {
    /// Whether this app may capture the screen right now.
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Ask macOS to put DSH in the Screen Recording list. The return value is
    /// the state after the dialog, but a fresh yes still needs a relaunch to
    /// apply, so callers must not treat `true` as "good to go".
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Run one real capture, the same way the tools do, so the answer is about
    /// the permission rather than about our own check.
    static func probe() -> (ok: Bool, detail: String) {
        let path = NSTemporaryDirectory() + "dsh-screen-recording-probe.png"
        try? FileManager.default.removeItem(atPath: path)
        let process = Process()
        // Through a login shell, exactly like a tool call: the grant has to
        // hold for a grandchild of the app, not just for the app itself.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "/usr/sbin/screencapture -x \(shellQuoted(path))"]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return (false, "无法运行 screencapture：\(error.localizedDescription)")
        }
        process.waitUntilExit()
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? Int) ?? 0
        if process.terminationStatus == 0, size > 0 {
            try? FileManager.default.removeItem(atPath: path)
            return (true, "截图测试成功（\(size / 1024) KB）")
        }
        let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, detail.isEmpty ? "screencapture 退出码 \(process.terminationStatus)" : detail)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var server = DSHServer()
    private var config = ShellConfig.load()
    private var logText = ""
    private var progressWindow: NSWindow?
    private var progressText: NSTextView?
    private var didPromptThisLaunch = false
    private var retriedWithoutArgs = false
    /// One upgrade at a time: a double-click must not start two npm installs.
    private var upgradeInFlight = false
    private var supervisor: DispatchSourceTimer?
    private var restartAttempts = 0
    /// While set, no path may start another restart — one is already in flight.
    private var supervisorHoldUntil = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        ShellPaths.ensureDir()
        writeLease()
        ShellPaths.appendLog("---- DSH.app launch (config: \(ShellPaths.config.path)) ----")
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        startServer()
        startSupervisor()
        checkScreenRecordingAtLaunch()
    }

    // MARK: Screen recording

    /// Say it once per launch, and only when something is actually wrong:
    /// screenshots failing silently is the expensive outcome, not the dialog.
    private func checkScreenRecordingAtLaunch() {
        guard !ScreenRecording.isGranted else {
            // `CGPreflightScreenCaptureAccess` answers about the *grant*, not
            // about this process, and the two disagree right after a toggle:
            // it says yes while capture still fails until the next launch. The
            // real capture is the only answer worth logging, and its result is
            // what a user reporting "screenshot fails" needs to see.
            let result = ScreenRecording.probe()
            ShellPaths.appendLog("screen recording: granted (probe ok=\(result.ok): \(result.detail))")
            return
        }
        ShellPaths.appendLog("screen recording: NOT granted — send_image --screenshot will fail until it is")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            // The system prompt is what adds DSH to the Settings list; our
            // alert explains the restart rule the system dialog does not.
            let grantedNow = ScreenRecording.request()
            ShellPaths.appendLog("screen recording: system prompt answered, granted=\(grantedNow)")
            self.explainScreenRecording(grantedNow: grantedNow)
        }
    }

    private func explainScreenRecording(grantedNow: Bool) {
        let alert = NSAlert()
        alert.messageText = grantedNow ? "屏幕录制权限已开，需要重新打开 DSH" : "DSH 还没有屏幕录制权限"
        alert.informativeText = grantedNow
            ? """
              macOS 只把新的屏幕录制权限交给重新启动后的进程。
              点「立即重新打开」，重启后截图就能用。
              """
            : """
              在「系统设置 → 隐私与安全性 → 屏幕录制」里勾选 DSH（勾选后可能需要点左下角锁解锁）。
              勾选完必须退出并重新打开 DSH.app —— macOS 只让新启动的进程拿到权限。

              不打开也不影响聊天，只是截图发送会失败。
              """
        alert.addButton(withTitle: grantedNow ? "立即重新打开" : "打开系统设置")
        alert.addButton(withTitle: "稍后")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if grantedNow {
                relaunch()
            } else {
                ScreenRecording.openSettings()
            }
        }
    }

    @objc private func screenRecordingMenu() {
        if ScreenRecording.isGranted {
            let result = ScreenRecording.probe()
            ShellPaths.appendLog("screen recording: probe ok=\(result.ok) (\(result.detail))")
            let alert = NSAlert()
            alert.messageText = result.ok ? "屏幕录制权限正常" : "屏幕录制权限未生效"
            alert.informativeText = result.ok
                ? "截图测试通过：\(result.detail)"
                : """
                  系统设置里可能已经勾选，但当前进程还没拿到权限。
                  退出并重新打开 DSH.app 即可。诊断：\(result.detail)
                  """
            alert.addButton(withTitle: result.ok ? "好" : "立即重新打开")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn, !result.ok { relaunch() }
            return
        }
        let grantedNow = ScreenRecording.request()
        explainScreenRecording(grantedNow: grantedNow)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Closing the window must not take the app (or the server it owns) down:
        // macOS sends a reopen AppleEvent when the user clicks the Dock icon.
        // Rebuild the window if it was ever torn down, then bring it forward.
        if window == nil {
            buildWindow()
            if let url = server.url {
                webView.load(URLRequest(url: url))
            } else {
                startServer()
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        supervisor?.cancel()
        supervisor = nil
        let minutes = config.lingerMinutes
        if minutes == 0 {
            ShellPaths.appendLog("quit: stopping owned server (lingerMinutes=0)")
            removeLeaseIfOurs()
            server.stopAll()
            return
        }
        guard server.ownsServer, let pid = server.serverPid else {
            ShellPaths.appendLog("quit: leaving non-owned server alone")
            removeLeaseIfOurs()
            return
        }
        ShellPaths.appendLog("quit: keeping dsh pid \(pid) alive (lingerMinutes=\(minutes))")
        removeLeaseIfOurs()
        if minutes > 0 { scheduleLingerReap(pid: pid, minutes: minutes) }
    }

    /// Detached watchdog: after `minutes`, stop the background server only if no
    /// DSH.app is running and the pid is still the same process.
    ///
    /// Liveness comes from the lease file, NOT from the process name: on macOS
    /// the app's `comm` is the executable path truncated to 15 characters
    /// (`/Applications/DS`), so `pgrep -x DSH` never matches — a name-based
    /// check would kill the server while the user is working in it.
    private func scheduleLingerReap(pid: Int32, minutes: Int) {
        let lease = ShellPaths.lease.path
        let script = "sleep \(minutes * 60); " +
            "if [ -r \"\(lease)\" ]; then " +
            "APID=$(sed -n 's/^pid=//p' \"\(lease)\" | head -n1); " +
            "if [ -n \"$APID\" ] && /bin/kill -0 \"$APID\" 2>/dev/null; then exit 0; fi; " +
            "fi; " +
            "if /bin/kill -0 \(pid) 2>/dev/null; then /bin/kill \(pid) 2>/dev/null; fi"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        do {
            try task.run()
            ShellPaths.appendLog("scheduled linger reap for pid \(pid) in \(minutes) min")
        } catch {
            ShellPaths.appendLog("linger reap not scheduled: \(error.localizedDescription)")
        }
    }

    /// Record this app instance while it runs, so a pending linger watchdog can
    /// tell "app in use" from "app gone" without relying on process names.
    private func writeLease() {
        ShellPaths.ensureDir()
        let text = "pid=\(ProcessInfo.processInfo.processIdentifier)\n" +
            "started=\(ISO8601DateFormatter().string(from: Date()))\n"
        try? text.write(to: ShellPaths.lease, atomically: true, encoding: .utf8)
    }

    private func removeLeaseIfOurs() {
        guard let text = try? String(contentsOf: ShellPaths.lease, encoding: .utf8) else { return }
        let recorded = text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("pid=") else { return nil }
            return String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }.first
        if recorded == String(ProcessInfo.processInfo.processIdentifier) {
            try? FileManager.default.removeItem(at: ShellPaths.lease)
        }
    }

    // MARK: UI

    private func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 860)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = config.appTitle
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        window.setFrameAutosaveName("DSHShellMainWindow")
        // NSWindow defaults to isReleasedWhenClosed = true for programmatic
        // windows. Under ARC that turns our strong reference into a dangling
        // pointer the moment the user clicks the red button, and the next
        // Dock-click (applicationShouldHandleReopen) segfaults in objc_msgSend.
        window.isReleasedWhenClosed = false

        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = .default()
        webConfig.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Tag the browser by *appending* to the default user agent.
        //
        // Do not assign `webView.customUserAgent`: that replaces the whole UA
        // string, and the GUI's editor sniffs `AppleWebKit/…` plus "is this
        // Mac" to pick its WebKit IME path. A UA without AppleWebKit puts the
        // editor on the non-WebKit composition path, where deleting the last
        // character of an underlined (composing) Chinese phrase also deletes
        // the committed character before it.
        webConfig.applicationNameForUserAgent = "DSHShell/1.0"
        // The version chip injected into the page asks the app to run the
        // upgrade whenever this handler exists, so the download and the backend
        // restart happen in one place instead of the page running npm alone.
        webConfig.userContentController.add(self, name: "dshShell")
        webView = WKWebView(frame: frame, configuration: webConfig)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        showPlaceholder("正在启动 DSH…\n首次启动约需 3 秒（DSH 启动时要组装浏览器插件包）；之后重新打开会复用后台服务，几乎瞬间完成。")
    }

    private func showPlaceholder(_ text: String) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{height:100%;margin:0;background:#111318;color:#c8ccd4;
          font:14px -apple-system,"PingFang SC",sans-serif;display:flex;
          align-items:center;justify-content:center}
        .box{text-align:center;max-width:640px;padding:24px}
        .spin{width:22px;height:22px;margin:0 auto 14px;border:2px solid #3a3f4b;
          border-top-color:#7aa2f7;border-radius:50%;animation:s 1s linear infinite}
        @keyframes s{to{transform:rotate(360deg)}}
        pre{text-align:left;white-space:pre-wrap;font-size:12px;color:#8b93a3;
          max-height:320px;overflow:auto;background:#0c0e12;padding:10px;border-radius:8px}
        button{margin-top:12px;background:#2b3242;color:#dbe2f0;border:1px solid #3d465a;
          border-radius:6px;padding:6px 14px;font-size:13px;cursor:pointer}
        </style></head><body><div class="box"><div class="spin"></div>
        <div>\(escapeHTML(text))</div>
        <pre id="log">\(escapeHTML(String(logText.suffix(4000))))</pre>
        <button onclick="location.reload()">刷新</button></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 \(config.appTitle)", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdatesMenu), keyEquivalent: "u")
        appMenu.addItem(withTitle: "屏幕录制权限…", action: #selector(screenRecordingMenu), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "打开配置文件夹", action: #selector(openConfigFolder), keyEquivalent: ",")
        appMenu.addItem(withTitle: "打开日志", action: #selector(openLog), keyEquivalent: "l")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(config.appTitle)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "在浏览器中打开", action: #selector(openInBrowser), keyEquivalent: "b")
        fileMenu.addItem(withTitle: "重启 DSH 服务", action: #selector(restartServer), keyEquivalent: "r")
        fileMenu.addItem(withTitle: "停止后台 DSH 服务并退出", action: #selector(stopServerAndQuit), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "重新打开窗口", action: #selector(reloadPage), keyEquivalent: "R")

        // Without an Edit menu macOS never turns ⌘C/⌘V/⌘X/⌘A/⌘Z into the
        // responder-chain editing commands, so the WKWebView below never sees
        // them: the shortcuts look "broken" even though the page is fine. The
        // items keep a nil target on purpose — the web view is the first
        // responder and answers copy:/paste:/cut:/selectAll:/undo:/redo:.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        // Same flow as the composer's 截图 button: the page owns the capture
        // request and the attachment, the menu only triggers it.
        let shotItem = NSMenuItem(title: "截图并附上", action: #selector(captureScreenshot), keyEquivalent: "a")
        shotItem.keyEquivalentModifierMask = [.control, .command]
        shotItem.target = self
        editMenu.addItem(.separator())
        editMenu.addItem(shotItem)

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "重新载入", action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "放大", action: #selector(zoomIn), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "缩小", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "实际大小", action: #selector(zoomReset), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")

        NSApp.mainMenu = main
    }

    // MARK: Server lifecycle

    private func startServer() {
        logText = ""
        let server = DSHServer()
        self.server = server
        // Every callback is scoped to this exact instance: after a restart the
        // previous process may still deliver exit/output events, and those must
        // never overwrite the state of the new server.
        server.onLog = { [weak self, weak server] text in
            guard let self, let server, self.server === server else { return }
            self.logText += text
            if self.logText.utf8.count > 200_000 { self.logText = String(self.logText.suffix(100_000)) }
        }
        server.onURL = { [weak self, weak server] url in
            guard let self, let server, self.server === server else { return }
            self.window.title = self.config.appTitle
            self.webView.load(URLRequest(url: url))
            if self.config.checkUpdates { self.autoCheckForUpdatesOnce() }
        }
        server.onExit = { [weak self, weak server] code, log in
            guard let self, let server, self.server === server else { return }
            if self.server.url == nil {
                // Self-healing: if a future dsh rejects our extra flags, retry once bare.
                let mentionsArgs = !self.config.extraArgs.isEmpty &&
                    (log.localizedCaseInsensitiveContains("unexpected argument") ||
                     log.localizedCaseInsensitiveContains("unknown option") ||
                     log.localizedCaseInsensitiveContains("unrecognized") ||
                     self.config.extraArgs.contains { log.contains($0) } &&
                     log.localizedCaseInsensitiveContains("error"))
                if mentionsArgs && !self.retriedWithoutArgs {
                    self.retriedWithoutArgs = true
                    ShellPaths.appendLog("retrying without extraArgs after flag error")
                    self.config.extraArgs = []
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startServer() }
                    return
                }
                self.showPlaceholder("DSH 启动失败（退出码 \(code)）。\n配置：\(ShellPaths.config.path)\n命令：\(self.config.dshBin) web --no-open\n\n下方为启动输出：")
            } else {
                self.showPlaceholder("DSH 服务已退出（退出码 \(code)）。正在自动重启…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.restartBackend(reason: "backend exited with status \(code)")
                }
            }
        }
        server.start(config: config)

        // Watchdog: if no URL arrives in time, surface the log instead of a blank window.
        DispatchQueue.main.asyncAfter(deadline: .now() + config.startupTimeoutSeconds) { [weak self, weak server] in
            guard let self, let server, self.server === server, self.server.url == nil else { return }
            self.showPlaceholder("等待 DSH 启动超时（\(Int(self.config.startupTimeoutSeconds)) 秒）。\n可检查 \(ShellPaths.log.path)，或在配置文件中调整 dshBin / extraArgs。")
        }
        tryLoadEndpointLater()
    }

    private func tryLoadEndpointLater() {
        guard server.attached, let url = server.url else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: Supervisor
    //
    // The invariant this app is built around: while the window is open there is
    // a backend that answers. Stopping the server is only ever a step towards
    // starting a new one, and this loop is what keeps that true even when some
    // other path forgets — a crash, a stray kill, or an upgrade that stopped the
    // old code and then relied on a button press that never came.

    private func startSupervisor() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 4, repeating: 3)
        timer.setEventHandler { [weak self] in self?.supervise() }
        timer.resume()
        supervisor = timer
    }

    private func supervise() {
        guard Date() >= supervisorHoldUntil else { return }
        if server.isHealthy() {
            restartAttempts = 0
            return
        }
        if server.isBooting(within: config.startupTimeoutSeconds) { return }
        restartBackend(reason: "watchdog: backend is not serving")
    }

    /// The only place a backend is ever started. Callers stop first and then
    /// come here, so "stopped" can never be the state the app is left in.
    private func restartBackend(reason: String) {
        guard Date() >= supervisorHoldUntil else { return }
        restartAttempts += 1
        // Back off instead of spinning when something is systematically wrong:
        // 3s between tries, then a slow retry once it is clearly not transient.
        supervisorHoldUntil = Date().addingTimeInterval(restartAttempts > 4 ? 15 : 3)
        ShellPaths.appendLog("supervisor: restarting backend (\(reason)), attempt \(restartAttempts)")

        server.stopAll()

        if restartAttempts > 8 {
            showPlaceholder("DSH 后台服务反复启动失败。\n请查看 \(ShellPaths.log.path)，或使用“文件 → 重启 DSH 服务”再试一次。")
            return
        }
        showPlaceholder("正在启动 DSH…")
        startServer()
    }

    // MARK: Actions

    @objc private func showAbout() {
        UpdateChecker.installedVersion(config: config) { version in
            let text = """
            DSH.app — DSH 的 macOS 独立窗口外壳

            当前 dsh 版本：\(version ?? "未知")
            服务地址：\(self.server.url?.absoluteString ?? "未启动")
            运行模式：\(self.server.attached ? "附着到已有实例" : "由本应用启动")
            配置文件：\(ShellPaths.config.path)
            日志文件：\(ShellPaths.log.path)
            """
            let alert = NSAlert()
            alert.messageText = "关于 DSH.app"
            alert.informativeText = text
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    @objc private func openConfigFolder() {
        ShellPaths.ensureDir()
        NSWorkspace.shared.open(ShellPaths.dir)
    }

    @objc private func openLog() {
        ShellPaths.ensureDir()
        if !FileManager.default.fileExists(atPath: ShellPaths.log.path) {
            FileManager.default.createFile(atPath: ShellPaths.log.path, contents: Data())
        }
        NSWorkspace.shared.open(ShellPaths.log)
    }

    @objc private func openInBrowser() {
        if let url = server.url { NSWorkspace.shared.open(url) }
    }

    @objc private func reloadPage() {
        if server.isHealthy() { webView.reload() } else { restartBackend(reason: "reload page") }
    }

    /**
     * ⌃⌘A — ask the page to run one interactive region screenshot and attach
     * it, so the menu shortcut and the composer button can never drift apart.
     */
    @objc private func captureScreenshot() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView?.evaluateJavaScript("window.__dshDesktopShellCapture && window.__dshDesktopShellCapture()") { _, error in
            guard let error = error else { return }
            ShellPaths.appendLog("screenshot shortcut: page hook unavailable: \(error.localizedDescription)")
        }
    }

    @objc private func restartServer() {
        // A manual restart must not be swallowed by an in-flight one.
        supervisorHoldUntil = .distantPast
        restartBackend(reason: "menu")
    }

    @objc private func stopServerAndQuit() {
        server.stopAll()
        ShellPaths.appendLog("background server stopped by menu action")
        NSApp.terminate(nil)
    }

    @objc private func zoomIn() { webView.pageZoom = min(webView.pageZoom + 0.1, 3.0) }
    @objc private func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.4) }
    @objc private func zoomReset() { webView.pageZoom = 1.0 }

    @objc private func checkForUpdatesMenu() { checkForUpdates(interactive: true) }

    private func autoCheckForUpdatesOnce() {
        guard !didPromptThisLaunch else { return }
        didPromptThisLaunch = true
        checkForUpdates(interactive: false)
    }

    private func checkForUpdates(interactive: Bool) {
        UpdateChecker.check(config: config) { [weak self] status in
            guard let self else { return }
            guard let installed = status.installed else {
                if interactive { self.info("检查更新", "无法确定当前 dsh 版本。请确认 npm / dsh 在 PATH 中。") }
                return
            }
            guard let latest = status.latest else {
                if interactive { self.info("检查更新", "无法访问 npm registry：\n\(self.config.registry)") }
                return
            }
            if !status.updateAvailable {
                if interactive { self.info("检查更新", "已是最新版本：\(installed)（跟随 \(status.tag ?? status.channel)）") }
                return
            }
            let alert = NSAlert()
            alert.messageText = "DSH 有新版本 \(latest)"
            let tagText = (status.tag ?? status.channel)
            let tagNote = (self.config.showPrereleases && tagText != "latest") ? "（预发布通道，非 npm 默认升级目标）" : ""
            alert.informativeText = "当前版本：\(installed)\n升级通道：\(tagText)\(tagNote)\n\n升级会在后台执行 npm install -g @deepseek-ai/dsh@\(latest)；完成后后台服务会自动重启，窗口自动刷新。"
            alert.addButton(withTitle: "立即升级")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                self.performUpgrade(to: latest, notifyWeb: false)
            }
        }
    }

    /// Runs the whole upgrade in one place: download, then replace the running
    /// backend so the new code is actually live. `notifyWeb` marks a request
    /// that came from the injected version chip instead of the menu — the page
    /// gets the verdict back instead of a modal.
    private func performUpgrade(to version: String, notifyWeb: Bool) {
        guard !upgradeInFlight else {
            if notifyWeb { notifyUpgradeResult(ok: false, message: "已有升级在进行中，请稍候。") }
            return
        }
        upgradeInFlight = true
        let progress = makeProgressWindow(title: "正在升级 DSH 到 \(version)…")
        UpdateChecker.upgrade(config: config, to: version, progress: { [weak self] line in
            self?.appendProgress(line)
        }) { [weak self] ok, output in
            guard let self else { return }
            self.upgradeInFlight = false
            self.appendProgress(output)
            self.closeProgressWindow()
            if ok {
                // A warm background server keeps running the old code, so it has
                // to be replaced — but stopping it may never be the last step.
                // Restart first, then tell the user what already happened.
                let owned = self.server.ownsServer
                if notifyWeb {
                    self.notifyUpgradeResult(ok: true, message: owned
                        ? "已安装 @deepseek-ai/dsh@\(version)，正在重启后台服务并刷新窗口…"
                        : "已安装 @deepseek-ai/dsh@\(version)。DSH 是你在终端里启动的，请在那边重启 dsh web 后生效。")
                }
                if owned {
                    self.supervisorHoldUntil = .distantPast
                    self.restartBackend(reason: "upgraded to \(version)")
                }
                if !notifyWeb {
                    let alert = NSAlert()
                    alert.messageText = "升级完成"
                    alert.informativeText = owned
                        ? "已安装 @deepseek-ai/dsh@\(version)，后台服务已自动重启，窗口将自动刷新。"
                        : "已安装 @deepseek-ai/dsh@\(version)。如果 DSH 是你在终端里启动的，请在那边重启 dsh web 后生效。"
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
            } else {
                let tail = String(output.suffix(1200))
                if notifyWeb {
                    self.notifyUpgradeResult(ok: false, message: tail)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "升级失败"
                    alert.informativeText = tail
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
            }
            _ = progress
        }
    }

    /// Push the upgrade verdict back into the page so the version card settles
    /// instead of spinning forever when the run did not replace the page.
    private func notifyUpgradeResult(ok: Bool, message: String) {
        let call = "window.__dshShellUpgradeResult && window.__dshShellUpgradeResult(\(ok ? "true" : "false"), \(Self.jsString(message)))"
        webView?.evaluateJavaScript(call) { _, error in
            if let error { ShellPaths.appendLog("upgrade callback failed: \(error.localizedDescription)") }
        }
    }

    /// A JSON-quoted Swift string, so page-bound messages cannot break the call.
    private static func jsString(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value]),
           let text = String(data: data, encoding: .utf8), text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        return "\"\""
    }

    private func relaunch() {
        let bundle = Bundle.main.bundlePath
        server.stopAll()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: bundle),
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func info(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func makeProgressWindow(title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 360))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = text
        window.contentView = scroll
        window.center()
        window.makeKeyAndOrderFront(nil)
        progressWindow = window
        progressText = text
        return window
    }

    private func appendProgress(_ line: String) {
        guard let text = progressText else { return }
        text.string += line.hasSuffix("\n") ? line : line + "\n"
        text.scrollToEndOfDocument(nil)
    }

    private func closeProgressWindow() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
        progressText = nil
    }

    // MARK: WebView delegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        ShellPaths.appendLog("navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        ShellPaths.appendLog("provisional navigation failed: \(error.localizedDescription)")
        showPlaceholder("无法连接 DSH 服务：\(error.localizedDescription)\n点击刷新重试。")
    }

    private func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated,
           !isLoopback(url),
           url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    // MARK: Web → app bridge
    //
    // The injected version chip asks the app to run the upgrade whenever the
    // `dshShell` handler exists, so the page never runs npm on its own and the
    // app can finish the job by restarting the backend and reloading the window.
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "dshShell", let body = message.body as? [String: Any] else { return }
        switch (body["action"] as? String) ?? "" {
        case "upgrade":
            let version = (body["version"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !version.isEmpty else {
                notifyUpgradeResult(ok: false, message: "桌面应用没有收到要升级的版本号。")
                return
            }
            performUpgrade(to: version, notifyWeb: true)
        default:
            break
        }
    }
}

// MARK: - Bootstrap

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
