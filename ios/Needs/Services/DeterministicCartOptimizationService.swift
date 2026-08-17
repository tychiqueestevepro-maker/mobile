import Foundation

public actor DeterministicCartOptimizationService: CartOptimizationService {
    public init() {}

    public func optimize(_ request: CartOptimizationRequest) async throws -> CartOptimizationResult {
        guard !request.strategies.isEmpty else {
            throw AppError.invalidInput("At least one cart strategy is required")
        }
        let currencies = Set(request.strategies.map(\.currency))
        guard currencies.count == 1 else { throw AppError.invalidInput("Strategies must share one currency") }

        let sorted = request.strategies.sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total < rhs.total }
            if lhs.storeCount != rhs.storeCount { return lhs.storeCount < rhs.storeCount }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return CartOptimizationResult(recommended: sorted[0], alternatives: Array(sorted.dropFirst()))
    }
}
