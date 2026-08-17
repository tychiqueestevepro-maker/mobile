import Foundation

public struct ClarificationQuestion: Codable, Hashable, Sendable {
    public var prompt: String
    public var options: [String]
    public var attributeKey: String

    public init(prompt: String, options: [String], attributeKey: String) {
        self.prompt = prompt
        self.options = options
        self.attributeKey = attributeKey
    }
}

public struct NeedIntent: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var category: String
    public var normalizedQuery: String
    public var attributes: [String: String]
    public var quantity: Int
    public var confidence: Double
    public var clarification: ClarificationQuestion?

    public init(
        id: UUID = UUID(),
        category: String,
        normalizedQuery: String,
        attributes: [String: String] = [:],
        quantity: Int = 1,
        confidence: Double,
        clarification: ClarificationQuestion? = nil
    ) {
        self.id = id
        self.category = category
        self.normalizedQuery = normalizedQuery
        self.attributes = attributes
        self.quantity = max(1, quantity)
        self.confidence = min(max(confidence, 0), 1)
        self.clarification = clarification
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, attributes, quantity, confidence, clarification
        case normalizedQuery = "normalized_query"
    }
}

public struct Need: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let userID: UUID
    public var originalText: String
    public var intent: NeedIntent
    public var source: Source
    public let createdAt: Date

    public enum Source: String, Codable, Hashable, Sendable {
        case text
        case voice
    }

    public init(
        id: UUID = UUID(),
        userID: UUID,
        originalText: String,
        intent: NeedIntent,
        source: Source,
        createdAt: Date = .now
    ) {
        self.id = id
        self.userID = userID
        self.originalText = originalText
        self.intent = intent
        self.source = source
        self.createdAt = createdAt
    }
}
