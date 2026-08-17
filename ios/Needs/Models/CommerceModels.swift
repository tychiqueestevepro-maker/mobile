import Foundation

public enum CheckoutStatus: String, Codable, Hashable, Sendable {
    case created
    case processing
    case actionRequired = "action_required"
    case completed
    case expired
    case cancelled
}

public struct CheckoutSession: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let listID: UUID
    public var status: CheckoutStatus
    public var items: [ActiveListItem]
    public var subtotal: Decimal
    public var deliveryFee: Decimal
    public var serviceFee: Decimal
    public var total: Decimal
    public var currency: String
    public var unavailableItemIDs: [UUID]
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        listID: UUID,
        status: CheckoutStatus = .created,
        items: [ActiveListItem],
        subtotal: Decimal,
        deliveryFee: Decimal,
        serviceFee: Decimal,
        total: Decimal,
        currency: String = "USD",
        unavailableItemIDs: [UUID] = [],
        expiresAt: Date = .now.addingTimeInterval(15 * 60)
    ) {
        self.id = id
        self.listID = listID
        self.status = status
        self.items = items
        self.subtotal = subtotal
        self.deliveryFee = deliveryFee
        self.serviceFee = serviceFee
        self.total = total
        self.currency = currency
        self.unavailableItemIDs = unavailableItemIDs
        self.expiresAt = expiresAt
    }
}

public struct CartStrategy: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var retailerIDs: [UUID]
    public var items: [ActiveListItem]
    public var productsTotal: Decimal
    public var deliveryTotal: Decimal
    public var serviceFee: Decimal
    public var fragmentationFee: Decimal
    public var currency: String

    public init(
        id: UUID = UUID(),
        retailerIDs: [UUID],
        items: [ActiveListItem] = [],
        productsTotal: Decimal,
        deliveryTotal: Decimal,
        serviceFee: Decimal = 0,
        fragmentationFee: Decimal = 0,
        currency: String = "USD"
    ) {
        self.id = id
        self.retailerIDs = retailerIDs
        self.items = items
        self.productsTotal = productsTotal
        self.deliveryTotal = deliveryTotal
        self.serviceFee = serviceFee
        self.fragmentationFee = fragmentationFee
        self.currency = currency
    }

    public var storeCount: Int { Set(retailerIDs).count }
    public var total: Decimal { productsTotal + deliveryTotal + serviceFee + fragmentationFee }
}

public struct CartOptimizationRequest: Codable, Hashable, Sendable {
    public var strategies: [CartStrategy]
    public init(strategies: [CartStrategy]) { self.strategies = strategies }
}

public struct CartOptimizationResult: Codable, Hashable, Sendable {
    public let recommended: CartStrategy
    public let alternatives: [CartStrategy]
}

public enum PaymentStatus: String, Codable, Hashable, Sendable {
    case created
    case authorized
    case captured
    case failed
    case voided
    case refunded
}

public struct PaymentSession: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let checkoutID: UUID
    public var status: PaymentStatus
    public let amount: Decimal
    public let currency: String
    public let clientToken: String

    public init(id: UUID = UUID(), checkoutID: UUID, status: PaymentStatus = .created, amount: Decimal, currency: String, clientToken: String) {
        self.id = id
        self.checkoutID = checkoutID
        self.status = status
        self.amount = amount
        self.currency = currency
        self.clientToken = clientToken
    }
}

public struct PaymentAuthorizationPayload: Hashable, Sendable {
    public let paymentData: Data
    public let transactionIdentifier: String

    public init(paymentData: Data, transactionIdentifier: String) {
        self.paymentData = paymentData
        self.transactionIdentifier = transactionIdentifier
    }
}

public struct PaymentResult: Codable, Hashable, Sendable {
    public let paymentID: UUID
    public let status: PaymentStatus
    public let processedAt: Date
    public let orderID: UUID?
    public let deliveryID: UUID?

    public init(
        paymentID: UUID,
        status: PaymentStatus,
        processedAt: Date,
        orderID: UUID? = nil,
        deliveryID: UUID? = nil
    ) {
        self.paymentID = paymentID
        self.status = status
        self.processedAt = processedAt
        self.orderID = orderID
        self.deliveryID = deliveryID
    }
}

