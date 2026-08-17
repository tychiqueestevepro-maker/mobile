import Foundation

public actor OutboxSyncService {
    public typealias Sender = @Sendable (BackendOutboxPayload, OutboxOperation) async throws -> Void

    private let store: any OutboxStore
    private let sender: Sender

    public init(store: any OutboxStore, sender: @escaping Sender) {
        self.store = store
        self.sender = sender
    }

    public func enqueue(
        userID: UUID,
        action: OutboxActionKind,
        payload: BackendOutboxPayload,
        idempotencyKey: String,
        memoryEpoch: Int
    ) async throws {
        let operation = OutboxOperation(
            userID: userID,
            action: action,
            payload: try NeedsJSON.encoder().encode(payload),
            idempotencyKey: idempotencyKey,
            memoryEpoch: memoryEpoch
        )
        try await store.enqueue(operation)
    }

    public func replay(for userID: UUID) async {
        guard let operations = try? await store.pending(for: userID) else { return }
        for operation in operations {
            do {
                let payload = try NeedsJSON.decoder().decode(BackendOutboxPayload.self, from: operation.payload)
                try await sender(payload, operation)
                try await store.markCompleted(id: operation.id)
            } catch let error as AppError where error == .offline {
                try? await store.incrementAttempt(id: operation.id)
                return
            } catch let error as AppError {
                if case .conflict = error {
                    // A reset increments the epoch; a stale operation must be
                    // dropped so it can never rebuild erased memory.
                    try? await store.markCompleted(id: operation.id)
                } else {
                    try? await store.incrementAttempt(id: operation.id)
                    return
                }
            } catch {
                try? await store.incrementAttempt(id: operation.id)
                return
            }
        }
    }
}
