import Foundation
import Observation
import UIKit
import DSHKit

/// Loads and caches the image bytes a session refers to.
///
/// Message and tool-result content carry only a reference — an id, a media
/// type and a size — so something has to fetch the actual bytes and keep them.
/// Before this existed the transcript drew a filename with a photo icon and
/// never showed the picture at all.
@MainActor
@Observable
final class AttachmentImages {

    /// The session whose attachments are being shown.
    ///
    /// Assigning it switches to that session's own cache — it does not throw the
    /// pictures away. An earlier version cleared everything here, which was safe
    /// but made every return to a conversation re-download its images; the ids
    /// are content hashes, so keeping them per session is both correct (a
    /// session only ever reads its own bucket) and instant on the way back.
    var sessionId: String? {
        didSet {
            guard sessionId != oldValue else { return }
            pruneSessions()
        }
    }

    /// session → attachment id → decoded image.
    private var images: [String: [String: UIImage]] = [:]
    /// session → attachment id → when it last failed.
    ///
    /// A timestamp rather than a set, because "failed" must not mean "forever":
    /// a picture that lost its race with a reconnecting socket used to stay
    /// broken for the rest of the session, with no way for anyone to ask again.
    private var failures: [String: [String: Date]] = [:]
    /// "session|attachment" → the load in progress, so the same picture asked
    /// for twice in one session coalesces while two sessions never share one.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Every cached picture, least recently used first.
    private var recent: [String] = []

    /// Enough for a session's worth of screenshots without hoarding memory.
    ///
    /// Three bounds, because decoded images are large: per session, in total, and
    /// in how many sessions keep a bucket at all. A bucket is dropped whole, so a
    /// conversation never shows a picture it did not load.
    private static let perSessionLimit = 24
    private static let totalLimit = 48
    private static let sessionLimit = 6

    private var key: String { sessionId ?? "" }

    private func bucketKey(_ session: String, _ attachmentId: String) -> String {
        "\(session)|\(attachmentId)"
    }

    private weak var store: ConnectionStore?

    func attach(store: ConnectionStore) {
        self.store = store
    }

    /// The decoded image, when it has already been loaded.
    func cached(_ attachmentId: String) -> UIImage? {
        images[key]?[attachmentId]
    }

    /// How long a failure keeps a re-rendering view from asking again.
    ///
    /// The guard is against a tight loop, not against trying later: past this
    /// window the next render retries by itself, and a tap retries immediately.
    static let retryAfter: TimeInterval = 15

    /// True when this attachment failed and is still inside the quiet window.
    func hasFailed(_ attachmentId: String) -> Bool {
        guard let at = failures[key]?[attachmentId] else { return false }
        return Date().timeIntervalSince(at) < Self.retryAfter
    }

    /// How many attachments are sitting in a failed state, for diagnostics.
    var failureCount: Int { (failures[key] ?? [:]).count }

    /// Forgets every failure, so the next render tries again.
    ///
    /// Called when the link is re-established: whatever failed during the
    /// outage was failing because there was no connection, not because the
    /// request was wrong.
    func clearFailures() {
        guard !failures.isEmpty else { return }
        // Every session, not just this one: what failed during the outage was
        // failing because there was no connection.
        failures.removeAll()
    }

    /// Fetches the bytes once, coalescing everyone who asks for the same image.
    @discardableResult
    func load(_ attachmentId: String) async -> UIImage? {
        let session = key
        let flightKey = bucketKey(session, attachmentId)
        if let cached = images[session]?[attachmentId] {
            touch(flightKey)
            return cached
        }
        if hasFailed(attachmentId) { return nil }
        // Past the quiet window the stale entry must not block the retry.
        failures[session]?.removeValue(forKey: attachmentId)
        if let running = inFlight[flightKey] { return await running.value }
        guard !attachmentId.isEmpty, let sessionId, let client = store?.client else { return nil }

        let task = Task<UIImage?, Never> { [weak self] in
            if self?.shouldInjectFailure(for: attachmentId) == true { return nil }
            do {
                let value = try await client.attachment(
                    sessionId: sessionId,
                    attachmentId: attachmentId
                )
                guard let encoded = value["data"]?.stringValue,
                      let data = Data(base64Encoded: encoded),
                      let image = UIImage(data: data)
                else { return nil }
                return image
            } catch {
                return nil
            }
        }
        inFlight[flightKey] = task

        let image = await task.value
        inFlight[flightKey] = nil
        if let image {
            store(image, for: attachmentId, in: session)
            failures[session]?.removeValue(forKey: attachmentId)
        } else {
            failures[session, default: [:]][attachmentId] = Date()
        }
        return image
    }

