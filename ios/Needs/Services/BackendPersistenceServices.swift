import Foundation
import Supabase

enum BackendOutboxSender {
    private struct ConfirmInput: Encodable, Sendable {
        let candidate_id: UUID
        let quantity: Int
        let idempotency_key: String
        let memory_epoch: Int
    }
    private struct RejectInput: Encodable, Sendable {
        let candidate_id: UUID
        let idempotency_key: String
        let memory_epoch: Int
    }
    private struct UpdateInput: Encodable, Sendable {
        let item_id: UUID
        let action: String
        let quantity: Int?
        let idempotency_key: String
        let memory_epoch: Int
    }
    private struct ReplaceInput: Encodable, Sendable {
        let item_id: UUID
        let action: String
        let candidate_id: UUID
        let quantity: Int
        let idempotency_key: String
        let memory_epoch: Int
    }

    static func send(
        api: BackendAPIClient,
        payload: BackendOutboxPayload,
        operation: OutboxOperation
    ) async throws {
        switch payload {
        case let .confirmSelection(candidateID, quantity):
            _ = try await api.call("confirm-selection", body: ConfirmInput(
                candidate_id: candidateID,
                quantity: quantity,
                idempotency_key: operation.idempotencyKey,
                memory_epoch: operation.memoryEpoch
            ), as: IgnoredBackendResponse.self)
        case let .rejectCandidate(candidateID):
            _ = try await api.call("reject-candidate", body: RejectInput(
                candidate_id: candidateID,
                idempotency_key: operation.idempotencyKey,
                memory_epoch: operation.memoryEpoch
            ), as: IgnoredBackendResponse.self)
        case let .updateQuantity(itemID, quantity):
            _ = try await api.call("update-active-list", body: UpdateInput(
                item_id: itemID,
                action: "set_quantity",
                quantity: quantity,
                idempotency_key: operation.idempotencyKey,
                memory_epoch: operation.memoryEpoch
            ), as: IgnoredBackendResponse.self)
        case let .removeItem(itemID):
            _ = try await api.call("update-active-list", body: UpdateInput(
                item_id: itemID,
                action: "remove",
                quantity: nil,
                idempotency_key: operation.idempotencyKey,
                memory_epoch: operation.memoryEpoch
            ), as: IgnoredBackendResponse.self)
        case let .replaceItem(itemID, candidateID, quantity):
            _ = try await api.call("update-active-list", body: ReplaceInput(
                item_id: itemID,
                action: "replace",
                candidate_id: candidateID,
                quantity: quantity,
                idempotency_key: operation.idempotencyKey,
                memory_epoch: operation.memoryEpoch
            ), as: IgnoredBackendResponse.self)
        }
    }
}

