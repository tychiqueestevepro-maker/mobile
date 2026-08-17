import Foundation

/// Coalesces concurrent requests sharing a key and retains successful results.
/// This mirrors the server contract and keeps double taps harmless in mocks.
public actor IdempotencyRegistry<Value: Sendable> {
    private var tasks: [String: Task<Value, Error>] = [:]

    public init() {}

    public func perform(
        key: String,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let existing = tasks[key] {
            return try await existing.value
        }

        let task = Task { try await operation() }
        tasks[key] = task

        do {
            return try await task.value
        } catch {
            tasks[key] = nil
            throw error
        }
    }

    public func cachedValue(for key: String) async throws -> Value? {
        guard let task = tasks[key] else { return nil }
        return try await task.value
    }

    public func removeAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}
