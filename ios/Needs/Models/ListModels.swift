import Foundation

public enum ActiveListStatus: String, Codable, Hashable, Sendable {
    case open
    case checkingOut = "checking_out"
    case purchased
    case removed
}

public struct ActiveListItem: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let needID: UUID
    public var intent: NeedIntent
    public var product: ProductCandidate
    public var quantity: Int
    public var carriedForward: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        needID: UUID,
        intent: NeedIntent,
        product: ProductCandidate,
        quantity: Int = 1,
        carriedForward: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.needID = needID
        self.intent = intent
        self.product = product
        self.quantity = max(1, quantity)
        self.carriedForward = carriedForward
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var lineTotal: Decimal { product.price * Decimal(quantity) }
}

public struct ActiveList: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let userID: UUID
    public var status: ActiveListStatus
    public var items: [ActiveListItem]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        userID: UUID,
        status: ActiveListStatus = .open,
        items: [ActiveListItem] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.userID = userID
        self.status = status
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var itemCount: Int { items.reduce(0) { $0 + $1.quantity } }
    public var subtotal: Decimal { items.reduce(Decimal.zero) { $0 + $1.lineTotal } }
    public var formattedSubtotal: String {
        CurrencyFormatter.string(amount: subtotal, currency: items.first?.product.currency ?? "USD")
    }
}

public enum OutboxActionKind: String, Codable, Hashable, Sendable {
    case addItem = "add_item"
    case updateQuantity = "update_quantity"
    case removeItem = "remove_item"
    case replaceItem = "replace_item"
    case confirmSelection = "confirm_selection"
    case rejectCandidate = "reject_candidate"
}

public struct OutboxOperation: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let userID: UUID
    public let action: OutboxActionKind
    public let payload: Data
    public let idempotencyKey: String
    public let memoryEpoch: Int
    public let createdAt: Date
    public var attemptCount: Int

    public init(
        id: UUID = UUID(),
        userID: UUID,
        action: OutboxActionKind,
        payload: Data,
        idempotencyKey: String = UUID().uuidString,
        memoryEpoch: Int,
        createdAt: Date = .now,
        attemptCount: Int = 0
    ) {
        self.id = id
        self.userID = userID
        self.action = action
        self.payload = payload
        self.idempotencyKey = idempotencyKey
        self.memoryEpoch = memoryEpoch
        self.createdAt = createdAt
        self.attemptCount = attemptCount
    }
}

public enum BackendOutboxPayload: Codable, Hashable, Sendable {
    case confirmSelection(candidateID: UUID, quantity: Int)
    case rejectCandidate(candidateID: UUID)
    case updateQuantity(itemID: UUID, quantity: Int)
    case removeItem(itemID: UUID)
    case replaceItem(itemID: UUID, candidateID: UUID, quantity: Int)
}
