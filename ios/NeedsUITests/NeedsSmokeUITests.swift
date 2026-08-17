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

        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["home.current_list"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Orders"].waitForExistence(timeout: 10))
        
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()
        
        let reminderToggle = app.switches["settings.reminder.toggle"]
        XCTAssertTrue(reminderToggle.waitForExistence(timeout: 10))
        XCTAssertEqual(reminderToggle.value as? String, "1", "Default reminder should be enabled after onboarding")
    }

    func testNeedSelectionPersistsInCurrentListAndChecksOut() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-UITesting", "-SkipOnboarding",
            "-MockVoiceTranscript", "I need toothpaste"
        ]
        app.launch()
        addFirstProduct(named: "I need strong black trash bags")
        addToothpasteByVoice()

        XCTAssertTrue(app.otherElements["home.list.items"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["home.checkout"].waitForExistence(timeout: 10))
        app.buttons["home.checkout"].tap()

        XCTAssertTrue(app.buttons["checkout.pay"].waitForExistence(timeout: 10))
        app.buttons["checkout.pay"].tap()
        XCTAssertTrue(app.otherElements["tracking.timeline"].waitForExistence(timeout: 10))

        XCTAssertTrue(app.staticTexts["Delivered"].waitForExistence(timeout: 10))
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
        app.tabBars.buttons["Orders"].tap()
        let deliveredOrder = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Delivered")
        ).firstMatch
        XCTAssertTrue(deliveredOrder.waitForExistence(timeout: 10))
    }

    func testReminderAndLearnedPreferenceControlsAreReachable() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-UITesting", "-SkipOnboarding",
            "-MockVoiceTranscript", "I need toothpaste"
        ]
        app.launch()
        addFirstProduct(named: "I need toothpaste")
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.switches["settings.reminder.toggle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.datePickers["settings.reminder.time"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.reminder.timezone"].waitForExistence(timeout: 5))
        
        let resetButton = app.buttons["settings.preferences.reset"]
        if !resetButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(resetButton.waitForExistence(timeout: 10))
    }

    func testVoiceRequestShowsToothpasteAndAddsSensodyne() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-UITesting", "-SkipOnboarding",
            "-MockVoiceTranscript", "I need toothpaste"
        ]
        app.launch()

        addToothpasteByVoice()
        XCTAssertTrue(app.otherElements["home.list.items"].waitForExistence(timeout: 10))
    }

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

    private func addFirstProduct(named request: String) {
        let input = app.textFields["home.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText(request)
        
        let submitBtn = app.buttons["home.submit"]
        XCTAssertTrue(submitBtn.waitForExistence(timeout: 5))
        submitBtn.tap()

        let candidate = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "candidate.")
        ).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        candidate.tap()
        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 10))
    }

    private func addToothpasteByVoice() {
        let microphone = app.buttons["home.microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 10))
        microphone.tap()
        XCTAssertTrue(app.staticTexts["home.listening_label"].waitForExistence(timeout: 10))
        microphone.tap()

        let sensodyne = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Sensodyne")
        ).firstMatch
        XCTAssertTrue(sensodyne.waitForExistence(timeout: 10))
        sensodyne.tap()
        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 10))
    }
}