public actor BackendActiveListStore: ActiveListStore {
    private struct EpochOutput: Decodable, Sendable { let memory_epoch: Int }
    private struct ConfirmInput: Encodable, Sendable {
        let candidate_id: UUID
        let quantity: Int
        let idempotency_key: String
        let memory_epoch: Int
    }
    private struct UpdateInput: Encodable, Sendable {
        let item_id: UUID
        let action: String
        let quantity: Int?
        let idempotency_key: String
        let memory_epoch: Int
    }
    private struct ReplaceInput: Encodable, Sendable {
        let item_id: UUID
        let action: String
        let candidate_id: UUID
        let quantity: Int
        let idempotency_key: String
        let memory_epoch: Int
    }
    private struct RetailerWire: Decodable, Sendable { let name: String }
    private struct SnapshotWire: Decodable, Sendable {
        let id: String
        let name: String
        let brand: String
        let category: String
        let format: String?
        let size_value: Decimal?
        let size_unit: String?
        let unit_count: Int?
        let attributes: [String: String]?
        let price_cents: Int
        let currency: String
        let retailer_id: String
    }
    private struct ItemWire: Decodable, Sendable {
        let id: UUID
        let need_id: UUID
        let candidate_id: UUID?
        let retailer_id: String
        let product_snapshot: SnapshotWire
        let quantity: Int
        let carry_forward: Bool
        let created_at: Date
        let updated_at: Date
        let retailers: RetailerWire?
    }
    private struct ListWire: Decodable, Sendable {
        let id: UUID
        let user_id: UUID
        let status: String
        let created_at: Date
        let updated_at: Date
        let active_list_items: [ItemWire]
    }

    private let api: BackendAPIClient
    private let client: SupabaseClient
    private let cache: any ActiveListStore
    private let outboxSync: OutboxSyncService
    private var lastKnownMemoryEpoch = 1

    public init(
        api: BackendAPIClient,
        client: SupabaseClient,
        cache: any ActiveListStore,
        outboxSync: OutboxSyncService
    ) {
        self.api = api
        self.client = client
        self.cache = cache
        self.outboxSync = outboxSync
    }

    public func currentList(for userID: UUID) async throws -> ActiveList {
        do {
            await outboxSync.replay(for: userID)
            let rows: [ListWire] = try await client.from("active_lists")
                .select("id,user_id,status,created_at,updated_at,active_list_items(id,need_id,candidate_id,retailer_id,product_snapshot,quantity,carry_forward,created_at,updated_at,retailers(name))")
                .eq("user_id", value: userID)
                .eq("status", value: "open")
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value
            guard let row = rows.first else {
                // A successful empty response is authoritative (for example,
                // immediately after the final item was purchased). Never
                // resurrect an older nonempty offline snapshot here.
                let empty = ActiveList(userID: userID)
                try? await cache.save(empty)
                return empty
            }
            let list = map(row)
            try? await cache.save(list)
            return list
        } catch {
            if let appError = error as? AppError, appError != .offline { throw appError }
            let cached = try await cache.currentList(for: userID)
            if !cached.items.isEmpty { return cached }
            throw AppError.offline
        }
    }

    public func add(
        product: ProductCandidate,
        for intent: NeedIntent,
        userID: UUID,
        quantity: Int
    ) async throws -> ActiveList {
        let key = "selection:\(intent.id.uuidString):\(product.id.uuidString)"
        do {
            let epoch = try await currentEpoch()
            _ = try await api.call("confirm-selection", body: ConfirmInput(
                candidate_id: product.id,
                quantity: quantity,
                idempotency_key: key,
                memory_epoch: epoch
            ), as: IgnoredBackendResponse.self)
            return try await currentList(for: userID)
        } catch let error as AppError where error == .offline {
            let list = try await cache.add(product: product, for: intent, userID: userID, quantity: quantity)
            try await outboxSync.enqueue(
                userID: userID,
                action: .confirmSelection,
                payload: .confirmSelection(candidateID: product.id, quantity: quantity),
                idempotencyKey: key,
                memoryEpoch: lastKnownMemoryEpoch
            )
            return list
        }
    }

    public func updateQuantity(itemID: UUID, quantity: Int, userID: UUID) async throws -> ActiveList {
        guard quantity > 0 else { return try await remove(itemID: itemID, userID: userID) }
        let key = "quantity:\(itemID.uuidString):\(quantity)"
        do {
            let epoch = try await currentEpoch()
            _ = try await api.call("update-active-list", body: UpdateInput(
                item_id: itemID,
                action: "set_quantity",
                quantity: quantity,
                idempotency_key: key,
                memory_epoch: epoch
            ), as: IgnoredBackendResponse.self)
            return try await currentList(for: userID)
        } catch let error as AppError where error == .offline {
            let list = try await cache.updateQuantity(itemID: itemID, quantity: quantity, userID: userID)
            try await outboxSync.enqueue(
                userID: userID,
                action: .updateQuantity,
                payload: .updateQuantity(itemID: itemID, quantity: quantity),
                idempotencyKey: key,
                memoryEpoch: lastKnownMemoryEpoch
            )
            return list
        }
    }

    public func replace(
        itemID: UUID,
        with product: ProductCandidate,
        for intent: NeedIntent,
        userID: UUID,
        quantity: Int
    ) async throws -> ActiveList {
        guard quantity > 0 else { throw AppError.invalidInput("Quantity must be at least one") }
        let key = "replacement:\(itemID.uuidString):\(product.id.uuidString)"
        do {
            let epoch = try await currentEpoch()
            _ = try await api.call("update-active-list", body: ReplaceInput(
                item_id: itemID,
                action: "replace",
                candidate_id: product.id,
                quantity: quantity,
                idempotency_key: key,
                memory_epoch: epoch
            ), as: IgnoredBackendResponse.self)
            return try await currentList(for: userID)
        } catch let error as AppError where error == .offline {
            let list = try await cache.replace(
                itemID: itemID,
                with: product,
                for: intent,
                userID: userID,
                quantity: quantity
            )
            try await outboxSync.enqueue(
                userID: userID,
                action: .replaceItem,
                payload: .replaceItem(itemID: itemID, candidateID: product.id, quantity: quantity),
                idempotencyKey: key,
                memoryEpoch: lastKnownMemoryEpoch
            )
            return list
        }
    }

    public func remove(itemID: UUID, userID: UUID) async throws -> ActiveList {
        let key = "removal:\(itemID.uuidString)"
        do {
            let epoch = try await currentEpoch()
            _ = try await api.call("update-active-list", body: UpdateInput(
                item_id: itemID,
                action: "remove",
                quantity: nil,
                idempotency_key: key,
                memory_epoch: epoch
            ), as: IgnoredBackendResponse.self)
            return try await currentList(for: userID)
        } catch let error as AppError where error == .offline {
            let list = try await cache.remove(itemID: itemID, userID: userID)
            try await outboxSync.enqueue(
                userID: userID,
                action: .removeItem,
                payload: .removeItem(itemID: itemID),
                idempotencyKey: key,
                memoryEpoch: lastKnownMemoryEpoch
            )
            return list
        }
    }

    public func save(_ list: ActiveList) async throws {
        // Arbitrary client snapshots are never authoritative in connected builds.
        try await cache.save(list)
    }

    public func complete(
        listID: UUID,
        purchasedItemIDs: Set<UUID>,
        carriedForwardItemIDs: Set<UUID>
    ) async throws -> ActiveList {
        guard let session = try? await client.auth.session else { throw AppError.authenticationRequired }
        // Payment completion moves purchased and remaining items transactionally.
        return try await currentList(for: session.user.id)
    }

    private func currentEpoch() async throws -> Int {
        let output: EpochOutput = try await api.call("preferences-summary", body: BackendEmptyBody())
        lastKnownMemoryEpoch = output.memory_epoch
        return output.memory_epoch
    }

    private func map(_ row: ListWire) -> ActiveList {
        let items = row.active_list_items.map { item -> ActiveListItem in
            let snapshot = item.product_snapshot
            let size = snapshot.size_value.map { NSDecimalNumber(decimal: $0).stringValue } ?? snapshot.format ?? ""
            let candidateID = item.candidate_id ?? UUID(uuidString: snapshot.id) ?? item.id
            let product = ProductCandidate(
                id: candidateID,
                storeID: UUID(uuidString: snapshot.retailer_id) ?? candidateID,
                retailerName: item.retailers?.name ?? "Local retailer",
                name: snapshot.name,
                brand: snapshot.brand,
                category: snapshot.category,
                description: snapshot.format ?? "",
                price: Decimal(snapshot.price_cents) / 100,
                currency: snapshot.currency,
                size: size,
                unit: snapshot.size_unit ?? ((snapshot.unit_count ?? 1) > 1 ? "count" : "item"),
                attributes: snapshot.attributes ?? [:],
                availability: .inStock,
                matchScore: 1,
                matchTier: .strong
            )
            let intent = NeedIntent(
                id: item.need_id,
                category: snapshot.category,
                normalizedQuery: snapshot.name,
                confidence: 1
            )
            return ActiveListItem(
                id: item.id,
                needID: item.need_id,
                intent: intent,
                product: product,
                quantity: item.quantity,
                carriedForward: item.carry_forward,
                createdAt: item.created_at,
                updatedAt: item.updated_at
            )
        }
        return ActiveList(
            id: row.id,
            userID: row.user_id,
            status: row.status == "open" ? .open : .purchased,
            items: items,
            createdAt: row.created_at,
            updatedAt: row.updated_at
        )
    }
}

