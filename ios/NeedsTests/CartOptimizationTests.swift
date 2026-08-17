import XCTest
@testable import Needs

final class CartOptimizationTests: XCTestCase {
    func testLowestFinalCostWinsEvenWhenProductsCostMore() async throws {
        let storeA = UUID(uuidString: "30000000-0000-0000-0000-000000000020")!
        let storeB = UUID(uuidString: "30000000-0000-0000-0000-000000000021")!
        let storeC = UUID(uuidString: "30000000-0000-0000-0000-000000000022")!
        let bundled = CartStrategy(retailerIDs: [storeA], productsTotal: 67, deliveryTotal: 7)
        let fragmented = CartStrategy(retailerIDs: [storeA, storeB, storeC], productsTotal: 62, deliveryTotal: 18)

        let result = try await DeterministicCartOptimizationService().optimize(
            CartOptimizationRequest(strategies: [fragmented, bundled])
        )

        XCTAssertEqual(result.recommended.id, bundled.id)
        XCTAssertEqual(result.recommended.total, 74)
        XCTAssertEqual(result.alternatives.first?.total, 80)
    }

    func testTieBreakPrefersFewerRetailersThenStableIdentifier() async throws {
        let storeA = UUID(uuidString: "30000000-0000-0000-0000-000000000023")!
        let storeB = UUID(uuidString: "30000000-0000-0000-0000-000000000024")!
        let oneStore = CartStrategy(retailerIDs: [storeA], productsTotal: 75, deliveryTotal: 5)
        let twoStores = CartStrategy(retailerIDs: [storeA, storeB], productsTotal: 70, deliveryTotal: 10)

        let result = try await DeterministicCartOptimizationService().optimize(.init(strategies: [twoStores, oneStore]))
        XCTAssertEqual(result.recommended.id, oneStore.id)
    }
}
