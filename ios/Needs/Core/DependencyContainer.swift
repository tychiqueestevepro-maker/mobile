import Foundation
import SwiftData

@MainActor
public final class DependencyContainer {
    public let configuration: PublicConfiguration
    public let authService: any AuthService
    public let intentParsingService: any IntentParsingService
    public let productProvider: any ProductProvider
    public let retailOrderProvider: any RetailOrderProvider
    public let deliveryProvider: any DeliveryProvider
    public let paymentService: any PaymentService
    public let checkoutService: any CheckoutService
    public let preferenceService: any PreferenceService
    public let cartOptimizationService: any CartOptimizationService
    public let entitlementService: any EntitlementService
    public let subscriptionManager: any SubscriptionManaging
    public let notificationService: any NotificationService
    public let pushDeviceRegistrationService: any PushDeviceRegistrationService
    public let addressService: any AddressService
    public let speechTranscriptionService: any SpeechTranscriptionService
    public let analyticsService: any AnalyticsService
    public let activeListStore: any ActiveListStore
    public let outboxStore: any OutboxStore
    public let orderRepository: any OrderRepository

    public init(
        configuration: PublicConfiguration,
        authService: any AuthService,
        intentParsingService: any IntentParsingService,
        productProvider: any ProductProvider,
        retailOrderProvider: any RetailOrderProvider,
        deliveryProvider: any DeliveryProvider,
        paymentService: any PaymentService,
        checkoutService: any CheckoutService,
        preferenceService: any PreferenceService,
        cartOptimizationService: any CartOptimizationService,
        entitlementService: any EntitlementService,
        subscriptionManager: any SubscriptionManaging,
        notificationService: any NotificationService,
        pushDeviceRegistrationService: any PushDeviceRegistrationService,
        addressService: any AddressService,
        speechTranscriptionService: any SpeechTranscriptionService,
        analyticsService: any AnalyticsService,
        activeListStore: any ActiveListStore,
        outboxStore: any OutboxStore,
        orderRepository: any OrderRepository
    ) {
        self.configuration = configuration
        self.authService = authService
        self.intentParsingService = intentParsingService
        self.productProvider = productProvider
        self.retailOrderProvider = retailOrderProvider
        self.deliveryProvider = deliveryProvider
        self.paymentService = paymentService
        self.checkoutService = checkoutService
        self.preferenceService = preferenceService
        self.cartOptimizationService = cartOptimizationService
        self.entitlementService = entitlementService
        self.subscriptionManager = subscriptionManager
        self.notificationService = notificationService
        self.pushDeviceRegistrationService = pushDeviceRegistrationService
        self.addressService = addressService
        self.speechTranscriptionService = speechTranscriptionService
        self.analyticsService = analyticsService
        self.activeListStore = activeListStore
        self.outboxStore = outboxStore
        self.orderRepository = orderRepository
    }

    public static func development(persistentStorage: Bool = true) -> DependencyContainer {
        let sessionStore: any SessionStore = persistentStorage ? KeychainSessionStore() : InMemorySessionStore()
        let listAndOutboxStore: any ActiveListAndOutboxStore

        if persistentStorage, let container = try? makeModelContainer() {
            listAndOutboxStore = SwiftDataActiveListStore(modelContainer: container)
        } else {
            listAndOutboxStore = InMemoryActiveListStore()
        }

        let entitlements = MockEntitlementService(tier: .free)
        let subscription = MockSubscriptionManager(tier: .free) { tier in
            await entitlements.setTier(tier)
        }
        let push = MockPushDeviceRegistrationService()

        return DependencyContainer(
            configuration: .development,
            authService: MockAuthService(sessionStore: sessionStore),
            intentParsingService: DeterministicIntentParsingService(),
            productProvider: MockProductProvider(),
            retailOrderProvider: MockRetailOrderProvider(),
            deliveryProvider: MockDeliveryProvider(),
            paymentService: MockPaymentService(),
            checkoutService: MockCheckoutService(),
            preferenceService: DeterministicPreferenceService(persistence: persistentStorage ? .userDefaults(suiteName: nil) : .ephemeral),
            cartOptimizationService: DeterministicCartOptimizationService(),
            entitlementService: entitlements,
            subscriptionManager: subscription,
            notificationService: MockNotificationService(),
            pushDeviceRegistrationService: push,
            addressService: InMemoryAddressService(),
            speechTranscriptionService: MockSpeechTranscriptionService(),
            analyticsService: NoOpAnalyticsService(),
            activeListStore: listAndOutboxStore,
            outboxStore: listAndOutboxStore,
            orderRepository: InMemoryOrderRepository()
        )
    }

