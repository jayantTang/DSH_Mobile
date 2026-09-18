import Foundation

/// Rebuilds one frame that the relay wrote as several WebSocket messages.
///
/// The relay splits a device-bound frame larger than 512 KB into several
/// WebSocket *messages* once the device is over its rate (`relay/hub.py::_send`),
/// on the stated assumption that "the channel is a stream, so the client
/// reassembles the frame". WebSocket messages are not a stream: each arrives as
/// its own `receive()`, so a parser that treats every message as a frame throws
/// the first fragment away as malformed JSON and the rest as garbage — and the
/// call that frame belonged to then never answers, with nothing on screen
/// saying why.
///
/// The rule here is therefore "accumulate until it parses". Only one frame is
/// ever being written to a device at a time — the relay sends from a single
/// queue, one `_send` at a time, and a heartbeat reply is queued like anything
/// else — so the fragments of a split frame are contiguous and the buffer never
/// holds two frames at once. A buffer that grows past `limit` is a protocol
/// violation rather than a large frame, and is reported so the caller can drop
/// the connection instead of waiting forever.
struct FrameAssembler {

    /// The largest frame this will hold. The relay's own frame cap, so a frame
    /// the relay would refuse is not silently buffered to death here.
    static let defaultLimit = 32 * 1024 * 1024

    enum Failure: Error, Equatable {
        /// The bytes so far cannot be a frame and never will be.
        case tooLarge(limit: Int)
    }

    private var buffer = Data()
    private let limit: Int

    init(limit: Int = FrameAssembler.defaultLimit) {
        self.limit = limit
    }

    /// Whether part of a frame is waiting for the rest of itself.
    var isHoldingPartialFrame: Bool { !buffer.isEmpty }

    /// Adds one WebSocket message and returns the frame it completed, if any.
    ///
    /// A message that is already a whole frame passes straight through — the
    /// normal case, since the relay only splits when it has to.
    mutating func feed(_ message: Data) throws -> Data? {
        if buffer.isEmpty {
            if Self.isWholeFrame(message) { return message }
            buffer = message
        } else {
            buffer.append(message)
        }
        guard buffer.count <= limit else {
            buffer.removeAll()
            throw Failure.tooLarge(limit: limit)
        }
        guard Self.isWholeFrame(buffer) else { return nil }
        let frame = buffer
        buffer.removeAll()
        return frame
    }

    /// Forgets a partial frame, for a socket that is being replaced.
    mutating func reset() {
        buffer.removeAll()
    }

    /// Whether these bytes are one whole frame.
    ///
    /// A frame is a JSON object with a non-empty string `t` — the same shape the
    /// relay itself insists on (`relay/dlp.py::parse_frame`). The cheap last-byte
    /// test in front of the parse is what keeps this affordable on a multi-
    /// megabyte frame: every fragment but the last ends mid-JSON, so the parser
    /// runs once instead of once per fragment.
    private static func isWholeFrame(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        guard let last = data.last(where: { !Self.isWhitespace($0) }),
              last == UInt8(ascii: "}")
        else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard let type = object["t"] as? String else { return false }
        return !type.isEmpty
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}
