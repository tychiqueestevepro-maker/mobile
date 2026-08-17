import Foundation

public protocol AuthService: Sendable {
    func restoreSession() async throws -> UserSession?
    func signInWithApple(request: AppleAuthRequest) async throws -> UserSession
    func sendEmailCode(to email: String) async throws
    func verifyEmailCode(email: String, code: String) async throws -> UserSession
    func signOut() async throws
    func deleteAccount() async throws
}

public extension AuthService {
    func signInWithApple(
        identityToken: Data,
        authorizationCode: Data?,
        rawNonce: String,
        givenName: String? = nil,
        familyName: String? = nil
    ) async throws -> UserSession {
        try await signInWithApple(request: AppleAuthRequest(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            rawNonce: rawNonce,
            givenName: givenName,
            familyName: familyName
        ))
    }
}

public protocol IntentParsingService: Sendable {
    func parse(_ text: String) async throws -> NeedIntent
}

public protocol ProductProvider: Sendable {
    func searchProducts(for intent: NeedIntent, limit: Int) async throws -> [ProductCandidate]
    func getProduct(id: UUID) async throws -> ProductCandidate?
    func checkAvailability(productIDs: [UUID]) async throws -> [UUID: ProductAvailability]
}

public protocol RetailOrderProvider: Sendable {
    func createRetailOrder(for order: Order, retailerID: UUID, idempotencyKey: String) async throws -> RetailOrder
    func cancelRetailOrder(id: UUID) async throws
}

public protocol DeliveryProvider: Sendable {
    func quote(for order: Order) async throws -> DeliveryQuote
    func createDelivery(for order: Order, quote: DeliveryQuote, idempotencyKey: String) async throws -> Delivery
    func cancelDelivery(id: UUID) async throws
    func delivery(id: UUID) async -> Delivery?
    func updates(for id: UUID) async -> AsyncStream<Delivery>
}

public protocol PaymentService: Sendable {
    func createPaymentSession(for checkout: CheckoutSession, idempotencyKey: String) async throws -> PaymentSession
    func confirmPayment(
        session: PaymentSession,
        authorization: PaymentAuthorizationPayload,
        idempotencyKey: String
    ) async throws -> PaymentResult
    func voidPayment(id: UUID, idempotencyKey: String) async throws -> PaymentResult
}

public protocol CheckoutService: Sendable {
    func createCheckout(
        for list: ActiveList,
        selectedItemIDs: Set<UUID>,
        strategy: CartStrategy?,
        idempotencyKey: String
    ) async throws -> CheckoutSession
    func revalidate(_ session: CheckoutSession, against list: ActiveList) async throws -> CheckoutSession
}

public extension CheckoutService {
    func createCheckout(
        for list: ActiveList,
        strategy: CartStrategy?,
        idempotencyKey: String
    ) async throws -> CheckoutSession {
        try await createCheckout(
            for: list,
            selectedItemIDs: Set(list.items.map(\.id)),
            strategy: strategy,
            idempotencyKey: idempotencyKey
        )
    }
}

public protocol PreferenceService: Sendable {
    @discardableResult
    func recordSignal(
        userID: UUID,
        product: ProductCandidate,
        kind: PreferenceSignalKind,
        idempotencyKey: String,
        expectedMemoryEpoch: Int?
    ) async throws -> LearnedPreferenceSummary

    func summary(for userID: UUID) async -> LearnedPreferenceSummary
    func rankCandidates(
        _ candidates: [ProductCandidate],
        for intent: NeedIntent,
        userID: UUID,
        useLearnedPreferences: Bool
    ) async -> [ProductCandidate]
    func removePreference(userID: UUID, preferenceID: String) async throws -> LearnedPreferenceSummary
    func resetProductMemory(userID: UUID) async throws -> LearnedPreferenceSummary
}

public protocol CartOptimizationService: Sendable {
    func optimize(_ request: CartOptimizationRequest) async throws -> CartOptimizationResult
}

public protocol EntitlementService: Sendable {
    func currentEntitlements() async -> Entitlements
    func refresh() async throws -> Entitlements
}

public protocol SubscriptionSyncService: Sendable {
    func syncVerifiedTransaction(jwsRepresentation: String, appAccountToken: UUID) async throws
}

public protocol AppAccountTokenProvider: Sendable {
    func appAccountToken() async throws -> UUID
}

@MainActor
public protocol SubscriptionManaging: AnyObject {
    var entitlements: Entitlements { get }
    var localizedPrice: String? { get }
    var isLoading: Bool { get }
    func loadProducts() async
    func purchasePlus() async throws
    func restorePurchases() async throws
}

@MainActor
public protocol NotificationService: AnyObject {
    var preferences: NotificationPreferences { get }
    func requestAuthorization() async -> Bool
    func registerForRemoteNotifications()
    func updatePreferences(_ preferences: NotificationPreferences) async throws
}

public protocol PushDeviceRegistrationService: Sendable {
    func register(deviceToken: Data) async throws
    func invalidate(deviceToken: Data) async
}

public protocol AddressService: Sendable {
    func defaultAddress(for userID: UUID) async throws -> Address?
    @discardableResult
    func saveDefaultAddress(
        _ address: Address,
        userID: UUID,
        recipientName: String
    ) async throws -> Address
}

@MainActor
public protocol SpeechTranscriptionService: AnyObject {
    var isListening: Bool { get }
    var transcript: String { get }
    func requestAuthorization() async -> Bool
    func startTranscribing() throws
    func stopTranscribing()
}

public protocol AnalyticsService: Sendable {
    func track(_ event: AnalyticsEvent, properties: [String: String]) async
}

public protocol ActiveListStore: Sendable {
    func currentList(for userID: UUID) async throws -> ActiveList
    @discardableResult
    func add(
        product: ProductCandidate,
        for intent: NeedIntent,
        userID: UUID,
        quantity: Int
    ) async throws -> ActiveList
    @discardableResult
    func updateQuantity(itemID: UUID, quantity: Int, userID: UUID) async throws -> ActiveList
    @discardableResult
    func replace(
        itemID: UUID,
        with product: ProductCandidate,
        for intent: NeedIntent,
        userID: UUID,
        quantity: Int
    ) async throws -> ActiveList
    @discardableResult
    func remove(itemID: UUID, userID: UUID) async throws -> ActiveList
    func save(_ list: ActiveList) async throws
    func complete(listID: UUID, purchasedItemIDs: Set<UUID>, carriedForwardItemIDs: Set<UUID>) async throws -> ActiveList
}

public protocol OutboxStore: Sendable {
    func enqueue(_ operation: OutboxOperation) async throws
    func pending(for userID: UUID) async throws -> [OutboxOperation]
    func markCompleted(id: UUID) async throws
    func incrementAttempt(id: UUID) async throws
    func invalidate(userID: UUID, beforeMemoryEpoch: Int) async throws
}

public protocol SessionStore: Sendable {
    func load() async throws -> UserSession?
    func save(_ session: UserSession) async throws
    func clear() async throws
}

public protocol OrderRepository: Sendable {
    func save(_ order: Order) async
    func order(id: UUID) async -> Order?
    func order(forListID listID: UUID) async -> Order?
    func orders(for userID: UUID) async -> [Order]
    func updateStatus(id: UUID, status: OrderStatus) async throws -> Order
}