    public static func make(
        configuration: PublicConfiguration,
        persistentStorage: Bool = true
    ) throws -> DependencyContainer {
        switch configuration.environment {
        case .development:
            return development(persistentStorage: persistentStorage)
        case .staging, .production:
            return try connected(configuration: configuration, persistentStorage: persistentStorage)
        }
    }

    public static func runtime(persistentStorage: Bool = true) throws -> DependencyContainer {
        try make(configuration: PublicConfiguration.runtime(), persistentStorage: persistentStorage)
    }

    public static func connected(
        configuration: PublicConfiguration,
        persistentStorage: Bool = true
    ) throws -> DependencyContainer {
        guard configuration.environment != .development else {
            return development(persistentStorage: persistentStorage)
        }
        let client = try SupabaseClientFactory.make(configuration: configuration)
        let api = BackendAPIClient(configuration: configuration, supabase: client)
        let sessionStore: any SessionStore = persistentStorage ? KeychainSessionStore() : InMemorySessionStore()
        let cacheAndOutbox: any ActiveListAndOutboxStore
        if persistentStorage, let modelContainer = try? makeModelContainer() {
            cacheAndOutbox = SwiftDataActiveListStore(modelContainer: modelContainer)
        } else {
            cacheAndOutbox = InMemoryActiveListStore()
        }
        let outboxSync = OutboxSyncService(store: cacheAndOutbox) { payload, operation in
            try await BackendOutboxSender.send(api: api, payload: payload, operation: operation)
        }
        let listStore = BackendActiveListStore(
            api: api,
            client: client,
            cache: cacheAndOutbox,
            outboxSync: outboxSync
        )
        let entitlementService = SupabaseEntitlementService(client: client)
        let subscriptionManager = SubscriptionManager(
            productIdentifier: configuration.storeKitProductIdentifier,
            appAccountTokenProvider: SupabaseAppAccountTokenProvider(client: client),
            syncService: BackendSubscriptionSyncService(api: api)
        ) { _ in
            _ = try? await entitlementService.refresh()
        }
        let push = BackendPushDeviceRegistrationService(api: api, environment: configuration.environment)

        return DependencyContainer(
            configuration: configuration,
            authService: SupabaseAuthService(client: client, backend: api, sessionStore: sessionStore),
            intentParsingService: BackendIntentParsingService(api: api),
            productProvider: BackendProductProvider(api: api),
            retailOrderProvider: SupabaseRetailOrderProvider(client: client),
            deliveryProvider: SupabaseDeliveryProvider(client: client),
            paymentService: BackendPaymentService(api: api),
            checkoutService: BackendCheckoutService(api: api),
            preferenceService: BackendPreferenceService(api: api, outboxSync: outboxSync),
            cartOptimizationService: DeterministicCartOptimizationService(),
            entitlementService: entitlementService,
            subscriptionManager: subscriptionManager,
            notificationService: BackendNotificationService(api: api),
            pushDeviceRegistrationService: push,
            addressService: SupabaseAddressService(client: client),
            speechTranscriptionService: NativeSpeechTranscriptionService(),
            analyticsService: NoOpAnalyticsService(),
            activeListStore: listStore,
            outboxStore: cacheAndOutbox,
            orderRepository: SupabaseOrderRepository(client: client)
        )
    }

    private static func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([CachedActiveListRecord.self, PendingOutboxRecord.self])
        let configuration = ModelConfiguration("NeedsCache", schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

/// Internal composition convenience for a store that owns both the durable
/// active-list snapshot and its synchronization outbox.
public protocol ActiveListAndOutboxStore: ActiveListStore, OutboxStore {}

extension InMemoryActiveListStore: ActiveListAndOutboxStore {}
extension SwiftDataActiveListStore: ActiveListAndOutboxStore {}
