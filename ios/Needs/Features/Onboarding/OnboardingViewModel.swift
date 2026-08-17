import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    enum Step: Int, CaseIterable {
        case welcome
        case account
        case address
        case reminder
    }

    var step: Step = .welcome
    var email = ""
    var verificationCode = ""
    var hasRequestedCode = false
    var street = ""
    var apartment = ""
    var city = ""
    var postalCode = ""
    var region = ""
    var country = "United States"
    var reminderEnabled = true
    var reminderTime: Date
    var isWorking = false
    var errorMessage: String?
    private(set) var session: UserSession?

    private let authService: any AuthService
    private let requestNotifications: @MainActor () async -> Bool
    private let complete: @MainActor (OnboardingDraft) async throws -> Void

    init(
        useDemoData: Bool,
        existingSession: UserSession? = nil,
        authService: any AuthService,
        requestNotifications: @escaping @MainActor () async -> Bool,
        complete: @escaping @MainActor (OnboardingDraft) async throws -> Void
    ) {
        self.authService = authService
        self.session = existingSession
        self.requestNotifications = requestNotifications
        self.complete = complete
        reminderTime = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: .now) ?? .now

        if useDemoData {
            email = "john@example.com"
            verificationCode = "123456"
            street = "123 Market Street"
            city = "San Francisco"
            postalCode = "94105"
            region = "CA"
        }
        if existingSession != nil {
            email = existingSession?.profile.email ?? email
            step = .address
        }
    }

    var addressIsValid: Bool {
        !street.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !postalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var progress: Double {
        Double(step.rawValue + 1) / Double(Step.allCases.count)
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    func sendCode() async {
        guard email.contains("@") else {
            errorMessage = "Enter a valid email address."
            return
        }
        isWorking = true
        errorMessage = nil
        do {
            try await authService.sendEmailCode(to: email)
            hasRequestedCode = true
        } catch {
            errorMessage = "We couldn't send a code right now. Please try again."
        }
        isWorking = false
    }

    func acceptEmailCode() async {
        guard !verificationCode.isEmpty || ProcessInfo.processInfo.arguments.contains("-UITesting") else {
            errorMessage = "Enter the code from your email."
            return
        }
        isWorking = true
        errorMessage = nil
        do {
            session = try await authService.verifyEmailCode(email: email, code: verificationCode)
            advance()
        } catch {
            errorMessage = "That code didn't work. Check it and try again."
        }
        isWorking = false
    }

    func acceptAppleCredential(
        identityToken: Data,
        authorizationCode: Data?,
        rawNonce: String,
        givenName: String?,
        familyName: String?
    ) async {
        isWorking = true
        errorMessage = nil
        do {
            session = try await authService.signInWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                rawNonce: rawNonce,
                givenName: givenName,
                familyName: familyName
            )
            advance()
        } catch {
            errorMessage = "Apple sign-in couldn't be completed. You can try again or use email."
        }
        isWorking = false
    }

    func finish() async {
        guard let session else {
            errorMessage = "Sign in before finishing setup."
            return
        }
        isWorking = true
        errorMessage = nil
        let notificationsAllowed = reminderEnabled ? await requestNotifications() : false
        let draft = OnboardingDraft(
            session: session,
            email: email,
            street: street,
            apartment: apartment,
            city: city,
            postalCode: postalCode,
            region: region,
            country: country,
            reminderEnabled: reminderEnabled && notificationsAllowed,
            reminderTime: reminderTime,
            timeZoneIdentifier: TimeZone.current.identifier
        )

        do {
            try await complete(draft)
        } catch {
            errorMessage = "We couldn't finish setting up your account. Please try again."
        }
        isWorking = false
    }
}

struct OnboardingDraft: Sendable {
    let session: UserSession
    let email: String
    let street: String
    let apartment: String
    let city: String
    let postalCode: String
    let region: String
    let country: String
    let reminderEnabled: Bool
    let reminderTime: Date
    let timeZoneIdentifier: String
}
