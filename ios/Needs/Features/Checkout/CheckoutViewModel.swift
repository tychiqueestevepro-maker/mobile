import Foundation
import Observation

@MainActor
@Observable
final class CheckoutViewModel {
    enum PaymentProgress: Equatable {
        case idle
        case revalidating
        case authorizing
        case placingOrder
        case completed
    }

    let listID: UUID
    let address: Address
    var state: LoadableState<CheckoutSession> = .idle
    private(set) var availableItems: [ActiveListItem] = []
    var selectedItemIDs: Set<UUID> = []
    var paymentProgress: PaymentProgress = .idle
    private(set) var isRepricing = false
    var errorMessage: String?

    private let userID: UUID
    private let entitlements: Entitlements
    private let usesLocalOrderSimulation: Bool
    private let listStore: any ActiveListStore
    private let checkoutService: any CheckoutService
    private let optimizer: any CartOptimizationService
    private let paymentService: any PaymentService
    private let retailOrderProvider: any RetailOrderProvider
    private let deliveryProvider: any DeliveryProvider
    private let orderRepository: any OrderRepository
    private let preferenceService: any PreferenceService
    private let analytics: any AnalyticsService
    private let authorizePayment: @MainActor (CheckoutSession) async throws -> PaymentAuthorizationContext
    private let completed: @MainActor (Order) -> Void
    private let serverOrderPending: @MainActor (UUID) -> Void

    init(
        listID: UUID,
        userID: UUID,
        address: Address,
        entitlements: Entitlements,
        usesLocalOrderSimulation: Bool,
        listStore: any ActiveListStore,
        checkoutService: any CheckoutService,
        optimizer: any CartOptimizationService,
        paymentService: any PaymentService,
        retailOrderProvider: any RetailOrderProvider,
        deliveryProvider: any DeliveryProvider,
        orderRepository: any OrderRepository,
        preferenceService: any PreferenceService,
        analytics: any AnalyticsService,
        authorizePayment: @escaping @MainActor (CheckoutSession) async throws -> PaymentAuthorizationContext,
        completed: @escaping @MainActor (Order) -> Void,
        serverOrderPending: @escaping @MainActor (UUID) -> Void
    ) {
        self.listID = listID
        self.userID = userID
        self.address = address
        self.entitlements = entitlements
        self.usesLocalOrderSimulation = usesLocalOrderSimulation
        self.listStore = listStore
        self.checkoutService = checkoutService
        self.optimizer = optimizer
        self.paymentService = paymentService
        self.retailOrderProvider = retailOrderProvider
        self.deliveryProvider = deliveryProvider
        self.orderRepository = orderRepository
        self.preferenceService = preferenceService
        self.analytics = analytics
        self.authorizePayment = authorizePayment
        self.completed = completed
        self.serverOrderPending = serverOrderPending
    }

    var session: CheckoutSession? {
        guard case let .loaded(session) = state else { return nil }
        return session
    }

    var isProcessing: Bool { paymentProgress != .idle && paymentProgress != .completed }
    var isBusy: Bool { isProcessing || isRepricing }

    func load() async {
        guard state == .idle || isFailure else { return }
        state = .loading
        errorMessage = nil
        do {
            let current = try await listStore.currentList(for: userID)
            guard current.id == listID, !current.items.isEmpty else {
                state = .empty
                return
            }

            selectedItemIDs = Set(current.items.map(\.id))
            availableItems = current.items
            let strategy = try await optimizedStrategy(for: current)
            let session = try await checkoutService.createCheckout(
                for: current,
                selectedItemIDs: selectedItemIDs,
                strategy: strategy,
                idempotencyKey: checkoutKey(for: selectedItemIDs)
            )
            state = .loaded(session)
            await analytics.track(.checkoutStarted, properties: ["list_id": current.id.uuidString])
        } catch let error as AppError where error == .offline {
            state = .offline(nil)
        } catch {
            state = .failed(message: "We couldn't prepare checkout right now.")
        }
    }

