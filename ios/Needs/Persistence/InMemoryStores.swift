import Foundation

public actor InMemoryActiveListStore: ActiveListStore, OutboxStore {
    private var listsByUser: [UUID: ActiveList]
    private var outbox: [UUID: OutboxOperation]

    public init(seedLists: [ActiveList] = []) {
        self.listsByUser = Dictionary(
            seedLists.filter { $0.status == .open }.map { ($0.userID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.outbox = [:]
    }

    public func currentList(for userID: UUID) async throws -> ActiveList {
        if let list = listsByUser[userID], list.status == .open { return list }
        let list = ActiveList(userID: userID)
        listsByUser[userID] = list
        return list
    }

    public func add(
        product: ProductCandidate,
        for intent: NeedIntent,
        userID: UUID,
        quantity: Int = 1
    ) async throws -> ActiveList {
        var list = try await currentList(for: userID)
        let item = ActiveListItem(
            needID: intent.id,
            intent: intent,
            product: product,
            quantity: quantity
        )
        list.items.append(item)
        list.updatedAt = .now
        listsByUser[userID] = list
        return list
    }

    public func updateQuantity(itemID: UUID, quantity: Int, userID: UUID) async throws -> ActiveList {
        guard quantity > 0 else { return try await remove(itemID: itemID, userID: userID) }
        var list = try await currentList(for: userID)
        guard let index = list.items.firstIndex(where: { $0.id == itemID }) else { throw AppError.notFound }
        list.items[index].quantity = quantity
        list.items[index].updatedAt = .now
        list.updatedAt = .now
        listsByUser[userID] = list
        return list
    }

    public func replace(
        itemID: UUID,
        with product: ProductCandidate,
        for intent: NeedIntent,
        userID: UUID,
        quantity: Int
    ) async throws -> ActiveList {
        guard quantity > 0 else { throw AppError.invalidInput("Quantity must be at least one") }
        var list = try await currentList(for: userID)
        guard let index = list.items.firstIndex(where: { $0.id == itemID }) else { throw AppError.notFound }
        list.items[index].product = product
        list.items[index].intent = intent
        list.items[index].quantity = quantity
        list.items[index].updatedAt = .now
        list.updatedAt = .now
        listsByUser[userID] = list
        return list
    }

    public func remove(itemID: UUID, userID: UUID) async throws -> ActiveList {
        var list = try await currentList(for: userID)
        guard list.items.contains(where: { $0.id == itemID }) else { throw AppError.notFound }
        list.items.removeAll { $0.id == itemID }
        list.updatedAt = .now
        listsByUser[userID] = list
        return list
    }

    public func save(_ list: ActiveList) async throws {
        guard list.status == .open else { return }
        listsByUser[list.userID] = list
    }

    public func complete(
        listID: UUID,
        purchasedItemIDs: Set<UUID>,
        carriedForwardItemIDs: Set<UUID>
    ) async throws -> ActiveList {
        guard let entry = listsByUser.first(where: { $0.value.id == listID }) else { throw AppError.notFound }
        let userID = entry.key
        let oldList = entry.value
        guard purchasedItemIDs.isDisjoint(with: carriedForwardItemIDs) else {
            throw AppError.invalidInput("An item cannot be purchased and carried forward together.")
        }
        let knownIDs = Set(oldList.items.map(\.id))
        guard purchasedItemIDs.union(carriedForwardItemIDs).isSubset(of: knownIDs) else { throw AppError.notFound }

        let carried = oldList.items.filter { carriedForwardItemIDs.contains($0.id) }.map { item in
            ActiveListItem(
                needID: item.needID,
                intent: item.intent,
                product: item.product,
                quantity: item.quantity,
                carriedForward: true
            )
        }
        let newList = ActiveList(userID: userID, items: carried)
        listsByUser[userID] = newList
        return newList
    }

    public func enqueue(_ operation: OutboxOperation) async throws {
        guard !outbox.values.contains(where: { $0.idempotencyKey == operation.idempotencyKey }) else { return }
        outbox[operation.id] = operation
    }

    public func pending(for userID: UUID) async throws -> [OutboxOperation] {
        outbox.values
            .filter { $0.userID == userID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func markCompleted(id: UUID) async throws {
        outbox[id] = nil
    }

    public func incrementAttempt(id: UUID) async throws {
        guard var operation = outbox[id] else { throw AppError.notFound }
        operation.attemptCount += 1
        outbox[id] = operation
    }

    public func invalidate(userID: UUID, beforeMemoryEpoch: Int) async throws {
        outbox = outbox.filter { _, value in
            value.userID != userID || value.memoryEpoch >= beforeMemoryEpoch
        }
    }
}

public actor InMemoryOrderRepository: OrderRepository {
    private var storage: [UUID: Order]

    public init(seed: [Order] = []) {
        self.storage = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    }

    public func save(_ order: Order) async { storage[order.id] = order }

    public func order(id: UUID) async -> Order? { storage[id] }

    public func order(forListID listID: UUID) async -> Order? {
        storage.values.first { $0.listID == listID }
    }

    public func orders(for userID: UUID) async -> [Order] {
        storage.values
            .filter { $0.userID == userID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func updateStatus(id: UUID, status: OrderStatus) async throws -> Order {
        guard var order = storage[id] else { throw AppError.notFound }
        order.status = status
        order.updatedAt = .now
        storage[id] = order
        return order
    }
}
