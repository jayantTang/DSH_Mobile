import Foundation

/// A file that has been staged on the computer, and where it landed.
///
/// One type for one outcome: **there is a single route for file bytes** (the
/// relay's HTTP surface driven by a background `URLSession` task), so whoever
/// receives one of these does not — and must not — know which transport carried
/// it. That is why the type lives here rather than next to either transport:
/// `DSHKit` is the neutral floor both sides can see, and neither transport owns
/// the answer shape.
///
/// It was `FileUploader.Staged` until the second upload implementation (the WSS
/// chunked path) was deleted; the WSS type went with it and this took its place.
public struct StagedFile: Decodable, Sendable, Equatable {
    /// Absolute path on the computer, as the connector reported it.
    public let path: String
    /// How many bytes landed there.
    public let bytes: Int

    public init(path: String, bytes: Int) {
        self.path = path
        self.bytes = bytes
    }
}