    /// The person asked for this picture again.
    ///
    /// The one path that ignores the quiet window: a tap is not a loop.
    @discardableResult
    func retry(_ attachmentId: String) async -> UIImage? {
        failures[key]?.removeValue(forKey: attachmentId)
        return await load(attachmentId)
    }

    /// Clears everything, for every session.
    ///
    /// Called when the connection itself changes: the pictures belong to the
    /// computer that served them, and session ids are unique per host, not
    /// across hosts. Switching *sessions* does not come here — that just changes
    /// which bucket is read.
    func reset() {
        images.removeAll()
        failures.removeAll()
        recent.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    /// `-DSHFailAttachmentLoad <n>`: make the first n attempts per picture fail.
    ///
    /// A run cannot wait for a real network failure to prove the retry path, and
    /// the failure that matters here (a socket that was down when the row
    /// appeared) is exactly the one that is hardest to stage. Injected failure
    /// only; everything after it — the placeholder, the tap, the reload — is the
    /// real code.
    private static let injectedFailures: Int = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHFailAttachmentLoad"),
              index + 1 < arguments.count,
              let count = Int(arguments[index + 1])
        else { return 0 }
        return max(0, count)
    }()

    private var injectedAttempts: [String: Int] = [:]

    private func shouldInjectFailure(for attachmentId: String) -> Bool {
        guard Self.injectedFailures > 0 else { return false }
        let attempts = (injectedAttempts[attachmentId] ?? 0) + 1
        injectedAttempts[attachmentId] = attempts
        return attempts <= Self.injectedFailures
    }

    private func store(_ image: UIImage, for attachmentId: String, in session: String) {
        images[session, default: [:]][attachmentId] = image
        touch(bucketKey(session, attachmentId))
        evict()
    }

    /// Marks a picture as just used.
    private func touch(_ flightKey: String) {
        recent.removeAll { $0 == flightKey }
        recent.append(flightKey)
    }

    /// Enforces the three bounds by dropping whole pictures, oldest first.
    private func evict() {
        // 总量：全局 LRU 里最旧的那些
        while recent.count > Self.totalLimit {
            drop(recent.first)
        }
        // 单个会话：`recent` 是按使用顺序排的，前缀里最旧的先丢
        for (session, bucket) in images where bucket.count > Self.perSessionLimit {
            let sessionKeys = recent.filter { $0.hasPrefix("\(session)|") }
            for flightKey in sessionKeys.prefix(bucket.count - Self.perSessionLimit) {
                drop(flightKey)
            }
        }
        pruneSessions()
    }

    /// Removes one cached picture (and its bucket, when it becomes empty).
    private func drop(_ flightKey: String?) {
        guard let flightKey else { return }
        recent.removeAll { $0 == flightKey }
        let parts = flightKey.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        images[parts[0]]?.removeValue(forKey: parts[1])
        if images[parts[0]]?.isEmpty == true { images.removeValue(forKey: parts[0]) }
    }

    /// Keeps at most `sessionLimit` sessions, oldest first.
    private func pruneSessions() {
        var seen: [String] = []
        for flightKey in recent.reversed() {
            guard let session = flightKey.split(separator: "|", maxSplits: 1).first.map(String.init) else { continue }
            if !seen.contains(session) { seen.append(session) }
        }
        for session in images.keys where !seen.contains(session) {
            images.removeValue(forKey: session)
            failures.removeValue(forKey: session)
        }
        for session in seen.dropFirst(Self.sessionLimit) {
            images.removeValue(forKey: session)
            failures.removeValue(forKey: session)
            recent.removeAll { $0.hasPrefix("\(session)|") }
        }
    }
}
