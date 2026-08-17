import XCTest
@testable import Needs

final class EntitlementStatusAndIdempotencyTests: XCTestCase {
    func testFreeAndPlusCapabilitiesAreCentralized() async {
        let service = MockEntitlementService(tier: .free)
        let free = await service.currentEntitlements()
        XCTAssertFalse(free.canOptimizeCart)
        XCTAssertFalse(free.hasPreferredProductRanking)
        XCTAssertFalse(free.hasReducedServiceFee)

        await service.setTier(.plus)
        let plus = await service.currentEntitlements()
        XCTAssertTrue(plus.canOptimizeCart)
        XCTAssertTrue(plus.hasPreferredProductRanking)
        XCTAssertTrue(plus.hasReducedServiceFee)
    }

    func testProviderStatusesMapToStableInternalStates() {
        XCTAssertEqual(DeliveryStatusMapper.normalizedStatus(from: "driver_assigned"), .courierAssigned)
        XCTAssertEqual(DeliveryStatusMapper.normalizedStatus(from: "en-route-to-dropoff"), .onTheWay)
        XCTAssertEqual(DeliveryStatusMapper.normalizedStatus(from: "complete"), .delivered)
        XCTAssertEqual(DeliveryStatusMapper.normalizedStatus(from: "unexpected_future_value"), .failed)
    }

    func testConcurrentDuplicateOperationsExecuteOnlyOnce() async throws {
        let registry = IdempotencyRegistry<Int>()
        let counter = TestCounter()

        async let first = registry.perform(key: "same-key") {
            try await Task.sleep(for: .milliseconds(30))
            return await counter.increment()
        }
        async let second = registry.perform(key: "same-key") {
            await counter.increment()
        }
        let (firstValue, secondValue) = try await (first, second)
        let calls = await counter.value

        XCTAssertEqual([firstValue, secondValue], [1, 1])
        XCTAssertEqual(calls, 1)
    }

    func testCheckoutIdempotencyReturnsSameSession() async throws {
        let storeID = UUID(uuidString: "30000000-0000-0000-0000-000000000025")!
        let userID = UUID(uuidString: "30000000-0000-0000-0000-000000000026")!
        let product = ProductCandidate(
            storeID: storeID,
            retailerName: "Store",
            name: "Product",
            brand: "Brand",
            category: "coffee",
            description: "Description",
            price: 10,
            size: "1",
            unit: "bag"
        )
        let intent = NeedIntent(category: "coffee", normalizedQuery: "coffee", confidence: 1)
        let list = ActiveList(userID: userID, items: [ActiveListItem(needID: intent.id, intent: intent, product: product)])
        let service = MockCheckoutService()

        let first = try await service.createCheckout(for: list, strategy: nil, idempotencyKey: "checkout-key")
        let second = try await service.createCheckout(for: list, strategy: nil, idempotencyKey: "checkout-key")
        XCTAssertEqual(first.id, second.id)
    }
}

private actor TestCounter {
    private(set) var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}
