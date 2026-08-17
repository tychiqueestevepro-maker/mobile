import XCTest

final class NeedsAccessibilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Dynamic Type

    func testWelcomeSupportsLargeDynamicType() {
        app.launchArguments = ["-UITesting", "-ResetState", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()

        XCTAssertTrue(app.staticTexts["onboarding.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["onboarding.continue"].isHittable)
    }

    // MARK: - Home screen accessibility labels

    func testHomeScreenAccessibilityLabelsPresent() {
        app.launchArguments = ["-UITesting", "-MockVoiceTranscript", "I need coffee", "-SkipOnboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 10),
                       "Home title must be reachable by accessibility identifier")
        XCTAssertTrue(app.textFields["home.input"].exists,
                       "Text input must have an accessibility identifier")
        XCTAssertTrue(app.buttons["home.microphone"].exists,
                       "Microphone button must be identifiable")

        let mic = app.buttons["home.microphone"]
        XCTAssertFalse(mic.label.isEmpty, "Microphone button must have an accessibility label for VoiceOver")
    }

    // MARK: - Candidate card accessibility

    func testCandidateCardsAreAccessible() {
        app.launchArguments = ["-UITesting", "-MockVoiceTranscript", "I need toothpaste", "-SkipOnboarding"]
        app.launch()
        submitRequest("I need toothpaste")

        let candidate = firstCandidate(in: app)
        XCTAssertTrue(candidate.waitForExistence(timeout: 15),
                       "Each candidate card must have an identifier starting with 'candidate.'")
        XCTAssertFalse(candidate.label.isEmpty,
                        "Candidate card must compose a descriptive accessibility label for VoiceOver")
    }

    private func firstCandidate(in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "candidate."))
            .firstMatch
    }

    // MARK: - Checkout bar announces item count

    func testCheckoutBarAnnouncesItemCountAndTotal() {
        app.launchArguments = ["-UITesting", "-MockVoiceTranscript", "I need coffee", "-SkipOnboarding"]
        app.launch()
        addFirstProduct(named: "I need coffee")

        let checkoutSummary = app.descendants(matching: .any)["home.checkout_summary"]
        XCTAssertTrue(checkoutSummary.waitForExistence(timeout: 10),
                       "Checkout summary must be reachable by VoiceOver")
        XCTAssertFalse(checkoutSummary.label.isEmpty,
                        "Checkout summary must announce item count and total")

        let checkoutButton = app.buttons["home.checkout"]
        XCTAssertTrue(checkoutButton.waitForExistence(timeout: 10),
                       "Checkout button must appear when items are on the list")
        XCTAssertTrue(checkoutButton.isHittable,
                       "Checkout button must be tappable")
    }

    // MARK: - Helpers

    private func completeOnboarding() {
        guard app.buttons["onboarding.continue"].waitForExistence(timeout: 10) else { return }
        app.buttons["onboarding.continue"].tap()

        let emailContinue = app.buttons["account.email.continue"]
        XCTAssertTrue(emailContinue.waitForExistence(timeout: 10))
        emailContinue.tap()
        XCTAssertTrue(app.textFields["account.code"].waitForExistence(timeout: 10))
        emailContinue.tap()

        XCTAssertTrue(app.buttons["address.continue"].waitForExistence(timeout: 10))
        app.buttons["address.continue"].tap()
        XCTAssertTrue(app.buttons["reminder.continue"].waitForExistence(timeout: 10))
        app.buttons["reminder.continue"].tap()
        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 10))
    }

    private func submitRequest(_ text: String) {
        let input = app.textFields["home.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText(text)
        
        let submitBtn = app.buttons["home.submit"]
        XCTAssertTrue(submitBtn.waitForExistence(timeout: 5))
        submitBtn.tap()
    }

    private func addFirstProduct(named request: String) {
        submitRequest(request)
        let candidate = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "candidate.")
        ).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        candidate.tap()
        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 10))
        sleep(2) // Wait for NavigationStack pop animation to complete
    }
}

