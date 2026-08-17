import Foundation

public enum ProductAvailability: String, Codable, Hashable, Sendable {
    case inStock = "in_stock"
    case lowStock = "low_stock"
    case unavailable

    public var isPurchasable: Bool { self != .unavailable }
}

public enum ProductMatchTier: Int, Codable, Comparable, Hashable, Sendable {
    case fallback = 0
    case partial = 1
    case strong = 2
    case exact = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum CandidateKind: String, Codable, Hashable, Sendable {
    case bestMatch = "best_match"
    case bestValue = "best_value"
    case discovery
    case standard
}

public struct Retailer: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var deliveryFee: Decimal
    public var serviceFee: Decimal

    public init(id: UUID, name: String, deliveryFee: Decimal, serviceFee: Decimal) {
        self.id = id
        self.name = name
        self.deliveryFee = deliveryFee
        self.serviceFee = serviceFee
    }
}

public struct ProductCandidate: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let storeID: UUID
    public var retailerName: String
    public var name: String
    public var brand: String
    public var category: String
    public var productDescription: String
    public var imageURL: URL?
    public var price: Decimal
    public var currency: String
    public var size: String
    public var unit: String
    public var attributes: [String: String]
    public var availability: ProductAvailability
    public var matchScore: Double
    public var matchTier: ProductMatchTier
    public var kind: CandidateKind
    public var isExplicitlyIncompatible: Bool

    public init(
        id: UUID = UUID(),
        storeID: UUID,
        retailerName: String,
        name: String,
        brand: String,
        category: String,
        description: String,
        imageURL: URL? = nil,
        price: Decimal,
        currency: String = "USD",
        size: String,
        unit: String,
        attributes: [String: String] = [:],
        availability: ProductAvailability = .inStock,
        matchScore: Double = 0,
        matchTier: ProductMatchTier = .partial,
        kind: CandidateKind = .standard,
        isExplicitlyIncompatible: Bool = false
    ) {
        self.id = id
        self.storeID = storeID
        self.retailerName = retailerName
        self.name = name
        self.brand = brand
        self.category = category
        self.productDescription = description
        self.imageURL = imageURL
        self.price = price
        self.currency = currency
        self.size = size
        self.unit = unit
        self.attributes = attributes
        self.availability = availability
        self.matchScore = min(max(matchScore, 0), 1)
        self.matchTier = matchTier
        self.kind = kind
        self.isExplicitlyIncompatible = isExplicitlyIncompatible
    }

    private enum CodingKeys: String, CodingKey {
        case id, brand, category, price, currency, size, unit, attributes, availability
        case storeID = "store_id"
        case retailerName = "retailer_name"
        case name
        case productDescription = "description"
        case imageURL = "image_url"
        case matchScore = "match_score"
        case matchTier = "match_tier"
        case kind
        case isExplicitlyIncompatible = "is_explicitly_incompatible"
    }

    public var formattedPrice: String { CurrencyFormatter.string(amount: price, currency: currency) }
    public var formatSummary: String { [size, unit].filter { !$0.isEmpty }.joined(separator: " • ") }
}
