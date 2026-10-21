import Foundation

/// Which search a session offers, and how to ask for its next page.
///
/// The connector can search the whole session (`_link/sessionFind`, spec 007
/// P2). A phone talking to a connector without `session-search` keeps the
/// on-device search over what is already loaded — capped, but honest about it
/// (FR-015/FR-036). This type owns that choice so the sheet does not have to
/// grow a second, subtly different, branch.
public struct TranscriptSearchService: Sendable {

    public enum Source: Sendable, Equatable {
        /// The connector searches the whole session.
        case connector
        /// Only what the phone already holds (the pre-007 behaviour).
        case local
    }

    public enum Failure: Error, CustomStringConvertible {
        /// This session offers the on-device search only; the caller runs its own.
        case localOnly
        /// The connector has the capability but refused this call.
        case unsupported(String)

        public var description: String {
            switch self {
            case .localOnly: return "this connector cannot search the whole session"
            case .unsupported(let message): return message
            }
        }
    }

    public let source: Source
    private let client: any ChatHosting
    private let address: SessionAddress

    public init(client: any ChatHosting, address: SessionAddress, capabilities: Set<String>) {
        self.client = client
        self.address = address
        self.source = capabilities.contains("session-search") ? .connector : .local
    }

    /// One page of hits, newest first. `onlyMine` maps onto the `me` role.
    public func page(query: String, onlyMine: Bool, cursor: String? = nil,
                     limit: Int = 50) async throws -> HistorySearchValue {
        guard source == .connector else { throw Failure.localOnly }
        do {
            return try await client.sessionFind(
                HistorySearchRequest(address: address, query: query,
                                     roles: onlyMine ? ["me"] : nil,
                                     limit: limit, cursor: cursor)
            )
        } catch {
            // `link/unsupported` means "this connector cannot", not "no results":
            // the caller must tell the reader apart from an empty answer (FR-013).
            throw Failure.unsupported(String(describing: error))
        }
    }
}