public actor SupabaseOrderRepository: OrderRepository {
    private struct SnapshotWire: Decodable, Sendable {
        let name: String
    }
    private struct ItemWire: Decodable, Sendable {
        let id: UUID
        let product_id: String
        let retailer_id: String
        let product_snapshot: SnapshotWire
        let quantity: Int
        let unit_price_cents: Int
    }
    private struct DeliveryWire: Decodable, Sendable { let id: UUID }
    private struct Row: Decodable, Sendable {
        let id: UUID
        let user_id: UUID
        let list_id: UUID
        let checkout_session_id: UUID
        let state: String
        let subtotal_cents: Int
        let service_fee_cents: Int
        let delivery_fee_cents: Int
        let total_cents: Int
        let currency: String
        let placed_at: Date
        let updated_at: Date
        let order_items: [ItemWire]
        let deliveries: DeliveryWire?
    }

    private let client: SupabaseClient
    private let defaultAddress: Address
    private var localCache: [UUID: Order] = [:]

    public init(client: SupabaseClient, defaultAddress: Address = .demo) {
        self.client = client
        self.defaultAddress = defaultAddress
    }

    public func save(_ order: Order) async { localCache[order.id] = order }

    public func order(id: UUID) async -> Order? {
        if let remote = try? await fetch().first(where: { $0.id == id }) { return remote }
        return localCache[id]
    }

    public func order(forListID listID: UUID) async -> Order? {
        if let remote = try? await fetch().first(where: { $0.listID == listID }) { return remote }
        return localCache.values.first { $0.listID == listID }
    }

    public func orders(for userID: UUID) async -> [Order] {
        if let remote = try? await fetch(userID: userID) { return remote }
        return localCache.values.filter { $0.userID == userID }.sorted { $0.createdAt > $1.createdAt }
    }

    public func updateStatus(id: UUID, status: OrderStatus) async throws -> Order {
        throw AppError.conflict("Order state is server managed")
    }

    private func fetch(userID: UUID? = nil) async throws -> [Order] {
        let selection = "id,user_id,list_id,checkout_session_id,state,subtotal_cents,service_fee_cents,delivery_fee_cents,total_cents,currency,placed_at,updated_at,order_items(id,product_id,retailer_id,product_snapshot,quantity,unit_price_cents),deliveries(id)"
        let rows: [Row]
        if let userID {
            rows = try await client.from("orders")
                .select(selection)
                .eq("user_id", value: userID)
                .order("placed_at", ascending: false)
                .execute()
                .value
        } else {
            rows = try await client.from("orders")
                .select(selection)
                .order("placed_at", ascending: false)
                .execute()
                .value
        }
        return rows.map(map)
    }

    private func map(_ row: Row) -> Order {
        let items = row.order_items.map { item in
            OrderItem(
                id: item.id,
                productID: UUID(uuidString: item.product_id) ?? item.id,
                retailerID: UUID(uuidString: item.retailer_id) ?? item.id,
                name: item.product_snapshot.name,
                quantity: item.quantity,
                unitPrice: Decimal(item.unit_price_cents) / 100
            )
        }
        let status: OrderStatus
        switch row.state {
        case "placed", "retailer_confirmed": status = .confirmed
        case "in_delivery": status = .delivering
        case "delivered": status = .delivered
        case "partially_failed": status = .actionRequired
        case "cancelled", "refunded": status = .cancelled
        default: status = .pending
        }
        return Order(
            id: row.id,
            userID: row.user_id,
            listID: row.list_id,
            checkoutID: row.checkout_session_id,
            status: status,
            items: items,
            subtotal: Decimal(row.subtotal_cents) / 100,
            deliveryFee: Decimal(row.delivery_fee_cents) / 100,
            serviceFee: Decimal(row.service_fee_cents) / 100,
            total: Decimal(row.total_cents) / 100,
            currency: row.currency,
            deliveryAddress: defaultAddress,
            deliveryID: row.deliveries?.id,
            createdAt: row.placed_at,
            updatedAt: row.updated_at
        )
    }
}

