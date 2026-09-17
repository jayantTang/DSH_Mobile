import Foundation

/// Sends a file from the phone to the computer, in pieces.
///
/// The Host has no upload endpoint: `workspaceFiles/*` is read-only and the
/// protocol's `{type:'file', receiptId}` part needs a receipt from an
/// `uploadFile` call that this build does not serve. So the link carries the
/// bytes itself, addressed to reserved method names the connector answers
/// locally instead of forwarding to the Host.
///
/// Nothing about the wire protocol changes: these are ordinary unary calls, so
/// the relay passes them through untouched.
public struct FileUploader: Sendable {

    /// How much of the file travels in one call.
    ///
    /// Sized to stay well inside the relay's frame limit while keeping the
    /// number of round trips reasonable for a multi-megabyte document.
    public static let chunkBytes = 192 * 1024

    private let carrier: any DSHCarrier

    public init(carrier: any DSHCarrier) {
        self.carrier = carrier
    }

    /// One staged file on the computer.
    public struct Staged: Decodable, Sendable {
        public let path: String
        public let bytes: Int
    }

    private struct BeginArgs: Encodable { let transferId, sessionId, name: String; let bytes: Int }
    private struct ChunkArgs: Encodable { let transferId: String; let seq: Int; let data: String }
    private struct EndArgs: Encodable { let transferId: String }
    private struct Ack: Decodable { let accepted: Bool?; let received: Int? }

    /// Uploads `data` and returns where it landed.
    ///
    /// Chunked rather than one call so a large document does not have to fit in
    /// a single frame, and so a failure can be retried from the beginning
    /// without re-encoding anything.
    public func upload(
        data: Data,
        name: String,
        sessionId: String,
        transferId: String = UUID().uuidString
    ) async throws -> Staged {
        let chunks = stride(from: 0, to: max(data.count, 1), by: Self.chunkBytes).map { offset in
            data.subdata(in: offset..<min(offset + Self.chunkBytes, data.count))
        }

        _ = try await carrier.unary(
            method: "_link/fileBegin",
            args: BeginArgs(transferId: transferId, sessionId: sessionId, name: name, bytes: data.count),
            as: Ack.self
        )

        for (seq, chunk) in chunks.enumerated() {
            _ = try await carrier.unary(
                method: "_link/fileChunk",
                args: ChunkArgs(transferId: transferId, seq: seq, data: chunk.base64EncodedString()),
                as: Ack.self
            )
        }

        return try await carrier.unary(
            method: "_link/fileEnd",
            args: EndArgs(transferId: transferId),
            as: Staged.self
        )
    }
}
