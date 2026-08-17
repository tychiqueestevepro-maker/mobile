import Foundation
import Observation

@MainActor
@Observable
final class NeedsAppModel {
    enum Phase {
        case launching
        case onboarding(OnboardingViewModel)
        case ready
    }

    private(set) var phase: Phase = .launching
    let router = AppRouter()
    private(set) var profile: UserProfile = .demo
    private(set) var address: Address = .demo
    private(set) var entitlements: Entitlements = .free
    private(set) var homeModel: HomeViewModel?
    private(set) var ordersModel: OrdersViewModel?
    private(set) var settingsModel: SettingsViewModel?

    let container: DependencyContainer
    private let defaults: UserDefaults
    private var pendingReplacement: ActiveListItem?
    private var pendingURL: URL?
    private var hasStarted = false
    private let addressKey = "needs.default-address.v1"

    init(container: DependencyContainer, defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
    }

    var isPlus: Bool { entitlements.tier == .plus }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        if ProcessInfo.processInfo.arguments.contains("-ResetState") {
            try? await container.authService.signOut()
            defaults.removeObject(forKey: addressKey)
        }

        do {
            if let session = try await container.authService.restoreSession() {
                configureReady(session: session, address: restoredAddress() ?? .demo)
                await refreshEntitlements()
                container.notificationService.registerForRemoteNotifications()
            } else {
                showOnboarding()
            }
        } catch {
            showOnboarding()
        }
    }

    func handle(url: URL) {
        guard case .ready = phase else {
            pendingURL = url
            return
        }
        guard let route = AppRoute(deepLink: url) else { return }
        Task { await resolveDeepLink(route) }
    }

    func register(deviceToken: Data) async {
        let bridge = APNsDeviceTokenBridge(registrationService: container.pushDeviceRegistrationService)
        try? await bridge.didRegister(deviceToken: deviceToken)
    }

    func candidateModel(for intent: NeedIntent) -> CandidateSelectionViewModel {
        CandidateSelectionViewModel(
            intent: intent,
            search: { [weak self] intent in
                guard let self else { throw AppError.unavailable("App unavailable") }
                let raw = try await self.container.productProvider.searchProducts(for: intent, limit: 12)
                let currentEntitlements = await self.container.entitlementService.currentEntitlements()
                let ranked = await self.container.preferenceService.rankCandidates(
                    raw,
                    for: intent,
                    userID: self.profile.id,
                    useLearnedPreferences: currentEntitlements.hasPreferredProductRanking
                )
                await self.container.analyticsService.track(
                    .productCandidatesViewed,
                    properties: ["category": intent.category, "count": String(min(ranked.count, 3))]
                )
                return Array(ranked.prefix(3))
            },
            select: { [weak self] intent, product in
                guard let self else { throw AppError.unavailable("App unavailable") }
                if let replaced = self.pendingReplacement, replaced.intent.id == intent.id {
                    _ = try await self.container.activeListStore.replace(
                        itemID: replaced.id,
                        with: product,
                        for: intent,
                        userID: self.profile.id,
                        quantity: intent.quantity
                    )
                    self.pendingReplacement = nil
                } else {
                    self.pendingReplacement = nil
                    _ = try await self.container.activeListStore.add(
                        product: product,
                        for: intent,
                        userID: self.profile.id,
                        quantity: intent.quantity
                    )
                }
                _ = try await self.container.preferenceService.recordSignal(
                    userID: self.profile.id,
                    product: product,
                    kind: .selection,
                    idempotencyKey: "selection:\(intent.id.uuidString):\(product.id.uuidString)",
                    expectedMemoryEpoch: nil
                )
                await self.container.analyticsService.track(.productSelected, properties: ["category": intent.category])
                await self.homeModel?.loadList()
            },
            reject: { [weak self] _, product in
                guard let self else { return }
                _ = try? await self.container.preferenceService.recordSignal(
                    userID: self.profile.id,
                    product: product,
                    kind: .rejection,
                    idempotencyKey: "rejection:\(UUID().uuidString)",
                    expectedMemoryEpoch: nil
                )
            },
            completed: { [weak self] in
                self?.router.popToRoot()
            }
        )
    }

    func checkoutModel(listID: UUID) -> CheckoutViewModel {
        CheckoutViewModel(
            listID: listID,
            userID: profile.id,
            address: address,
            entitlements: entitlements,
            usesLocalOrderSimulation: container.configuration.environment == .development,
            listStore: container.activeListStore,
            checkoutService: container.checkoutService,
            optimizer: container.cartOptimizationService,
            paymentService: container.paymentService,
            retailOrderProvider: container.retailOrderProvider,
            deliveryProvider: container.deliveryProvider,
            orderRepository: container.orderRepository,
            preferenceService: container.preferenceService,
            analytics: container.analyticsService,
            authorizePayment: { [weak self] checkout in
                guard let self else { throw AppError.unavailable("App unavailable") }
                if self.container.configuration.environment == .development {
                    return PaymentAuthorizationContext(
                        payload: PaymentAuthorizationPayload(
                            paymentData: Data("development-payment".utf8),
                            transactionIdentifier: UUID().uuidString
                        )
                    )
                }
                guard let merchantIdentifier = self.container.configuration.applePayMerchantIdentifier,
                      !merchantIdentifier.isEmpty else {
                    throw AppError.configurationMissing("Apple Pay merchant identifier")
                }
                return try await ApplePayAuthorizer().authorize(
                    checkout: checkout,
                    merchantIdentifier: merchantIdentifier
                )
            },
            completed: { [weak self] order in
                guard let self else { return }
                Task {
                    await self.homeModel?.loadList()
                    await self.ordersModel?.load()
                }
                self.router.path = [.order(id: order.id)]
            },
            serverOrderPending: { [weak self] orderID in
                guard let self else { return }
                Task {
                    await self.homeModel?.loadList()
                    await self.ordersModel?.load()
                }
                self.router.path = [.order(id: orderID)]
            }
        )
    }

    func trackingModel(orderID: UUID) -> TrackingViewModel {
        TrackingViewModel(
            orderID: orderID,
            repository: container.orderRepository,
            deliveryProvider: container.deliveryProvider,
            analytics: container.analyticsService
        )
    }

    func plusModel() -> PlusViewModel {
        PlusViewModel(subscriptionManager: container.subscriptionManager, analytics: container.analyticsService) { [weak self] in
            guard let self else { return }
            self.entitlements = self.container.subscriptionManager.entitlements
            self.router.popToRoot()
        }
    }

    private func showOnboarding() {
        let useDemoData = container.configuration.environment == .development
        phase = .onboarding(OnboardingViewModel(
            useDemoData: useDemoData,
            authService: container.authService,
            requestNotifications: { [weak self] in
                guard let self else { return false }
                let allowed = await self.container.notificationService.requestAuthorization()
                if allowed { self.container.notificationService.registerForRemoteNotifications() }
                return allowed
            },
            complete: { [weak self] draft in
                guard let self else { return }
                let address = Address(
                    street: draft.street,
                    apartment: draft.apartment.isEmpty ? nil : draft.apartment,
                    city: draft.city,
                    postalCode: draft.postalCode,
                    region: draft.region,
                    country: draft.country == "United States" ? "US" : draft.country
                )
                self.persist(address: address)
                let components = Calendar.current.dateComponents([.hour, .minute], from: draft.reminderTime)
                try await self.container.notificationService.updatePreferences(NotificationPreferences(
                    isDailyReminderEnabled: draft.reminderEnabled,
                    localHour: components.hour ?? 17,
                    localMinute: components.minute ?? 0,
                    timeZoneIdentifier: draft.timeZoneIdentifier
                ))
                self.configureReady(session: draft.session, address: address)
                await self.refreshEntitlements()
                await self.container.analyticsService.track(.onboardingCompleted, properties: [:])
            }
        ))
    }

    private func configureReady(session: UserSession, address: Address) {
        profile = session.profile
        self.address = address
        let speechService: any SpeechTranscriptionService
        if ProcessInfo.processInfo.arguments.contains("-UITesting") {
            speechService = container.speechTranscriptionService
            if let mock = speechService as? MockSpeechTranscriptionService,
               let transcript = launchArgumentValue(after: "-MockVoiceTranscript") {
                mock.simulateTranscript(transcript)
            }
        } else {
            speechService = NativeSpeechTranscriptionService()
        }
        let home = HomeViewModel(
            userID: profile.id,
            parser: container.intentParsingService,
            speech: speechService,
            listStore: container.activeListStore,
            preferenceService: container.preferenceService,
            analytics: container.analyticsService,
            router: router,
            beginReplacement: { [weak self] item in self?.pendingReplacement = item }
        )
        homeModel = home
        ordersModel = OrdersViewModel(userID: profile.id, repository: container.orderRepository, router: router)
        settingsModel = SettingsViewModel(
            profile: profile,
            address: address,
            preferenceService: container.preferenceService,
            outboxStore: container.outboxStore,
            notificationService: container.notificationService,
            subscriptionManager: container.subscriptionManager,
            authService: container.authService,
            router: router,
            signedOut: { [weak self] in
                guard let self else { return }
                self.homeModel = nil
                self.ordersModel = nil
                self.settingsModel = nil
                self.router.navigate(to: .home)
                self.showOnboarding()
            }
        )
        phase = .ready
        if let pendingURL {
            self.pendingURL = nil
            handle(url: pendingURL)
        }
    }

    private func persist(address: Address) {
        guard let data = try? NeedsJSON.encoder().encode(address) else { return }
        defaults.set(data, forKey: addressKey)
    }

    private func restoredAddress() -> Address? {
        guard let data = defaults.data(forKey: addressKey) else { return nil }
        return try? NeedsJSON.decoder().decode(Address.self, from: data)
    }

    private func refreshEntitlements() async {
        do {
            entitlements = try await container.entitlementService.refresh()
        } catch {
            entitlements = await container.entitlementService.currentEntitlements()
        }
    }

    private func launchArgumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func resolveDeepLink(_ route: AppRoute) async {
        switch route {
        case let .checkout(listID):
            if let list = try? await container.activeListStore.currentList(for: profile.id),
               list.id == listID,
               list.status == .open,
               !list.items.isEmpty {
                router.navigate(to: .checkout(listID: listID))
            } else if let order = await container.orderRepository.order(forListID: listID) {
                router.navigate(to: .order(id: order.id))
            } else {
                router.navigate(to: .home)
            }
        case let .order(id):
            if await container.orderRepository.order(id: id) != nil {
                router.navigate(to: route)
            } else {
                router.navigate(to: .home)
            }
        default:
            router.navigate(to: route)
        }
    }
}