public actor SupabaseDeliveryProvider: DeliveryProvider {
    private struct Row: Decodable, Sendable {
        let id: UUID
        let order_id: UUID
        let state: String
        let eta_end: Date?
        let courier_display_name: String?
        let external_reference: String?
        let created_at: Date
        let updated_at: Date
    }
    private let client: SupabaseClient

    public init(client: SupabaseClient) { self.client = client }
    public func quote(for order: Order) async throws -> DeliveryQuote { throw AppError.conflict("Delivery is arranged by checkout") }
    public func createDelivery(for order: Order, quote: DeliveryQuote, idempotencyKey: String) async throws -> Delivery { throw AppError.conflict("Delivery is arranged by checkout") }
    public func cancelDelivery(id: UUID) async throws { throw AppError.conflict("Contact support to cancel this delivery") }

    public func delivery(id: UUID) async -> Delivery? {
        let rows: [Row]? = try? await client.from("deliveries").select().eq("id", value: id).limit(1).execute().value
        guard let row = rows?.first else { return nil }
        return map(row)
    }

    public func updates(for id: UUID) async -> AsyncStream<Delivery> {
        let (stream, continuation) = AsyncStream<Delivery>.makeStream()
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let value = await self.delivery(id: id) else {
                    continuation.finish()
                    return
                }
                continuation.yield(value)
                if [.delivered, .cancelled, .failed].contains(value.status) {
                    continuation.finish()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            continuation.finish()
        }
        return stream
    }

    private func map(_ row: Row) -> Delivery {
        Delivery(
            id: row.id,
            orderID: row.order_id,
            status: DeliveryStatus(rawValue: row.state) ?? .failed,
            estimatedArrival: row.eta_end,
            courierFirstName: row.courier_display_name,
            externalReference: row.external_reference,
            createdAt: row.created_at,
            updatedAt: row.updated_at
        )
    }
}

public actor SupabaseRetailOrderProvider: RetailOrderProvider {
    private struct Row: Decodable, Sendable {
        let id: UUID
        let order_id: UUID
        let retailer_id: String
        let state: String
        let external_reference: String?
    }
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func createRetailOrder(for order: Order, retailerID: UUID, idempotencyKey: String) async throws -> RetailOrder {
        let rows: [Row] = try await client.from("retailer_orders")
            .select("id,order_id,retailer_id,state,external_reference")
            .eq("order_id", value: order.id)
            .eq("retailer_id", value: retailerID.uuidString)
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { throw AppError.conflict("Retail order is still being prepared") }
        return RetailOrder(
            id: row.id,
            orderID: row.order_id,
            retailerID: UUID(uuidString: row.retailer_id) ?? retailerID,
            status: RetailOrderStatus(rawValue: row.state) ?? .pending,
            externalReference: row.external_reference
        )
    }

    public func cancelRetailOrder(id: UUID) async throws {
        throw AppError.conflict("Contact support to cancel this order")
    }
}
