import Foundation

// MARK: - Model catalog

/// Every route the host can currently serve.
public struct ModelCatalog: Sendable, Codable {
    public let `default`: ModelSelection?
    public let routableProviders: [String]?
    public let groups: [ModelProviderGroup]?
    public let failures: [ModelCatalogFailure]?
}

public struct ModelProviderGroup: Sendable, Codable, Identifiable {
    public let id: String
    public let name: String?
    public let models: [ModelDescriptor]?
}

public struct ModelDescriptor: Sendable, Codable, Identifiable {
    public let id: String
    public let name: String?
    public let reasoning: Reasoning?

    /// The selectable reasoning efforts this model accepts.
    public struct Reasoning: Sendable, Codable {
        public let efforts: [Effort]?
        /// The effort the host picks when the caller names none.
        ///
        /// Carried through rather than re-derived: "the first effort in the
        /// list" is a different answer, and writing a default model without it
        /// would silently pick a level the host never chose.
        public let defaultEffort: String?

        public struct Effort: Sendable, Codable, Identifiable {
            public let id: String
            public let name: String?
            public let description: String?
        }
    }

    public var displayName: String { name ?? id }
}

public struct ModelCatalogFailure: Sendable, Codable {
    public let provider: String?
    public let message: String?
}

// MARK: - Skills

public struct SkillListValue: Sendable, Codable {
    public let skills: [SkillEntry]?
}

public struct SkillEntry: Sendable, Codable, Identifiable {
    public let name: String
    public let description: String?

    public var id: String { name }
}

// MARK: - File references

/// One `@`-mention candidate returned while typing in the composer.
public struct FileReferenceCandidate: Sendable, Codable, Identifiable, Hashable {
    public let path: String
    public let kind: String?

    public var id: String { path }
    public var isDirectory: Bool { kind == "directory" }
}

// MARK: - Prompt content

/// One part of an outbound prompt.
public enum PromptContentPart: Encodable, Sendable {
    case text(String)
    case image(mediaType: String, data: String, name: String?)
    case file(receiptId: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, mediaType, data, name, receiptId
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let mediaType, let data, let name):
            try container.encode("image", forKey: .type)
            try container.encode(mediaType, forKey: .mediaType)
            try container.encode(data, forKey: .data)
            try container.encodeIfPresent(name, forKey: .name)
        case .file(let receiptId):
            try container.encode("file", forKey: .type)
            try container.encode(receiptId, forKey: .receiptId)
        }
    }
}
