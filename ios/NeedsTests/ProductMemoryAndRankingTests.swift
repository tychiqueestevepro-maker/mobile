import XCTest
@testable import Needs

final class ProductMemoryAndRankingTests: XCTestCase {
    private let userID = UUID(uuidString: "30000000-0000-0000-0000-000000000010")!
    private let storeID = UUID(uuidString: "30000000-0000-0000-0000-000000000011")!

    func testCurrentIntentTierAlwaysWinsOverHistoricalFavorite() async throws {
        let service = DeterministicPreferenceService()
        let historical = candidate(name: "Historical", brand: "Favorite", score: 0.94, tier: .strong, price: 8)
        let exact = candidate(name: "Exact Current Match", brand: "New Brand", score: 0.81, tier: .exact, price: 10)
        let discovery = candidate(name: "Discovery", brand: "Different", score: 0.80, tier: .strong, price: 7)

        for index in 0..<12 {
            _ = try await service.recordSignal(
                userID: userID,
                product: historical,
                kind: .selection,
                idempotencyKey: "history-\(index)",
                expectedMemoryEpoch: 0
            )
        }
        let intent = NeedIntent(category: "coffee", normalizedQuery: "dark ground coffee", confidence: 1)
        let ranked = await service.rankCandidates(
            [historical, exact, discovery],
            for: intent,
            userID: userID,
            useLearnedPreferences: true
        )

        XCTAssertEqual(ranked.first?.id, exact.id, "Memory must never promote a lower intent tier")
        XCTAssertEqual(ranked.count, 3)
        XCTAssertEqual(ranked.last?.kind, .discovery)
        XCTAssertNotEqual(ranked.last?.brand, "Favorite")
    }

    func testFreeRankingIgnoresMemoryWhilePlusCanReorderCompatibleCandidates() async throws {
        let service = DeterministicPreferenceService()
        var baseWinner = candidate(name: "Base", brand: "Other", score: 0.90, tier: .strong, price: 9)
        let favorite = candidate(name: "Learned", brand: "Favorite", score: 0.86, tier: .strong, price: 10)
        var third = candidate(name: "Third", brand: "Third", score: 0.82, tier: .strong, price: 11)
        baseWinner.size = "16"
        baseWinner.attributes = ["roast": "light"]
        third.size = "10"
        third.attributes = ["roast": "medium"]
        for index in 0..<8 {
            _ = try await service.recordSignal(
                userID: userID,
                product: favorite,
                kind: .selection,
                idempotencyKey: "favorite-\(index)",
                expectedMemoryEpoch: 0
            )
        }
        let intent = NeedIntent(category: "coffee", normalizedQuery: "coffee", confidence: 1)

        let free = await service.rankCandidates([baseWinner, favorite, third], for: intent, userID: userID, useLearnedPreferences: false)
        let plus = await service.rankCandidates([baseWinner, favorite, third], for: intent, userID: userID, useLearnedPreferences: true)

        XCTAssertEqual(free.first?.id, baseWinner.id)
        XCTAssertEqual(plus.first?.id, favorite.id)
    }

    func testResetIncrementsEpochAndRejectsStaleOfflineWrite() async throws {
        let service = DeterministicPreferenceService()
        let product = candidate(name: "Coffee", brand: "Brand", score: 0.9, tier: .strong, price: 10)
        _ = try await service.recordSignal(
            userID: userID,
            product: product,
            kind: .selection,
            idempotencyKey: "initial",
            expectedMemoryEpoch: 0
        )

        let reset = try await service.resetProductMemory(userID: userID)
        XCTAssertEqual(reset.memoryEpoch, 1)
        XCTAssertTrue(reset.entries.isEmpty)

        do {
            _ = try await service.recordSignal(
                userID: userID,
                product: product,
                kind: .selection,
                idempotencyKey: "stale-outbox-operation",
                expectedMemoryEpoch: 0
            )
            XCTFail("Expected stale memory epoch rejection")
        } catch let error as AppError {
            guard case .conflict = error else { return XCTFail("Expected conflict, got \(error)") }
        }
    }

    func testPriceProfileAppearsAfterThreePositiveSignals() async throws {
        let service = DeterministicPreferenceService()
        for (index, price) in [Decimal(8), Decimal(10), Decimal(12)].enumerated() {
            let product = candidate(name: "Coffee \(index)", brand: "Brand", score: 0.9, tier: .strong, price: price)
            _ = try await service.recordSignal(
                userID: userID,
                product: product,
                kind: .selection,
                idempotencyKey: "price-\(index)",
                expectedMemoryEpoch: 0
            )
        }
        let summary = await service.summary(for: userID)
        XCTAssertEqual(summary.acceptedPricesByCategory["coffee"]?.median, 10)
        XCTAssertEqual(summary.acceptedPricesByCategory["coffee"]?.positiveSignalCount, 3)
    }

    private func candidate(
        name: String,
        brand: String,
        score: Double,
        tier: ProductMatchTier,
        price: Decimal
    ) -> ProductCandidate {
        ProductCandidate(
            storeID: storeID,
            retailerName: "Test Store",
            name: name,
            brand: brand,
            category: "coffee",
            description: "Test product",
            price: price,
            size: "12",
            unit: "oz",
            attributes: ["roast": "dark"],
            matchScore: score,
            matchTier: tier
        )
    }
}