public enum RetailOrderStatus: String, Codable, Hashable, Sendable {
    case pending
    case confirmed
    case failed
    case cancelled
}

public struct RetailOrder: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let orderID: UUID
    public let retailerID: UUID
    public var status: RetailOrderStatus
    public let externalReference: String?

    public init(id: UUID = UUID(), orderID: UUID, retailerID: UUID, status: RetailOrderStatus, externalReference: String? = nil) {
        self.id = id
        self.orderID = orderID
        self.retailerID = retailerID
        self.status = status
        self.externalReference = externalReference
    }
}

public enum OrderStatus: String, Codable, Hashable, Sendable {
    case pending
    case confirmed
    case actionRequired = "action_required"
    case preparing
    case delivering
    case delivered
    case cancelled
    case failed
}

public struct OrderItem: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let productID: UUID
    public let retailerID: UUID
    public let name: String
    public let quantity: Int
    public let unitPrice: Decimal
    public let totalPrice: Decimal

    public init(id: UUID = UUID(), productID: UUID, retailerID: UUID, name: String, quantity: Int, unitPrice: Decimal) {
        self.id = id
        self.productID = productID
        self.retailerID = retailerID
        self.name = name
        self.quantity = max(1, quantity)
        self.unitPrice = unitPrice
        self.totalPrice = unitPrice * Decimal(max(1, quantity))
    }
}

public struct Order: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let userID: UUID
    public let listID: UUID?
    public let checkoutID: UUID?
    public var paymentID: UUID?
    public var status: OrderStatus
    public var items: [OrderItem]
    public var subtotal: Decimal
    public var deliveryFee: Decimal
    public var serviceFee: Decimal
    public var total: Decimal
    public var currency: String
    public var deliveryAddress: Address
    public var deliveryID: UUID?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        userID: UUID,
        listID: UUID? = nil,
        checkoutID: UUID? = nil,
        paymentID: UUID? = nil,
        status: OrderStatus = .pending,
        items: [OrderItem],
        subtotal: Decimal,
        deliveryFee: Decimal,
        serviceFee: Decimal,
        total: Decimal,
        currency: String = "USD",
        deliveryAddress: Address,
        deliveryID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.userID = userID
        self.listID = listID
        self.checkoutID = checkoutID
        self.paymentID = paymentID
        self.status = status
        self.items = items
        self.subtotal = subtotal
        self.deliveryFee = deliveryFee
        self.serviceFee = serviceFee
        self.total = total
        self.currency = currency
        self.deliveryAddress = deliveryAddress
        self.deliveryID = deliveryID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum DeliveryStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case confirmed
    case courierAssigned = "courier_assigned"
    case courierHeadingToPickup = "courier_heading_to_pickup"
    case pickedUp = "picked_up"
    case onTheWay = "on_the_way"
    case arriving
    case delivered
    case cancelled
    case failed
}

public struct DeliveryQuote: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let fee: Decimal
    public let currency: String
    public let estimatedPickupAt: Date
    public let estimatedDeliveryAt: Date
    public let expiresAt: Date

    public init(id: UUID = UUID(), fee: Decimal, currency: String = "USD", estimatedPickupAt: Date, estimatedDeliveryAt: Date, expiresAt: Date) {
        self.id = id
        self.fee = fee
        self.currency = currency
        self.estimatedPickupAt = estimatedPickupAt
        self.estimatedDeliveryAt = estimatedDeliveryAt
        self.expiresAt = expiresAt
    }
}

public struct Delivery: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let orderID: UUID
    public var status: DeliveryStatus
    public var estimatedArrival: Date?
    public var courierFirstName: String?
    public var vehicleDescription: String?
    public var externalReference: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        orderID: UUID,
        status: DeliveryStatus = .pending,
        estimatedArrival: Date? = nil,
        courierFirstName: String? = nil,
        vehicleDescription: String? = nil,
        externalReference: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.orderID = orderID
        self.status = status
        self.estimatedArrival = estimatedArrival
        self.courierFirstName = courierFirstName
        self.vehicleDescription = vehicleDescription
        self.externalReference = externalReference
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