    func toggle(_ item: ActiveListItem) async {
        guard !isBusy else { return }
        if selectedItemIDs.contains(item.id) {
            guard selectedItemIDs.count > 1 else { return }
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
        await refreshSelectionPrice()
    }

    func pay() async {
        guard session != nil, !isBusy, !selectedItemIDs.isEmpty else { return }
        paymentProgress = .revalidating
        errorMessage = nil

        var authorization: PaymentAuthorizationContext?
        var paymentWasConfirmed = false
        var recoveryOrder: Order?

        do {
            // The selected subset and every amount are rebuilt by the checkout
            // service immediately before payment. UI totals are never trusted.
            let current = try await listStore.currentList(for: userID)
            guard current.id == listID else { throw AppError.conflict("The active list changed") }
            let purchasedItems = current.items.filter { selectedItemIDs.contains($0.id) }
            guard !purchasedItems.isEmpty, purchasedItems.count == selectedItemIDs.count else {
                throw AppError.conflict("The selected items changed")
            }

            let selectedList = ActiveList(
                id: current.id,
                userID: current.userID,
                status: current.status,
                items: purchasedItems,
                createdAt: current.createdAt,
                updatedAt: current.updatedAt
            )
            let strategy = try await optimizedStrategy(for: selectedList)
            let created = try await checkoutService.createCheckout(
                for: current,
                selectedItemIDs: selectedItemIDs,
                strategy: strategy,
                idempotencyKey: checkoutKey(for: selectedItemIDs)
            )
            let checkout = try await checkoutService.revalidate(created, against: current)
            guard checkout.unavailableItemIDs.isEmpty else { throw AppError.unavailable("An item changed availability") }
            state = .loaded(checkout)

            let paymentSession = try await paymentService.createPaymentSession(
                for: checkout,
                idempotencyKey: "payment-session:\(checkout.id.uuidString)"
            )
            paymentProgress = .authorizing
            let paymentAuthorization = try await authorizePayment(checkout)
            authorization = paymentAuthorization

            let paymentResult: PaymentResult
            do {
                paymentResult = try await paymentService.confirmPayment(
                    session: paymentSession,
                    authorization: paymentAuthorization.payload,
                    idempotencyKey: "payment-confirm:\(checkout.id.uuidString)"
                )
                guard paymentResult.status == .authorized || paymentResult.status == .captured else {
                    throw AppError.paymentFailed
                }
                paymentWasConfirmed = true
                paymentAuthorization.complete(success: true)
            } catch {
                paymentAuthorization.complete(success: false)
                throw error
            }

            paymentProgress = .placingOrder
            if let serverOrderID = paymentResult.orderID {
                // Connected confirmation owns retailer ordering and delivery.
                // Never replay those privileged operations from the phone.
                let purchasedIDs = Set(checkout.items.map(\.id))
                let carriedIDs = Set(current.items.map(\.id)).subtracting(purchasedIDs)
                _ = try? await listStore.complete(
                    listID: listID,
                    purchasedItemIDs: purchasedIDs,
                    carriedForwardItemIDs: carriedIDs
                )
                await analytics.track(.checkoutCompleted, properties: ["order_id": serverOrderID.uuidString])
                await analytics.track(.orderCreated, properties: ["order_id": serverOrderID.uuidString])
                paymentProgress = .completed
                if let serverOrder = await fetchServerOrder(id: serverOrderID) {
                    completed(serverOrder)
                } else {
                    serverOrderPending(serverOrderID)
                }
                return
            }

            guard usesLocalOrderSimulation else {
                throw AppError.conflict("Server confirmation did not return an order")
            }

            let orderItems = checkout.items.map {
                OrderItem(
                    productID: $0.product.id,
                    retailerID: $0.product.storeID,
                    name: $0.product.name,
                    quantity: $0.quantity,
                    unitPrice: $0.product.price
                )
            }
            var order = Order(
                userID: userID,
                listID: listID,
                checkoutID: checkout.id,
                paymentID: paymentResult.paymentID,
                status: .actionRequired,
                items: orderItems,
                subtotal: checkout.subtotal,
                deliveryFee: checkout.deliveryFee,
                serviceFee: checkout.serviceFee,
                total: checkout.total,
                currency: checkout.currency,
                deliveryAddress: address
            )
            recoveryOrder = order
            await orderRepository.save(order)

            var retailOrderSucceeded = true
            do {
                for retailerID in Set(orderItems.map(\.retailerID)) {
                    _ = try await retailOrderProvider.createRetailOrder(
                        for: order,
                        retailerID: retailerID,
                        idempotencyKey: "retail:\(order.id.uuidString):\(retailerID.uuidString)"
                    )
                }
            } catch {
                retailOrderSucceeded = false
                _ = try? await paymentService.voidPayment(
                    id: paymentResult.paymentID,
                    idempotencyKey: "payment-void:\(order.id.uuidString)"
                )
            }

            if retailOrderSucceeded {
                do {
                    order.status = .confirmed
                    let quote = try await deliveryProvider.quote(for: order)
                    let delivery = try await deliveryProvider.createDelivery(
                        for: order,
                        quote: quote,
                        idempotencyKey: "delivery:\(order.id.uuidString)"
                    )
                    order.deliveryID = delivery.id
                    order.status = .delivering
                } catch {
                    order.status = .actionRequired
                }
            } else {
                order.status = .actionRequired
            }
            order.updatedAt = .now
            recoveryOrder = order
            await orderRepository.save(order)

            let purchasedIDs = Set(checkout.items.map(\.id))
            let carriedIDs = Set(current.items.map(\.id)).subtracting(purchasedIDs)
            _ = try await listStore.complete(
                listID: listID,
                purchasedItemIDs: purchasedIDs,
                carriedForwardItemIDs: carriedIDs
            )
            for item in checkout.items {
                _ = try? await preferenceService.recordSignal(
                    userID: userID,
                    product: item.product,
                    kind: .purchase,
                    idempotencyKey: "purchase:\(order.id.uuidString):\(item.id.uuidString)",
                    expectedMemoryEpoch: nil
                )
            }
            await analytics.track(.checkoutCompleted, properties: ["order_id": order.id.uuidString])
            await analytics.track(.orderCreated, properties: ["order_id": order.id.uuidString])
            paymentProgress = .completed
            completed(order)
        } catch is CancellationError where !paymentWasConfirmed {
            authorization?.complete(success: false)
            paymentProgress = .idle
        } catch {
            authorization?.complete(success: false)
            paymentProgress = .idle
            if paymentWasConfirmed {
                if var order = recoveryOrder {
                    order.status = .actionRequired
                    order.updatedAt = .now
                    await orderRepository.save(order)
                    errorMessage = "Payment was authorized, but your order needs attention. Open the order for updates."
                    completed(order)
                } else {
                    errorMessage = "Payment was authorized. We're recovering your order and will keep it visible in Orders."
                }
            } else {
                errorMessage = "Your order wasn't placed. No payment was confirmed."
            }
        }
    }

    private func optimizedStrategy(for list: ActiveList) async throws -> CartStrategy? {
        guard entitlements.canOptimizeCart else { return nil }
        let retailerIDs = list.items.map(\.product.storeID)
        let storeCount = max(Set(retailerIDs).count, 1)
        let strategy = CartStrategy(
            retailerIDs: retailerIDs,
            items: list.items,
            productsTotal: list.subtotal,
            deliveryTotal: Decimal(storeCount * 6),
            serviceFee: entitlements.hasReducedServiceFee ? 0 : 2,
            fragmentationFee: Decimal(max(0, storeCount - 1) * 2)
        )
        return try await optimizer.optimize(.init(strategies: [strategy])).recommended
    }

    private func refreshSelectionPrice() async {
        let selection = selectedItemIDs
        isRepricing = true
        defer { isRepricing = false }
        do {
            let current = try await listStore.currentList(for: userID)
            guard current.id == listID else { throw AppError.conflict("The active list changed") }
            availableItems = current.items
            let selected = current.items.filter { selection.contains($0.id) }
            let selectedList = ActiveList(
                id: current.id,
                userID: current.userID,
                status: current.status,
                items: selected,
                createdAt: current.createdAt,
                updatedAt: current.updatedAt
            )
            let strategy = try await optimizedStrategy(for: selectedList)
            let refreshed = try await checkoutService.createCheckout(
                for: current,
                selectedItemIDs: selection,
                strategy: strategy,
                idempotencyKey: checkoutKey(for: selection)
            )
            guard selection == selectedItemIDs else { return }
            state = .loaded(refreshed)
        } catch {
            errorMessage = "We couldn't refresh the total. Please try again before paying."
        }
    }

    private func checkoutKey(for itemIDs: Set<UUID>) -> String {
        let selection = itemIDs.map(\.uuidString).sorted().joined(separator: ",")
        return "checkout:\(listID.uuidString):\(selection)"
    }

    private func fetchServerOrder(id: UUID) async -> Order? {
        for attempt in 0..<5 {
            if let order = await orderRepository.order(id: id) { return order }
            if attempt < 4 { try? await Task.sleep(for: .milliseconds(300)) }
        }
        return nil
    }

    private var isFailure: Bool {
        switch state {
        case .failed, .offline: true
        default: false
        }
    }
}
