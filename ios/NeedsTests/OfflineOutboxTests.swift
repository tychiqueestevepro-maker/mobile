import XCTest
@testable import Needs

// Actor wrapper so Swift 6 allows mutation from concurrent closures.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

final class OfflineOutboxTests: XCTestCase {
    private let userID = UUID(uuidString: "30000000-0000-0000-0000-000000000040")!
    private let storeID = MockCatalog.storeAID

    // MARK: - Outbox enqueue and idempotent dedup

    func testOutboxEnqueuesAndDeduplicatesById() async throws {
        let store = InMemoryActiveListStore()
        let payload = BackendOutboxPayload.confirmSelection(candidateID: UUID(), quantity: 1)
        let data = try NeedsJSON.encoder().encode(payload)
        let operation = OutboxOperation(
            userID: userID,
            action: .confirmSelection,
            payload: data,
            idempotencyKey: "same-key",
            memoryEpoch: 0
        )

        try await store.enqueue(operation)
        try await store.enqueue(operation) // duplicate
        let pending = try await store.pending(for: userID)
        XCTAssertEqual(pending.count, 1, "Duplicate idempotency keys must not produce multiple entries")
    }

    // MARK: - Outbox replay drains successful operations

    func testOutboxReplayDrainsSuccessfulOperations() async throws {
        let store = InMemoryActiveListStore()
        let counter = Counter()
        let service = OutboxSyncService(store: store) { _, _ in
            await counter.increment()
        }

        let payload = BackendOutboxPayload.confirmSelection(candidateID: UUID(), quantity: 1)
        try await service.enqueue(
            userID: userID,
            action: .confirmSelection,
            payload: payload,
            idempotencyKey: "replay-ok-\(UUID())",
            memoryEpoch: 0
        )

        await service.replay(for: userID)
        let remaining = try await store.pending(for: userID)
        let sentCount = await counter.value
        XCTAssertEqual(sentCount, 1, "Sender must be called once")
        XCTAssertTrue(remaining.isEmpty, "Successful operations must be purged")
    }

    // MARK: - Outbox replay retries on offline error

    func testOutboxReplayRetriesWhenOffline() async throws {
        let store = InMemoryActiveListStore()
        let service = OutboxSyncService(store: store) { _, _ in
            throw AppError.offline
        }

        let payload = BackendOutboxPayload.confirmSelection(candidateID: UUID(), quantity: 1)
        try await service.enqueue(
            userID: userID,
            action: .confirmSelection,
            payload: payload,
            idempotencyKey: "replay-offline-\(UUID())",
            memoryEpoch: 0
        )

        await service.replay(for: userID)
        let remaining = try await store.pending(for: userID)
        XCTAssertEqual(remaining.count, 1, "Offline failure must not drain the operation")
        XCTAssertEqual(remaining.first?.attemptCount, 1, "Attempt counter must increment")
    }

    // MARK: - Stale epoch operations are dropped on conflict

    func testOutboxDropsStaleEpochOnConflict() async throws {
        let store = InMemoryActiveListStore()
        let service = OutboxSyncService(store: store) { _, _ in
            throw AppError.conflict("Stale memory epoch")
        }

        let payload = BackendOutboxPayload.confirmSelection(candidateID: UUID(), quantity: 1)
        try await service.enqueue(
            userID: userID,
            action: .confirmSelection,
            payload: payload,
            idempotencyKey: "replay-conflict-\(UUID())",
            memoryEpoch: 0
        )

        await service.replay(for: userID)
        let remaining = try await store.pending(for: userID)
        XCTAssertTrue(remaining.isEmpty, "Conflict from stale epoch must drop the operation, not retry it")
    }

    // MARK: - Store invalidation removes only stale-epoch operations

    func testInvalidateRemovesOnlyStaleEpochOperations() async throws {
        let store = InMemoryActiveListStore()
        let oldPayload = BackendOutboxPayload.confirmSelection(candidateID: UUID(), quantity: 1)
        let newPayload = BackendOutboxPayload.rejectCandidate(candidateID: UUID())
        let oldData = try NeedsJSON.encoder().encode(oldPayload)
        let newData = try NeedsJSON.encoder().encode(newPayload)

        let oldOp = OutboxOperation(userID: userID, action: .confirmSelection, payload: oldData, idempotencyKey: "old", memoryEpoch: 0)
        let newOp = OutboxOperation(userID: userID, action: .rejectCandidate, payload: newData, idempotencyKey: "new", memoryEpoch: 1)

        try await store.enqueue(oldOp)
        try await store.enqueue(newOp)
        try await store.invalidate(userID: userID, beforeMemoryEpoch: 1)

        let remaining = try await store.pending(for: userID)
        XCTAssertEqual(remaining.count, 1, "Only the newer epoch operation must survive")
        XCTAssertEqual(remaining.first?.idempotencyKey, "new")
    }
}
