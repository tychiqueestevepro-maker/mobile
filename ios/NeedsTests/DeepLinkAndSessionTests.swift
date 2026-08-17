import XCTest
@testable import Needs

final class DeepLinkAndSessionTests: XCTestCase {

    // MARK: - AppRoute deep link parsing

    func testCheckoutDeepLinkRequiresValidListID() {
        let listID = UUID(uuidString: "30000000-0000-0000-0000-000000000050")!
        let valid = AppRoute(deepLink: URL(string: "app://checkout?list_id=\(listID.uuidString)")!)
        XCTAssertEqual(valid, .checkout(listID: listID))

        XCTAssertNil(AppRoute(deepLink: URL(string: "app://checkout")!), "Missing list_id must reject")
        XCTAssertNil(AppRoute(deepLink: URL(string: "app://checkout?list_id=not-a-uuid")!), "Invalid UUID must reject")
    }

    func testOrderDeepLinkRequiresValidOrderID() {
        let orderID = UUID(uuidString: "30000000-0000-0000-0000-000000000051")!
        let valid = AppRoute(deepLink: URL(string: "app://order/\(orderID.uuidString)")!)
        XCTAssertEqual(valid, .order(id: orderID))

        XCTAssertNil(AppRoute(deepLink: URL(string: "app://order")!), "Missing path must reject")
        XCTAssertNil(AppRoute(deepLink: URL(string: "app://order/not-a-uuid")!), "Invalid UUID must reject")
    }

    func testKnownDeepLinkRoutesParseCorrectly() {
        XCTAssertEqual(AppRoute(deepLink: URL(string: "app://home")!), .home)
        XCTAssertEqual(AppRoute(deepLink: URL(string: "app://plus")!), .plus)
        XCTAssertEqual(AppRoute(deepLink: URL(string: "app://settings")!), .settings)
    }

    func testUnknownDeepLinkHostReturnsNil() {
        XCTAssertNil(AppRoute(deepLink: URL(string: "app://unknown")!))
        XCTAssertNil(AppRoute(deepLink: URL(string: "https://example.com")!), "Non-app scheme must reject")
    }

    // MARK: - AppRouter navigation

    @MainActor
    func testRouterNavigatesToHomeResetsPath() {
        let router = AppRouter(selectedTab: .orders, path: [.plus])
        router.navigate(to: .home)
        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertTrue(router.path.isEmpty, "Navigating to home must clear the navigation stack")
    }

    @MainActor
    func testRouterNavigatesToSettingsResetsPath() {
        let router = AppRouter(selectedTab: .home, path: [.plus])
        router.navigate(to: .settings)
        XCTAssertEqual(router.selectedTab, .settings)
        XCTAssertTrue(router.path.isEmpty)
    }

    @MainActor
    func testRouterPushesNonTabRoutes() {
        let router = AppRouter()
        let listID = UUID()
        router.navigate(to: .checkout(listID: listID))
        XCTAssertEqual(router.path.count, 1)
        XCTAssertEqual(router.path.first, .checkout(listID: listID))
    }

    @MainActor
    func testRouterHandleURLReturnsFalseForInvalidURL() {
        let router = AppRouter()
        let handled = router.handle(url: URL(string: "https://external.com/something")!)
        XCTAssertFalse(handled)
        XCTAssertTrue(router.path.isEmpty, "Invalid URLs must not affect the navigation stack")
    }

    @MainActor
    func testRouterPopToRootClearsPath() {
        let router = AppRouter(path: [.plus, .settings])
        router.popToRoot()
        XCTAssertTrue(router.path.isEmpty)
    }

    // MARK: - Session restore

    func testMockAuthRestoredSessionReturnsSavedSession() async throws {
        let sessionStore = InMemorySessionStore()
        let auth = MockAuthService(sessionStore: sessionStore)
        let session = try await auth.verifyEmailCode(email: "test@example.com", code: "123456")
        let restored = try await auth.restoreSession()
        XCTAssertEqual(restored?.profile.email, session.profile.email)
    }

    func testMockAuthRestoreReturnsNilWhenEmpty() async throws {
        let sessionStore = InMemorySessionStore()
        let auth = MockAuthService(sessionStore: sessionStore)
        let session = try await auth.restoreSession()
        XCTAssertNil(session, "Empty store must return nil session")
    }

    func testMockAuthSignOutClearsSession() async throws {
        let sessionStore = InMemorySessionStore()
        let auth = MockAuthService(sessionStore: sessionStore)
        _ = try await auth.verifyEmailCode(email: "test@example.com", code: "123456")
        try await auth.signOut()
        let after = try await auth.restoreSession()
        XCTAssertNil(after, "Sign-out must clear the session")
    }

    func testMockAuthRejectsInvalidEmailCode() async {
        let sessionStore = InMemorySessionStore()
        let auth = MockAuthService(sessionStore: sessionStore)
        try? await auth.sendEmailCode(to: "test@example.com")
        do {
            _ = try await auth.verifyEmailCode(email: "test@example.com", code: "wrong")
            XCTFail("Expected an error for wrong code")
        } catch let error as AppError {
            guard case .invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }
}
