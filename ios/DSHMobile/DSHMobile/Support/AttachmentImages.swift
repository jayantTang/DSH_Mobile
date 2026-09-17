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
    private var failures: Set<String> = []
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

    /// True when this attachment failed to load and should not be retried in a
    /// tight loop by a re-rendering view.
    func hasFailed(_ attachmentId: String) -> Bool {
        failures.contains(attachmentId)
    }

    /// Fetches the bytes once, coalescing everyone who asks for the same image.
    @discardableResult
    func load(_ attachmentId: String) async -> UIImage? {
        if let cached = images[attachmentId] { return cached }
        if failures.contains(attachmentId) { return nil }
        if let running = inFlight[attachmentId] { return await running.value }
        guard !attachmentId.isEmpty, let sessionId, let client = store?.client else { return nil }

        let task = Task<UIImage?, Never> { [weak self] in
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
        } else {
            failures.insert(attachmentId)
        }
        return image
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

    private func store(_ image: UIImage, for attachmentId: String) {
        images[attachmentId] = image
        order.removeAll { $0 == attachmentId }
        order.append(attachmentId)
        while order.count > Self.limit {
            images.removeValue(forKey: order.removeFirst())
        }
    }
}
