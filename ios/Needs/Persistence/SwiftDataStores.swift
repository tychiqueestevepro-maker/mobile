import Foundation
import SwiftData

@Model
final class CachedActiveListRecord {
    @Attribute(.unique) var id: UUID
    var userID: UUID
    var payload: Data
    var statusValue: String
    var updatedAt: Date

    init(list: ActiveList, payload: Data) {
        self.id = list.id
        self.userID = list.userID
        self.payload = payload
        self.statusValue = list.status.rawValue
        self.updatedAt = list.updatedAt
    }
}

@Model
final class PendingOutboxRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var idempotencyKey: String
    var userID: UUID
    var memoryEpoch: Int
    var createdAt: Date
    var payload: Data

    init(operation: OutboxOperation, payload: Data) {
        self.id = operation.id
        self.idempotencyKey = operation.idempotencyKey
        self.userID = operation.userID
        self.memoryEpoch = operation.memoryEpoch
        self.createdAt = operation.createdAt
        self.payload = payload
    }
}

@ModelActor
public actor SwiftDataActiveListStore: ActiveListStore, OutboxStore {
    private func allListRecords() throws -> [CachedActiveListRecord] {
        try modelContext.fetch(FetchDescriptor<CachedActiveListRecord>())
    }

    private func decode(_ record: CachedActiveListRecord) throws -> ActiveList {
        do { return try NeedsJSON.decoder().decode(ActiveList.self, from: record.payload) }
        catch { throw AppError.underlying("Could not decode cached list: \(error)") }
    }

    private func persist(_ list: ActiveList) throws {
        let data: Data
        do { data = try NeedsJSON.encoder().encode(list) }
        catch { throw AppError.underlying("Could not encode cached list: \(error)") }

        if let existing = try allListRecords().first(where: { $0.id == list.id }) {
            existing.payload = data
            existing.statusValue = list.status.rawValue
            existing.updatedAt = list.updatedAt
        } else {
            modelContext.insert(CachedActiveListRecord(list: list, payload: data))
        }
        try modelContext.save()
    }

    public func currentList(for userID: UUID) async throws -> ActiveList {
        let records = try allListRecords()
            .filter { $0.userID == userID && $0.statusValue == ActiveListStatus.open.rawValue }
            .sorted { $0.updatedAt > $1.updatedAt }

        if let record = records.first { return try decode(record) }
        let list = ActiveList(userID: userID)
        try persist(list)
        return list
    }

    public func add(
        product: ProductCandidate,
        for intent: NeedIntent,
        userID: UUID,
        quantity: Int = 1
    ) async throws -> ActiveList {
        var list = try await currentList(for: userID)
        list.items.append(ActiveListItem(needID: intent.id, intent: intent, product: product, quantity: quantity))
        list.updatedAt = .now
        try persist(list)
        return list
    }

    public func updateQuantity(itemID: UUID, quantity: Int, userID: UUID) async throws -> ActiveList {
        guard quantity > 0 else { return try await remove(itemID: itemID, userID: userID) }
        var list = try await currentList(for: userID)
        guard let index = list.items.firstIndex(where: { $0.id == itemID }) else { throw AppError.notFound }
        list.items[index].quantity = quantity
        list.items[index].updatedAt = .now
        list.updatedAt = .now
        try persist(list)
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
        try persist(list)
        return list
    }

    public func remove(itemID: UUID, userID: UUID) async throws -> ActiveList {
        var list = try await currentList(for: userID)
        guard list.items.contains(where: { $0.id == itemID }) else { throw AppError.notFound }
        list.items.removeAll { $0.id == itemID }
        list.updatedAt = .now
        try persist(list)
        return list
    }

    public func save(_ list: ActiveList) async throws { try persist(list) }

    public func complete(
        listID: UUID,
        purchasedItemIDs: Set<UUID>,
        carriedForwardItemIDs: Set<UUID>
    ) async throws -> ActiveList {
        guard let record = try allListRecords().first(where: { $0.id == listID }) else { throw AppError.notFound }
        var completed = try decode(record)
        guard purchasedItemIDs.isDisjoint(with: carriedForwardItemIDs) else {
            throw AppError.invalidInput("An item cannot be purchased and carried forward together.")
        }
        let knownIDs = Set(completed.items.map(\.id))
        guard purchasedItemIDs.union(carriedForwardItemIDs).isSubset(of: knownIDs) else { throw AppError.notFound }

        completed.status = .purchased
        completed.updatedAt = .now
        try persist(completed)

        let carried = completed.items.filter { carriedForwardItemIDs.contains($0.id) }.map { item in
            ActiveListItem(
                needID: item.needID,
                intent: item.intent,
                product: item.product,
                quantity: item.quantity,
                carriedForward: true
            )
        }
        let newList = ActiveList(userID: completed.userID, items: carried)
        try persist(newList)
        return newList
    }

    public func enqueue(_ operation: OutboxOperation) async throws {
        let existing = try modelContext.fetch(FetchDescriptor<PendingOutboxRecord>())
        guard !existing.contains(where: { $0.idempotencyKey == operation.idempotencyKey }) else { return }
        let data = try NeedsJSON.encoder().encode(operation)
        modelContext.insert(PendingOutboxRecord(operation: operation, payload: data))
        try modelContext.save()
    }

    public func pending(for userID: UUID) async throws -> [OutboxOperation] {
        let records = try modelContext.fetch(FetchDescriptor<PendingOutboxRecord>())
        return try records
            .filter { $0.userID == userID }
            .map { try NeedsJSON.decoder().decode(OutboxOperation.self, from: $0.payload) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func markCompleted(id: UUID) async throws {
        let records = try modelContext.fetch(FetchDescriptor<PendingOutboxRecord>())
        guard let record = records.first(where: { $0.id == id }) else { return }
        modelContext.delete(record)
        try modelContext.save()
    }

    public func incrementAttempt(id: UUID) async throws {
        let records = try modelContext.fetch(FetchDescriptor<PendingOutboxRecord>())
        guard let record = records.first(where: { $0.id == id }) else { throw AppError.notFound }
        var operation = try NeedsJSON.decoder().decode(OutboxOperation.self, from: record.payload)
        operation.attemptCount += 1
        record.payload = try NeedsJSON.encoder().encode(operation)
        try modelContext.save()
    }

    public func invalidate(userID: UUID, beforeMemoryEpoch: Int) async throws {
        let records = try modelContext.fetch(FetchDescriptor<PendingOutboxRecord>())
        for record in records where record.userID == userID && record.memoryEpoch < beforeMemoryEpoch {
            modelContext.delete(record)
        }
        try modelContext.save()
    }
}
