import Foundation

public enum PreferenceSignalKind: String, Codable, Hashable, Sendable {
    case selection
    case purchase
    case rejection
    case removal

    public var baseWeight: Double {
        switch self {
        case .selection, .purchase: 1
        case .rejection: -1
        case .removal: -0.25
        }
    }
}

public struct PreferenceEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let userID: UUID
    public let category: String
    public let productID: UUID
    public let brand: String
    public let size: String
    public let attributes: [String: String]
    public let price: Decimal
    public let currency: String
    public let kind: PreferenceSignalKind
    public let memoryEpoch: Int
    public let occurredAt: Date
    public let idempotencyKey: String

    public init(
        id: UUID = UUID(),
        userID: UUID,
        product: ProductCandidate,
        kind: PreferenceSignalKind,
        memoryEpoch: Int,
        occurredAt: Date = .now,
        idempotencyKey: String = UUID().uuidString
    ) {
        self.id = id
        self.userID = userID
        self.category = product.category
        self.productID = product.id
        self.brand = product.brand
        self.size = product.size
        self.attributes = product.attributes
        self.price = product.price
        self.currency = product.currency
        self.kind = kind
        self.memoryEpoch = memoryEpoch
        self.occurredAt = occurredAt
        self.idempotencyKey = idempotencyKey
    }
}

public enum PreferenceDimension: String, Codable, Hashable, Sendable {
    case brand
    case size
    case attribute
}

public struct LearnedPreference: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let category: String
    public let dimension: PreferenceDimension
    public let key: String
    public let value: String
    public let score: Double
    public let signalCount: Int

    public init(
        category: String,
        dimension: PreferenceDimension,
        key: String,
        value: String,
        score: Double,
        signalCount: Int
    ) {
        self.id = "\(category)|\(dimension.rawValue)|\(key)|\(value)"
        self.category = category
        self.dimension = dimension
        self.key = key
        self.value = value
        self.score = score
        self.signalCount = signalCount
    }
}

public struct AcceptedPriceProfile: Codable, Hashable, Sendable {
    public let currency: String
    public let median: Decimal
    public let lowerBound: Decimal
    public let upperBound: Decimal
    public let positiveSignalCount: Int

    public init(currency: String, median: Decimal, lowerBound: Decimal, upperBound: Decimal, positiveSignalCount: Int) {
        self.currency = currency
        self.median = median
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.positiveSignalCount = positiveSignalCount
    }
}

public struct LearnedPreferenceSummary: Codable, Hashable, Sendable {
    public let userID: UUID
    public let memoryEpoch: Int
    public let entries: [LearnedPreference]
    public let acceptedPricesByCategory: [String: AcceptedPriceProfile]
    public let updatedAt: Date

    public init(
        userID: UUID,
        memoryEpoch: Int,
        entries: [LearnedPreference],
        acceptedPricesByCategory: [String: AcceptedPriceProfile],
        updatedAt: Date = .now
    ) {
        self.userID = userID
        self.memoryEpoch = memoryEpoch
        self.entries = entries
        self.acceptedPricesByCategory = acceptedPricesByCategory
        self.updatedAt = updatedAt
    }

    public func strongestBrand(in category: String) -> String? {
        entries
            .filter { $0.category == category && $0.dimension == .brand && $0.score > 0 }
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.value < rhs.value : lhs.score > rhs.score
            }
            .first?.value
    }

    public static func empty(userID: UUID, epoch: Int = 0) -> Self {
        .init(userID: userID, memoryEpoch: epoch, entries: [], acceptedPricesByCategory: [:])
    }
}
