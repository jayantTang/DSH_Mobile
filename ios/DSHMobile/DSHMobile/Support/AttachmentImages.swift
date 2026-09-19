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
    /// Set when a session is opened, so any view holding this store can resolve
    /// a block without threading a session id through every row.
    var sessionId: String?

    private var images: [String: UIImage] = [:]
    /// When each failed attachment last failed.
    ///
    /// A timestamp rather than a set, because "failed" must not mean "forever":
    /// a picture that lost its race with a reconnecting socket used to stay
    /// broken for the rest of the session, with no way for anyone to ask again.
    private var failures: [String: Date] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var order: [String] = []

    /// Enough for a session's worth of screenshots without hoarding memory.
    private static let limit = 24

    private weak var store: ConnectionStore?

    func attach(store: ConnectionStore) {
        self.store = store
    }

    /// The decoded image, when it has already been loaded.
    func cached(_ attachmentId: String) -> UIImage? {
        images[attachmentId]
    }

    /// How long a failure keeps a re-rendering view from asking again.
    ///
    /// The guard is against a tight loop, not against trying later: past this
    /// window the next render retries by itself, and a tap retries immediately.
    static let retryAfter: TimeInterval = 15

    /// True when this attachment failed and is still inside the quiet window.
    func hasFailed(_ attachmentId: String) -> Bool {
        guard let at = failures[attachmentId] else { return false }
        return Date().timeIntervalSince(at) < Self.retryAfter
    }

    /// How many attachments are sitting in a failed state, for diagnostics.
    var failureCount: Int { failures.count }

    /// Forgets every failure, so the next render tries again.
    ///
    /// Called when the link is re-established: whatever failed during the
    /// outage was failing because there was no connection, not because the
    /// request was wrong.
    func clearFailures() {
        guard !failures.isEmpty else { return }
        failures.removeAll()
    }

    /// Fetches the bytes once, coalescing everyone who asks for the same image.
    @discardableResult
    func load(_ attachmentId: String) async -> UIImage? {
        if let cached = images[attachmentId] { return cached }
        if hasFailed(attachmentId) { return nil }
        // Past the quiet window the stale entry must not block the retry.
        failures.removeValue(forKey: attachmentId)
        if let running = inFlight[attachmentId] { return await running.value }
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
        inFlight[attachmentId] = task

        let image = await task.value
        inFlight[attachmentId] = nil
        if let image {
            store(image, for: attachmentId)
            failures.removeValue(forKey: attachmentId)
        } else {
            failures[attachmentId] = Date()
        }
        return image
    }

    /// The person asked for this picture again.
    ///
    /// The one path that ignores the quiet window: a tap is not a loop.
    @discardableResult
    func retry(_ attachmentId: String) async -> UIImage? {
        failures.removeValue(forKey: attachmentId)
        return await load(attachmentId)
    }

    /// Clears everything when the session changes.
    ///
    /// Attachment ids are content hashes, so a cache could in principle be
    /// global — but they are authorized per session, and dropping them keeps
    /// memory bounded when hopping between conversations.
    func reset() {
        images.removeAll()
        failures.removeAll()
        order.removeAll()
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

    private func store(_ image: UIImage, for attachmentId: String) {
        images[attachmentId] = image
        order.removeAll { $0 == attachmentId }
        order.append(attachmentId)
        while order.count > Self.limit {
            images.removeValue(forKey: order.removeFirst())
        }
    }
}
