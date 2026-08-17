import Foundation

public enum MembershipTier: String, Codable, Hashable, Sendable {
    case free
    case plus
}

public struct Entitlements: Codable, Hashable, Sendable {
    public let tier: MembershipTier
    public let canOptimizeCart: Bool
    public let hasPreferredProductRanking: Bool
    public let hasReducedServiceFee: Bool

    public static let free = Entitlements(
        tier: .free,
        canOptimizeCart: false,
        hasPreferredProductRanking: false,
        hasReducedServiceFee: false
    )

    public static let plus = Entitlements(
        tier: .plus,
        canOptimizeCart: true,
        hasPreferredProductRanking: true,
        hasReducedServiceFee: true
    )
}

public struct NotificationPreferences: Codable, Hashable, Sendable {
    public var isDailyReminderEnabled: Bool
    public var localHour: Int
    public var localMinute: Int
    public var timeZoneIdentifier: String

    public init(
        isDailyReminderEnabled: Bool = true,
        localHour: Int = 17,
        localMinute: Int = 0,
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.isDailyReminderEnabled = isDailyReminderEnabled
        self.localHour = min(max(localHour, 0), 23)
        self.localMinute = min(max(localMinute, 0), 59)
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public struct DailyReminderContext: Codable, Hashable, Sendable {
    public let preferences: NotificationPreferences
    public let list: ActiveList?
    public let hasBlockingCheckout: Bool
    public let hasActivePushDevice: Bool
    public let wasAlreadySentForLocalDate: Bool

    public init(
        preferences: NotificationPreferences,
        list: ActiveList?,
        hasBlockingCheckout: Bool,
        hasActivePushDevice: Bool,
        wasAlreadySentForLocalDate: Bool
    ) {
        self.preferences = preferences
        self.list = list
        self.hasBlockingCheckout = hasBlockingCheckout
        self.hasActivePushDevice = hasActivePushDevice
        self.wasAlreadySentForLocalDate = wasAlreadySentForLocalDate
    }
}

public enum AnalyticsEvent: String, Codable, CaseIterable, Sendable {
    case onboardingCompleted = "onboarding_completed"
    case needCreated = "need_created"
    case voiceNeedCreated = "voice_need_created"
    case productCandidatesViewed = "product_candidates_viewed"
    case productSelected = "product_selected"
    case itemRemoved = "item_removed"
    case checkoutStarted = "checkout_started"
    case checkoutCompleted = "checkout_completed"
    case plusViewed = "plus_viewed"
    case plusStarted = "plus_started"
    case orderCreated = "order_created"
    case deliveryCompleted = "delivery_completed"
}
