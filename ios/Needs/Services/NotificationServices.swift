import Foundation
import Observation
@preconcurrency import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
public final class SystemNotificationService: NotificationService {
    public private(set) var preferences: NotificationPreferences
    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let storageKey = "needs.notification-preferences.v1"

    public init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let value = try? NeedsJSON.decoder().decode(NotificationPreferences.self, from: data) {
            self.preferences = value
        } else {
            self.preferences = NotificationPreferences()
        }
    }

    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    public func registerForRemoteNotifications() {
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    public func updatePreferences(_ preferences: NotificationPreferences) async throws {
        self.preferences = preferences
        defaults.set(try NeedsJSON.encoder().encode(preferences), forKey: storageKey)
    }
}

@MainActor
@Observable
public final class MockNotificationService: NotificationService {
    public private(set) var preferences: NotificationPreferences
    public var authorizationGranted: Bool
    public private(set) var didRequestRemoteRegistration = false

    public init(
        preferences: NotificationPreferences = .init(),
        authorizationGranted: Bool = true
    ) {
        self.preferences = preferences
        self.authorizationGranted = authorizationGranted
    }

    public func requestAuthorization() async -> Bool { authorizationGranted }
    public func registerForRemoteNotifications() { didRequestRemoteRegistration = true }
    public func updatePreferences(_ preferences: NotificationPreferences) async throws { self.preferences = preferences }
}

public actor MockPushDeviceRegistrationService: PushDeviceRegistrationService {
    private var activeTokens: Set<Data> = []
    public init() {}
    public func register(deviceToken: Data) async throws { activeTokens.insert(deviceToken) }
    public func invalidate(deviceToken: Data) async { activeTokens.remove(deviceToken) }
    public func registeredTokens() -> Set<Data> { activeTokens }
}

public actor APNsDeviceTokenBridge {
    private let registrationService: any PushDeviceRegistrationService

    public init(registrationService: any PushDeviceRegistrationService) {
        self.registrationService = registrationService
    }

    public func didRegister(deviceToken: Data) async throws {
        guard !deviceToken.isEmpty else { throw AppError.invalidInput("Empty device token") }
        try await registrationService.register(deviceToken: deviceToken)
    }

    public func didReceivePermanentRejection(for deviceToken: Data) async {
        await registrationService.invalidate(deviceToken: deviceToken)
    }
}

public enum DailyReminderEligibilityEvaluator {
    public static func shouldSend(_ context: DailyReminderContext) -> Bool {
        guard context.preferences.isDailyReminderEnabled,
              context.hasActivePushDevice,
              !context.hasBlockingCheckout,
              !context.wasAlreadySentForLocalDate,
              let list = context.list,
              list.status == .open,
              !list.items.isEmpty else { return false }
        return true
    }
}

public enum NotificationDeepLinkResolver {
    public static func route(from userInfo: [AnyHashable: Any]) -> AppRoute? {
        guard let raw = userInfo["deep_link"] as? String,
              let url = URL(string: raw) else { return nil }
        return AppRoute(deepLink: url)
    }
}
