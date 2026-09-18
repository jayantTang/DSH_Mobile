import DSHKit
import Foundation

/// Fetches a web page and the files it refers to into a local directory.
///
/// The report lives on the computer; a `WKWebView` renders from a URL. So the
/// page is pulled over the same RPC the file browser uses and written to a
/// temporary directory, and the web view is pointed at *that* — which is what
/// lets a relative `media/….jpg` resolve without teaching the web view anything
/// about the host, the relay or authentication.
///
/// Scope is deliberately narrow: one directory at a time, only the files the
/// page names, nothing written outside the app's own container.
@MainActor
final class WorkspaceWebPage {

    enum Phase: Equatable {
        case idle
        case loading(String)
        case ready(URL, missing: [String])
        case failed(String)
    }

    /// One fetched page, kept so a second look costs nothing.
    struct Loaded {
        let url: URL
        let html: String
        let missing: [String]
    }

    private(set) var phase: Phase = .idle
    private var loaded: Loaded?

    private let downloader: WorkspaceFileDownloader
    private let scopeId: String
    private let path: String
    /// 8 MB: past this the phone should say "look at it on the computer" rather
    /// than spend its memory on a file nobody asked it to hold.
    private let sizeLimit = 8 * 1024 * 1024

    init(client: DSHClient, scopeId: String, path: String) {
        // Zero pacing: these are the handful of files a page needs before it can
        // be drawn, and making the reader wait 50 ms between every window would
        // be paid on every open.
        self.downloader = WorkspaceFileDownloader(client: client, pacing: .zero)
        self.scopeId = scopeId
        self.path = path
    }

    /// Loads once, then serves from memory.
    func load() async {
        if case .ready = phase, loaded != nil { return }
        if case .loading = phase { return }
        phase = .loading("正在读取…")
        do {
            let page = try await fetchPage()
            loaded = page
            phase = .ready(page.url, missing: page.missing)
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// Re-reads from the host, for the pull-to-refresh gesture.
    func reload() async {
        loaded = nil
        phase = .idle
        await load()
    }

    private func fetchPage() async throws -> Loaded {
        let data: Data
        do {
            data = try await downloader.data(scopeId: scopeId, path: path, cap: sizeLimit)
        } catch let failure as WorkspaceFileDownloader.Failure {
            if case .overCap(_, let bytes) = failure { throw PageError.tooLarge(bytes ?? 0) }
            throw failure
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw PageError.notText(data.count)
        }

        let directory = Self.directoryFor(scopeId: scopeId, path: path)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = (path as NSString).deletingLastPathComponent
        let resources = Self.references(in: html)
        var missing: [String] = []

        // Fetched together: a report with six screenshots should not take six
        // round trips in series.
        await withTaskGroup(of: String?.self) { group in
            for resource in resources {
                group.addTask { [downloader, scopeId, base, directory] in
                    let remote = base.isEmpty ? resource : "\(base)/\(resource)"
                    guard let bytes = try? await downloader.data(
                        scopeId: scopeId, path: remote, cap: 8 * 1024 * 1024
                    ) else { return resource }
                    let target = directory.appendingPathComponent(resource)
                    try? FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? bytes.write(to: target)
                    return nil
                }
            }
            for await failure in group {
                if let failure { missing.append(failure) }
            }
        }

        let page = directory.appendingPathComponent((path as NSString).lastPathComponent)
        try data.write(to: page)
        return Loaded(url: page, html: html, missing: missing.sorted())
    }

    /// Relative resources a static page refers to: `<link href>` and `<img src>`.
    ///
    /// Parsed with a regular expression rather than a real parser on purpose:
    /// the page is one this project generates, the shapes are known, and a
    /// dependency is not worth carrying for it. Anything absolute
    /// (`data:`, `http:`, `/…`) is skipped — the report has none by design.
    static func references(in html: String) -> [String] {
        var found: [String] = []
        let pattern = #"<(?:img|link|script)[^>]*?(?:src|href)\s*=\s*['"]([^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return found
        }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, options: [], range: range) {
            guard let captured = Range(match.range(at: 1), in: html) else { continue }
            let value = String(html[captured])
            guard !value.hasPrefix("data:"), !value.hasPrefix("http:"),
                  !value.hasPrefix("https:"), !value.hasPrefix("/"), !value.hasPrefix("#")
            else { continue }
            if !found.contains(value) { found.append(value) }
        }
        return found
    }

    private static func directoryFor(scopeId: String, path: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workspace-web", isDirectory: true)
        // Folders keep a readable tail so the cache can be inspected by hand,
        // and a stable prefix so two reports never overwrite each other's
        // pictures. A digest, not `hashValue`, which changes between launches.
        let key = "\\(scopeId)~\\(path)"
        let digest = key.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        let tail = (path as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .prefix(40)
        return base.appendingPathComponent("\(String(digest, radix: 16))-\(tail)", isDirectory: true)
    }

    enum PageError: Error, LocalizedError {
        case tooLarge(Int)
        case notText(Int)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                "文件 \(ByteFormat.compact(bytes))，超过手机上直接打开的上限，请在电脑上查看。"
            case .notText:
                "这个文件不是文本，无法作为网页打开。"
            }
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let page = error as? PageError { return page.errorDescription ?? "无法打开" }
        return error.localizedDescription
    }
}
