import Foundation

/// The stable failure shape DSH returns for a rejected RPC.
///
/// Every rejection on every transport — unary `/api` calls, logical stream
/// frames, and the relay's own control errors — is normalized to this shape so
/// callers can branch on `code` uniformly.
public struct DSHRPCFailure: Error, Sendable, Hashable, Codable {
    public let code: String
    public let message: String
    public let details: JSONValue

    public init(code: String, message: String, details: JSONValue = .object([:])) {
        self.code = code
        self.message = message
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, details
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? container.decode(String.self, forKey: .code))
            ?? (try? container.decode(String.self, forKey: .message)) ?? "unknown"
        message = (try? container.decode(String.self, forKey: .message)) ?? code
        details = (try? container.decode(JSONValue.self, forKey: .details)) ?? .object([:])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(details, forKey: .details)
    }
}

extension DSHRPCFailure: LocalizedError {
    public var errorDescription: String? { String(localized: String.LocalizationValue(message)) }
    public var failureReason: String? { code }
}

extension DSHRPCFailure {
    /// Whether re-authenticating and retrying could plausibly succeed.
    ///
    /// DSH rotates its launch token when the server restarts, so a stale
    /// cookie surfaces as an auth failure rather than a transport error.
    public var isAuthenticationFailure: Bool {
        code.contains("unauthorized")
            || code.contains("forbidden")
            || code.contains("auth")
            || code == "gateway/unauthorized"
    }

    /// Whether the addressed session/workspace no longer exists.
    public var isNotFound: Bool {
        code.hasSuffix("/not-found") || code == "gateway/not-found"
    }
}

/// Failures raised by the client stack itself, before or around DSH.
public enum DSHTransportError: Error, Sendable {
    /// The carrier could not reach the host at all.
    case unreachable(String)
    /// No link is open, so there is nothing to send over.
    case notConnected
    /// The host answered with an unexpected HTTP status.
    case httpStatus(Int, body: String?)
    /// The response body was not the envelope the protocol requires.
    case malformedResponse(String)
    /// The session cookie is missing, expired, or was rejected.
    case notAuthenticated(String)
    /// The carrier was closed underneath an in-flight request.
    case carrierClosed
    /// A logical stream failed after it had opened.
    case streamFailed(DSHRPCFailure)
    /// The request exceeded its deadline.
    case timedOut(method: String)
}

extension DSHTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            return "无法连接到 DSH：\(detail)"
        case .httpStatus(let status, let body):
            if let body, !body.isEmpty {
                return "DSH 返回 HTTP \(status)：\(body.prefix(400))"
            }
            return "DSH 返回 HTTP \(status)"
        case .malformedResponse(let detail):
            return "DSH 响应格式异常：\(detail)"
        case .notAuthenticated(let detail):
            return "认证失败：\(detail)"
        case .notConnected:
            return "尚未连接，无法发送"
        case .carrierClosed:
            return "连接已关闭"
        case .streamFailed(let failure):
            return failure.message
        case .timedOut(let method):
            return "请求超时：\(method)"
        }
    }
}
