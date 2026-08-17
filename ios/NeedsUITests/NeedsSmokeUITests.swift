import XCTest

final class NeedsSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-UITesting", "-ResetState",
            "-MockVoiceTranscript", "I need toothpaste"
        ]
        app.launch()
    }

    func testOnboardingReachesHomeWithDefaultReminder() {
        completeOnboarding()

        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["home.current_list"].exists)
        XCTAssertTrue(app.tabBars.buttons["Orders"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
    }

    func testNeedSelectionPersistsInCurrentListAndChecksOut() {
        completeOnboarding()
        addFirstProduct(named: "I need strong black trash bags")
        addToothpasteByVoice()

        XCTAssertTrue(app.otherElements["home.list.items"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["home.checkout"].waitForExistence(timeout: 2))
        app.buttons["home.checkout"].tap()

        XCTAssertTrue(app.buttons["checkout.pay"].waitForExistence(timeout: 3))
        app.buttons["checkout.pay"].tap()
        XCTAssertTrue(app.otherElements["tracking.timeline"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.staticTexts["Delivered"].waitForExistence(timeout: 18))
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
        app.tabBars.buttons["Orders"].tap()
        let deliveredOrder = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Delivered")
        ).firstMatch
        XCTAssertTrue(deliveredOrder.waitForExistence(timeout: 4))
    }

    func testReminderAndLearnedPreferenceControlsAreReachable() {
        completeOnboarding()
        addFirstProduct(named: "I need toothpaste")
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.switches["settings.reminder.toggle"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.datePickers["settings.reminder.time"].exists)
        XCTAssertTrue(app.buttons["settings.reminder.timezone"].exists)
        XCTAssertTrue(app.buttons["settings.preferences.reset"].waitForExistence(timeout: 3))
    }

    func testVoiceRequestShowsToothpasteAndAddsSensodyne() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-UITesting", "-ResetState",
            "-MockVoiceTranscript", "I need toothpaste"
        ]
        app.launch()
        completeOnboarding()

        addToothpasteByVoice()
        XCTAssertTrue(app.otherElements["home.list.items"].waitForExistence(timeout: 4))
    }

    private func completeOnboarding() {
        guard app.buttons["onboarding.continue"].waitForExistence(timeout: 2) else { return }
        app.buttons["onboarding.continue"].tap()

        let emailContinue = app.buttons["account.email.continue"]
        XCTAssertTrue(emailContinue.waitForExistence(timeout: 2))
        emailContinue.tap()
        XCTAssertTrue(app.textFields["account.code"].waitForExistence(timeout: 2))
        emailContinue.tap()

        XCTAssertTrue(app.buttons["address.continue"].waitForExistence(timeout: 2))
        app.buttons["address.continue"].tap()
        XCTAssertTrue(app.buttons["reminder.continue"].waitForExistence(timeout: 2))
        app.buttons["reminder.continue"].tap()
        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 4))
    }

    private func addFirstProduct(named request: String) {
        let input = app.textFields["home.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 2))
        input.tap()
        input.typeText(request)
        app.buttons["home.submit"].tap()

        let candidate = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "candidate.")
        ).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 4))
        candidate.tap()
        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 4))
    }

    private func addToothpasteByVoice() {
        let microphone = app.buttons["home.microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 2))
        microphone.tap()
        XCTAssertTrue(app.staticTexts["Listening..."].waitForExistence(timeout: 2))
        microphone.tap()

        let sensodyne = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Sensodyne")
        ).firstMatch
        XCTAssertTrue(sensodyne.waitForExistence(timeout: 4))
        sensodyne.tap()
        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 4))
    }
}
