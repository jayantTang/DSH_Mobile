import Foundation

/// One entry in the desktop client's workspace list.
///
/// Workspaces are an explicit, user-curated grouping — not a derived one. The
/// sidebar shows these, in this order, with the sessions the user put in them.
/// Anything not listed here belongs to no workspace at all.
public struct Workspace: Sendable, Codable, Identifiable, Hashable {
    public let workspaceId: String
    public let path: String
    public let title: String
    /// The sessions this workspace holds, in the user's own order.
    public let sessionIds: [String]

    public var id: String { workspaceId }
}

/// The result of registering a directory as a workspace.
///
/// `created` is false when the directory was already registered: the call is
/// "resolve or register", and the caller only needs the identity either way.
public struct WorkspaceCreateValue: Sendable, Codable {
    public let workspace: Workspace
    public let created: Bool
}

/// The opening frame of the `workspace/follow` stream.
public struct WorkspaceBaseline: Sendable, Codable {
    public let items: [Workspace]
    public let archivedSessionIds: [String]

    public init(items: [Workspace], archivedSessionIds: [String] = []) {
        self.items = items
        self.archivedSessionIds = archivedSessionIds
    }

    private enum CodingKeys: String, CodingKey { case items, archivedSessionIds }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? container.decode([Workspace].self, forKey: .items)) ?? []
        archivedSessionIds = (try? container.decode([String].self, forKey: .archivedSessionIds)) ?? []
    }
}

/// One frame of the workspace stream: the baseline, then change notifications.
public enum WorkspaceFrame: Sendable {
    case baseline(WorkspaceBaseline)
    case change(JSONValue)
    case unknown(type: String?, raw: JSONValue)

    /// The baseline payload, when this frame is one.
    public var baseline: WorkspaceBaseline? {
        if case .baseline(let value) = self { return value }
        return nil
    }
}

extension WorkspaceFrame: Decodable {
    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try? container.decode(String.self, forKey: .type)
        if type == "baseline" {
            self = .baseline(
                (try? container.decode(WorkspaceBaseline.self, forKey: .value)) ?? WorkspaceBaseline(items: [])
            )
        } else if type == "value" || type == "change" {
            self = .change((try? container.decode(JSONValue.self, forKey: .value)) ?? .null)
        } else {
            self = .unknown(type: type, raw: (try? JSONValue(from: decoder)) ?? .null)
        }
    }
}
