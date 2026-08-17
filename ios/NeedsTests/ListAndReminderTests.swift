import XCTest
@testable import Needs

final class ListAndReminderTests: XCTestCase {
    func testListPersistsUntilExplicitCompletionAndCarriesSelectedItemsForward() async throws {
        let userID = UUID(uuidString: "30000000-0000-0000-0000-000000000030")!
        let store = InMemoryActiveListStore()
        let intent = NeedIntent(category: "coffee", normalizedQuery: "coffee", confidence: 1)
        let product = ProductCandidate(
            storeID: MockCatalog.storeAID,
            retailerName: "Store",
            name: "Coffee",
            brand: "Brand",
            category: "coffee",
            description: "Coffee",
            price: 10,
            size: "12",
            unit: "oz"
        )

        let original = try await store.add(product: product, for: intent, userID: userID, quantity: 1)
        let reopened = try await store.currentList(for: userID)
        XCTAssertEqual(reopened.id, original.id, "The list must not reset based on the date")

        let itemID = try XCTUnwrap(original.items.first?.id)
        let next = try await store.complete(
            listID: original.id,
            purchasedItemIDs: [],
            carriedForwardItemIDs: [itemID]
        )
        XCTAssertNotEqual(next.id, original.id)
        XCTAssertEqual(next.items.count, 1)
        XCTAssertTrue(next.items[0].carriedForward)
    }

    func testReminderRequiresNonemptyOpenListAndNoCheckout() {
        let userID = UUID(uuidString: "30000000-0000-0000-0000-000000000031")!
        let base = DailyReminderContext(
            preferences: .init(),
            list: ActiveList(userID: userID),
            hasBlockingCheckout: false,
            hasActivePushDevice: true,
            wasAlreadySentForLocalDate: false
        )
        XCTAssertFalse(DailyReminderEligibilityEvaluator.shouldSend(base))

        let product = ProductCandidate(
            storeID: MockCatalog.storeAID,
            retailerName: "Store",
            name: "Coffee",
            brand: "Brand",
            category: "coffee",
            description: "Coffee",
            price: 10,
            size: "12",
            unit: "oz"
        )
        let intent = NeedIntent(category: "coffee", normalizedQuery: "coffee", confidence: 1)
        let item = ActiveListItem(needID: intent.id, intent: intent, product: product)
        let eligible = DailyReminderContext(
            preferences: .init(),
            list: ActiveList(userID: userID, items: [item]),
            hasBlockingCheckout: false,
            hasActivePushDevice: true,
            wasAlreadySentForLocalDate: false
        )
        XCTAssertTrue(DailyReminderEligibilityEvaluator.shouldSend(eligible))

        let checkoutStarted = DailyReminderContext(
            preferences: eligible.preferences,
            list: eligible.list,
            hasBlockingCheckout: true,
            hasActivePushDevice: true,
            wasAlreadySentForLocalDate: false
        )
        XCTAssertFalse(DailyReminderEligibilityEvaluator.shouldSend(checkoutStarted))
    }

    func testCheckoutDeepLinkRequiresListIdentifier() {
        let listID = UUID(uuidString: "30000000-0000-0000-0000-000000000032")!
        let route = AppRoute(deepLink: URL(string: "app://checkout?list_id=\(listID.uuidString)")!)
        XCTAssertEqual(route, .checkout(listID: listID))
        XCTAssertNil(AppRoute(deepLink: URL(string: "app://checkout")!))
    }
}
