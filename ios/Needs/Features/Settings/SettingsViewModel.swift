import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    let profile: UserProfile
    var address: Address
    var notificationPreferences: NotificationPreferences
    var learnedPreferences: LoadableState<LearnedPreferenceSummary> = .idle
    var isSavingReminder = false
    var isResetting = false
    var errorMessage: String?

    private let userID: UUID
    private let preferenceService: any PreferenceService
    private let outboxStore: any OutboxStore
    private let notificationService: any NotificationService
    private let subscriptionManager: any SubscriptionManaging
    private let authService: any AuthService
    private let router: AppRouter
    private let signedOut: @MainActor () -> Void

    init(
        profile: UserProfile,
        address: Address,
        preferenceService: any PreferenceService,
        outboxStore: any OutboxStore,
        notificationService: any NotificationService,
        subscriptionManager: any SubscriptionManaging,
        authService: any AuthService,
        router: AppRouter,
        signedOut: @escaping @MainActor () -> Void
    ) {
        self.profile = profile
        self.address = address
        self.userID = profile.id
        self.preferenceService = preferenceService
        self.outboxStore = outboxStore
        self.notificationService = notificationService
        self.subscriptionManager = subscriptionManager
        self.authService = authService
        self.router = router
        self.signedOut = signedOut
        self.notificationPreferences = notificationService.preferences
    }

    var isPlus: Bool { subscriptionManager.entitlements.tier == .plus }

    var reminderTime: Date {
        get {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
            components.hour = notificationPreferences.localHour
            components.minute = notificationPreferences.localMinute
            return Calendar.current.date(from: components) ?? .now
        }
        set {
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            notificationPreferences.localHour = components.hour ?? 17
            notificationPreferences.localMinute = components.minute ?? 0
        }
    }

    func load() async {
        if learnedPreferences == .idle { learnedPreferences = .loading }
        let summary = await preferenceService.summary(for: userID)
        learnedPreferences = summary.entries.isEmpty && summary.acceptedPricesByCategory.isEmpty ? .empty : .loaded(summary)
        await subscriptionManager.loadProducts()
    }

    func saveReminder() async {
        guard !isSavingReminder else { return }
        isSavingReminder = true
        errorMessage = nil
        do {
            try await notificationService.updatePreferences(notificationPreferences)
        } catch {
            errorMessage = "We couldn't update your reminder."
        }
        isSavingReminder = false
    }

    func removePreference(_ preference: LearnedPreference) async {
        do {
            let summary = try await preferenceService.removePreference(userID: userID, preferenceID: preference.id)
            try await outboxStore.invalidate(userID: userID, beforeMemoryEpoch: summary.memoryEpoch)
            learnedPreferences = summary.entries.isEmpty && summary.acceptedPricesByCategory.isEmpty ? .empty : .loaded(summary)
        } catch {
            errorMessage = "We couldn't remove that preference."
        }
    }

    func resetPreferences() async {
        guard !isResetting else { return }
        isResetting = true
        do {
            let summary = try await preferenceService.resetProductMemory(userID: userID)
            try await outboxStore.invalidate(userID: userID, beforeMemoryEpoch: summary.memoryEpoch)
            learnedPreferences = .loaded(summary)
        } catch {
            errorMessage = "We couldn't reset learned preferences."
        }
        isResetting = false
    }

    func openPlus() { router.navigate(to: .plus) }

    func signOut() async {
        do {
            try await authService.signOut()
            signedOut()
        } catch {
            errorMessage = "We couldn't sign you out."
        }
    }

    func deleteAccount() async {
        do {
            let summary = try await preferenceService.resetProductMemory(userID: userID)
            try await outboxStore.invalidate(userID: userID, beforeMemoryEpoch: summary.memoryEpoch)
            try await authService.deleteAccount()
            signedOut()
        } catch {
            errorMessage = "We couldn't delete your account. Please try again."
        }
    }
}
