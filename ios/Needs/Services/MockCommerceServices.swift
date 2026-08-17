import Foundation

public actor MockCheckoutService: CheckoutService {
    private let registry = IdempotencyRegistry<CheckoutSession>()
    private let defaultDeliveryFee: Decimal
    private let defaultServiceFee: Decimal

    public init(defaultDeliveryFee: Decimal = 6.99, defaultServiceFee: Decimal = 2) {
        self.defaultDeliveryFee = defaultDeliveryFee
        self.defaultServiceFee = defaultServiceFee
    }

    public func createCheckout(
        for list: ActiveList,
        selectedItemIDs: Set<UUID>,
        strategy: CartStrategy?,
        idempotencyKey: String
    ) async throws -> CheckoutSession {
        guard !list.items.isEmpty else { throw AppError.invalidInput("Cannot checkout an empty list") }
        let knownIDs = Set(list.items.map(\.id))
        guard !selectedItemIDs.isEmpty, selectedItemIDs.isSubset(of: knownIDs) else {
            throw AppError.invalidInput("Checkout selection is invalid")
        }
        let defaultDeliveryFee = self.defaultDeliveryFee
        let defaultServiceFee = self.defaultServiceFee
        let selectedItems = list.items.filter { selectedItemIDs.contains($0.id) }
        if let strategy, !strategy.items.isEmpty,
           Set(strategy.items.map(\.id)) != selectedItemIDs {
            throw AppError.invalidInput("Optimized strategy does not match selected items")
        }
        return try await registry.perform(key: idempotencyKey) {
            let unavailable = selectedItems.filter { !$0.product.availability.isPurchasable }.map(\.id)
            guard unavailable.isEmpty else { throw AppError.unavailable("One or more items became unavailable") }

            let subtotal = strategy?.productsTotal ?? selectedItems.reduce(Decimal.zero) { $0 + $1.lineTotal }
            let delivery = strategy?.deliveryTotal ?? defaultDeliveryFee
            let service = strategy?.serviceFee ?? defaultServiceFee
            return CheckoutSession(
                listID: list.id,
                items: strategy?.items.isEmpty == false ? strategy!.items : selectedItems,
                subtotal: subtotal,
                deliveryFee: delivery,
                serviceFee: service,
                total: subtotal + delivery + service,
                unavailableItemIDs: unavailable
            )
        }
    }

    public func revalidate(_ session: CheckoutSession, against list: ActiveList) async throws -> CheckoutSession {
        guard session.listID == list.id, session.expiresAt > .now else {
            throw AppError.conflict("Checkout is stale")
        }
        let selectedIDs = Set(session.items.map(\.id))
        let currentItems = list.items.filter { selectedIDs.contains($0.id) }
        guard currentItems.count == selectedIDs.count else { throw AppError.conflict("The list changed") }
        guard currentItems.allSatisfy({ $0.product.availability.isPurchasable }) else {
            throw AppError.unavailable("One or more items became unavailable")
        }
        let subtotal = currentItems.reduce(Decimal.zero) { $0 + $1.lineTotal }
        return CheckoutSession(
            id: session.id,
            listID: session.listID,
            status: session.status,
            items: currentItems,
            subtotal: subtotal,
            deliveryFee: session.deliveryFee,
            serviceFee: session.serviceFee,
            total: subtotal + session.deliveryFee + session.serviceFee,
            currency: session.currency,
            unavailableItemIDs: [],
            expiresAt: session.expiresAt
        )
    }
}

public actor MockPaymentService: PaymentService {
    private let sessionRegistry = IdempotencyRegistry<PaymentSession>()
    private let confirmationRegistry = IdempotencyRegistry<PaymentResult>()
    private let voidRegistry = IdempotencyRegistry<PaymentResult>()
    private var shouldFailNextConfirmation = false

    public init() {}

    public func setShouldFailNextConfirmation(_ shouldFail: Bool) {
        shouldFailNextConfirmation = shouldFail
    }

    public func createPaymentSession(for checkout: CheckoutSession, idempotencyKey: String) async throws -> PaymentSession {
        try await sessionRegistry.perform(key: idempotencyKey) {
            PaymentSession(
                checkoutID: checkout.id,
                amount: checkout.total,
                currency: checkout.currency,
                clientToken: "mock_\(UUID().uuidString)"
            )
        }
    }

    public func confirmPayment(
        session: PaymentSession,
        authorization: PaymentAuthorizationPayload,
        idempotencyKey: String
    ) async throws -> PaymentResult {
        let shouldFail = shouldFailNextConfirmation
        shouldFailNextConfirmation = false
        return try await confirmationRegistry.perform(key: idempotencyKey) {
            guard !authorization.paymentData.isEmpty else { throw AppError.paymentFailed }
            if shouldFail { throw AppError.paymentFailed }
            return PaymentResult(paymentID: session.id, status: .captured, processedAt: .now)
        }
    }

    public func voidPayment(id: UUID, idempotencyKey: String) async throws -> PaymentResult {
        try await voidRegistry.perform(key: idempotencyKey) {
            PaymentResult(paymentID: id, status: .voided, processedAt: .now)
        }
    }
}

public actor MockRetailOrderProvider: RetailOrderProvider {
    private let registry = IdempotencyRegistry<RetailOrder>()
    private var orders: [UUID: RetailOrder] = [:]
    private var retailerIDsThatFail: Set<UUID>

    public init(retailerIDsThatFail: Set<UUID> = []) {
        self.retailerIDsThatFail = retailerIDsThatFail
    }

    public func setFailure(retailerID: UUID, enabled: Bool) {
        if enabled { retailerIDsThatFail.insert(retailerID) }
        else { retailerIDsThatFail.remove(retailerID) }
    }

    public func createRetailOrder(for order: Order, retailerID: UUID, idempotencyKey: String) async throws -> RetailOrder {
        let shouldFail = retailerIDsThatFail.contains(retailerID)
        let retailOrder = try await registry.perform(key: idempotencyKey) {
            if shouldFail { throw AppError.unavailable("Retail order could not be created") }
            return RetailOrder(
                orderID: order.id,
                retailerID: retailerID,
                status: .confirmed,
                externalReference: "retail_\(UUID().uuidString)"
            )
        }
        orders[retailOrder.id] = retailOrder
        return retailOrder
    }

    public func cancelRetailOrder(id: UUID) async throws {
        guard var order = orders[id] else { throw AppError.notFound }
        order.status = .cancelled
        orders[id] = order
    }
}

public enum OrderFactory {
    public static func makeOrder(
        userID: UUID,
        checkout: CheckoutSession,
        address: Address
    ) -> Order {
        let items = checkout.items.map { item in
            OrderItem(
                productID: item.product.id,
                retailerID: item.product.storeID,
                name: item.product.name,
                quantity: item.quantity,
                unitPrice: item.product.price
            )
        }
        return Order(
            userID: userID,
            listID: checkout.listID,
            checkoutID: checkout.id,
            status: .confirmed,
            items: items,
            subtotal: checkout.subtotal,
            deliveryFee: checkout.deliveryFee,
            serviceFee: checkout.serviceFee,
            total: checkout.total,
            currency: checkout.currency,
            deliveryAddress: address
        )
    }
}
