import Foundation
import Observation
import Supabase

struct BackendEmptyBody: Encodable, Sendable {}

private struct BackendAttributeWire: Codable, Sendable {
    let name: String
    let value: String
}

private struct BackendClarificationWire: Codable, Sendable {
    let question: String
    let options: [String]
}

private struct BackendIntentWire: Codable, Sendable {
    let category: String
    let normalized_query: String
    let attributes: [BackendAttributeWire]
    let quantity: Int
    let confidence: Double
    let clarification: BackendClarificationWire?
}

public actor BackendIntentParsingService: IntentParsingService {
    private struct Input: Encodable, Sendable { let text: String; let source: String }
    private struct Output: Decodable, Sendable {
        let need_id: UUID
        let intent: BackendIntentWire
    }
    private let api: BackendAPIClient

    public init(api: BackendAPIClient) { self.api = api }

    public func parse(_ text: String) async throws -> NeedIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.invalidInput("Need text is empty") }
        let output: Output = try await api.call("parse-need", body: Input(text: trimmed, source: "text"))
        return NeedIntent(
            id: output.need_id,
            category: output.intent.category,
            normalizedQuery: output.intent.normalized_query,
            attributes: Dictionary(uniqueKeysWithValues: output.intent.attributes.map { ($0.name, $0.value) }),
            quantity: output.intent.quantity,
            confidence: output.intent.confidence,
            clarification: output.intent.clarification.map {
                ClarificationQuestion(prompt: $0.question, options: $0.options, attributeKey: "choice")
            }
        )
    }
}

public actor BackendProductProvider: ProductProvider {
    private struct Input: Encodable, Sendable { let need_id: UUID }
    private struct Output: Decodable, Sendable {
        let candidates: [Candidate]
    }
    private struct Candidate: Decodable, Sendable {
        let id: UUID
        let product_id: String
        let retailer_id: String
        let category: String
        let name: String
        let brand: String
        let format: String?
        let size_value: Decimal?
        let size_unit: String?
        let unit_count: Int
        let attributes: [String: String]
        let price_cents: Int
        let currency: String
        let available: Bool
        let intent_score: Double
        let final_score: Double
        let result_role: String
        let reason: String
        let retailer_name: String
        let image_url: URL?
    }

    private let api: BackendAPIClient
    private var cache: [UUID: ProductCandidate] = [:]

    public init(api: BackendAPIClient) { self.api = api }

    public func searchProducts(for intent: NeedIntent, limit: Int = 3) async throws -> [ProductCandidate] {
        let output: Output = try await api.call("search-products", body: Input(need_id: intent.id))
        let mapped = output.candidates.map { wire -> ProductCandidate in
            let size = wire.size_value.map { NSDecimalNumber(decimal: $0).stringValue } ?? wire.format ?? ""
            let tier: ProductMatchTier = wire.intent_score >= 0.9 ? .exact : wire.intent_score >= 0.7 ? .strong : wire.intent_score >= 0.5 ? .partial : .fallback
            return ProductCandidate(
                id: wire.id,
                storeID: UUID(uuidString: wire.retailer_id) ?? wire.id,
                retailerName: wire.retailer_name,
                name: wire.name,
                brand: wire.brand,
                category: wire.category,
                description: wire.reason,
                imageURL: wire.image_url,
                price: Decimal(wire.price_cents) / 100,
                currency: wire.currency,
                size: size,
                unit: wire.size_unit ?? (wire.unit_count > 1 ? "count" : "item"),
                attributes: wire.attributes,
                availability: wire.available ? .inStock : .unavailable,
                matchScore: wire.final_score,
                matchTier: tier,
                kind: CandidateKind(rawValue: wire.result_role) ?? .standard
            )
        }
        for candidate in mapped { cache[candidate.id] = candidate }
        return Array(mapped.prefix(min(max(limit, 0), 3)))
    }

    public func getProduct(id: UUID) async throws -> ProductCandidate? { cache[id] }

    public func checkAvailability(productIDs: [UUID]) async throws -> [UUID: ProductAvailability] {
        Dictionary(uniqueKeysWithValues: productIDs.compactMap { id in cache[id].map { (id, $0.availability) } })
    }
}

private struct BackendPreferenceEntryWire: Decodable, Sendable {
    let id: UUID
    let category: String
    let dimension: String
    let value_key: String
    let score: Double
    let positive_count: Int
    let negative_count: Int
    let typical_price_cents: Decimal?
    let lower_price_cents: Decimal?
    let upper_price_cents: Decimal?
    let currency: String?
    let memory_epoch: Int
}

private struct BackendPreferencesOutput: Decodable, Sendable {
    let memory_epoch: Int
    let entries: [BackendPreferenceEntryWire]
}

private func backendPreferenceSummary(
    userID: UUID,
    output: BackendPreferencesOutput
) -> LearnedPreferenceSummary {
    var entries: [LearnedPreference] = []
    var prices: [String: AcceptedPriceProfile] = [:]
    for wire in output.entries {
        if wire.dimension.hasPrefix("price:"), let cents = wire.typical_price_cents {
            let amount = cents / 100
            prices[wire.category] = AcceptedPriceProfile(
                currency: wire.currency ?? "USD",
                median: amount,
                lowerBound: (wire.lower_price_cents ?? cents) / 100,
                upperBound: (wire.upper_price_cents ?? cents) / 100,
                positiveSignalCount: wire.positive_count
            )
            continue
        }
        let dimension: PreferenceDimension
        let key: String
        if wire.dimension == "brand" { dimension = .brand; key = "brand" }
        else if wire.dimension == "size" { dimension = .size; key = "size" }
        else { dimension = .attribute; key = wire.dimension.split(separator: ":", maxSplits: 1).last.map(String.init) ?? wire.dimension }
        entries.append(LearnedPreference(
            category: wire.category,
            dimension: dimension,
            key: key,
            value: wire.value_key,
            score: wire.score,
            signalCount: wire.positive_count + wire.negative_count
        ))
    }
    return LearnedPreferenceSummary(
        userID: userID,
        memoryEpoch: output.memory_epoch,
        entries: entries,
        acceptedPricesByCategory: prices
    )
}

public actor BackendPreferenceService: PreferenceService {
    private struct ConfirmInput: Encodable, Sendable {
        let candidate_id: UUID
        let quantity: Int
        let idempotency_key: String
        let memory_epoch: Int
    }
    private struct RejectInput: Encodable, Sendable {
        let candidate_id: UUID
        let idempotency_key: String
        let memory_epoch: Int
    }
    private struct RemoveInput: Encodable, Sendable {
        let category: String
        let dimension: String
        let value_key: String
        let memory_epoch: Int
    }
    private struct ResetInput: Encodable, Sendable { let memory_epoch: Int }

    private let api: BackendAPIClient
    private let outboxSync: OutboxSyncService
    private var removalDescriptors: [String: BackendPreferenceEntryWire] = [:]
    private var lastKnownMemoryEpoch = 1

    public init(api: BackendAPIClient, outboxSync: OutboxSyncService) {
        self.api = api
        self.outboxSync = outboxSync
    }

    public func recordSignal(
        userID: UUID,
        product: ProductCandidate,
        kind: PreferenceSignalKind,
        idempotencyKey: String,
        expectedMemoryEpoch: Int?
    ) async throws -> LearnedPreferenceSummary {
        let current = await summary(for: userID)
        let epoch = max(1, expectedMemoryEpoch ?? current.memoryEpoch)
        do {
            switch kind {
            case .selection:
                _ = try await api.call("confirm-selection", body: ConfirmInput(
                    candidate_id: product.id,
                    quantity: 1,
                    idempotency_key: idempotencyKey,
                    memory_epoch: epoch
                ), as: IgnoredBackendResponse.self)
            case .rejection:
                _ = try await api.call("reject-candidate", body: RejectInput(
                    candidate_id: product.id,
                    idempotency_key: idempotencyKey,
                    memory_epoch: epoch
                ), as: IgnoredBackendResponse.self)
            case .purchase, .removal:
                // These signals are written transactionally by payment/list endpoints.
                break
            }
        } catch let error as AppError where error == .offline {
            switch kind {
            case .selection:
                try await outboxSync.enqueue(
                    userID: userID,
                    action: .confirmSelection,
                    payload: .confirmSelection(candidateID: product.id, quantity: 1),
                    idempotencyKey: idempotencyKey,
                    memoryEpoch: epoch
                )
            case .rejection:
                try await outboxSync.enqueue(
                    userID: userID,
                    action: .rejectCandidate,
                    payload: .rejectCandidate(candidateID: product.id),
                    idempotencyKey: idempotencyKey,
                    memoryEpoch: epoch
                )
            case .purchase, .removal:
                break
            }
            return current
        }
        return await summary(for: userID)
    }

    public func summary(for userID: UUID) async -> LearnedPreferenceSummary {
        do {
            let output: BackendPreferencesOutput = try await api.call("preferences-summary", body: BackendEmptyBody())
            lastKnownMemoryEpoch = output.memory_epoch
            removalDescriptors = Dictionary(uniqueKeysWithValues: output.entries.map { wire in
                let dimension: PreferenceDimension = wire.dimension == "brand" ? .brand : wire.dimension == "size" ? .size : .attribute
                let key = wire.dimension.split(separator: ":", maxSplits: 1).last.map(String.init) ?? wire.dimension
                let id = LearnedPreference(
                    category: wire.category,
                    dimension: dimension,
                    key: key,
                    value: wire.value_key,
                    score: wire.score,
                    signalCount: wire.positive_count + wire.negative_count
                ).id
                return (id, wire)
            })
            return backendPreferenceSummary(userID: userID, output: output)
        } catch {
            return .empty(userID: userID)
        }
    }

    public func rankCandidates(
        _ candidates: [ProductCandidate],
        for intent: NeedIntent,
        userID: UUID,
        useLearnedPreferences: Bool
    ) async -> [ProductCandidate] {
        // The authenticated search endpoint applies the server entitlement and memory.
        candidates
    }

    public func removePreference(userID: UUID, preferenceID: String) async throws -> LearnedPreferenceSummary {
        if removalDescriptors[preferenceID] == nil { _ = await summary(for: userID) }
        guard let wire = removalDescriptors[preferenceID] else { throw AppError.notFound }
        let current = await summary(for: userID)
        _ = try await api.call("remove-preference", body: RemoveInput(
            category: wire.category,
            dimension: wire.dimension,
            value_key: wire.value_key,
            memory_epoch: current.memoryEpoch
        ), as: IgnoredBackendResponse.self)
        return await summary(for: userID)
    }

    public func resetProductMemory(userID: UUID) async throws -> LearnedPreferenceSummary {
        let current = await summary(for: userID)
        _ = try await api.call(
            "reset-product-memory",
            body: ResetInput(memory_epoch: current.memoryEpoch),
            as: IgnoredBackendResponse.self
        )
        removalDescriptors.removeAll()
        return await summary(for: userID)
    }
}

public actor BackendCheckoutService: CheckoutService {
    private struct Input: Encodable, Sendable {
        let selected_item_ids: [UUID]
        let idempotency_key: String
    }
    private struct Output: Decodable, Sendable { let checkout: CheckoutWire }
    private struct CheckoutWire: Decodable, Sendable {
        let id: UUID
        let list_id: UUID
        let state: String
        let subtotal_cents: Int
        let service_fee_cents: Int
        let delivery_fee_cents: Int
        let total_cents: Int
        let currency: String
    }
    private let api: BackendAPIClient

    public init(api: BackendAPIClient) { self.api = api }

    public func createCheckout(
        for list: ActiveList,
        selectedItemIDs: Set<UUID>,
        strategy: CartStrategy?,
        idempotencyKey: String
    ) async throws -> CheckoutSession {
        let known = Set(list.items.map(\.id))
        guard !selectedItemIDs.isEmpty, selectedItemIDs.isSubset(of: known) else {
            throw AppError.invalidInput("Checkout selection is invalid")
        }
        let output: Output = try await api.call("create-checkout", body: Input(
            selected_item_ids: selectedItemIDs.sorted { $0.uuidString < $1.uuidString },
            idempotency_key: idempotencyKey
        ))
        let items = list.items.filter { selectedItemIDs.contains($0.id) }
        return CheckoutSession(
            id: output.checkout.id,
            listID: output.checkout.list_id,
            status: output.checkout.state == "action_required" ? .actionRequired : .created,
            items: items,
            subtotal: Decimal(output.checkout.subtotal_cents) / 100,
            deliveryFee: Decimal(output.checkout.delivery_fee_cents) / 100,
            serviceFee: Decimal(output.checkout.service_fee_cents) / 100,
            total: Decimal(output.checkout.total_cents) / 100,
            currency: output.checkout.currency
        )
    }

    public func revalidate(_ session: CheckoutSession, against list: ActiveList) async throws -> CheckoutSession {
        try await createCheckout(
            for: list,
            selectedItemIDs: Set(session.items.map(\.id)),
            strategy: nil,
            idempotencyKey: "revalidate:\(session.id.uuidString)"
        )
    }
}

public actor BackendPaymentService: PaymentService {
    private struct Input: Encodable, Sendable {
        let checkout_id: UUID
        let payment_token: String
        let idempotency_key: String
    }
    private struct Output: Decodable, Sendable {
        let state: String
        let order_id: UUID?
        let delivery: DeliveryReference?
    }
    private struct DeliveryReference: Decodable, Sendable { let id: UUID }
    private let api: BackendAPIClient

    public init(api: BackendAPIClient) { self.api = api }

    public func createPaymentSession(for checkout: CheckoutSession, idempotencyKey: String) async throws -> PaymentSession {
        PaymentSession(
            id: checkout.id,
            checkoutID: checkout.id,
            amount: checkout.total,
            currency: checkout.currency,
            clientToken: idempotencyKey
        )
    }

    public func confirmPayment(
        session: PaymentSession,
        authorization: PaymentAuthorizationPayload,
        idempotencyKey: String
    ) async throws -> PaymentResult {
        guard !authorization.paymentData.isEmpty else { throw AppError.paymentFailed }
        let output: Output = try await api.call("confirm-payment", body: Input(
            checkout_id: session.checkoutID,
            payment_token: authorization.paymentData.base64EncodedString(),
            idempotency_key: idempotencyKey
        ))
        let status: PaymentStatus = output.state == "succeeded" ? .captured : .failed
        return PaymentResult(
            paymentID: session.id,
            status: status,
            processedAt: .now,
            orderID: output.order_id,
            deliveryID: output.delivery?.id
        )
    }

    public func voidPayment(id: UUID, idempotencyKey: String) async throws -> PaymentResult {
        throw AppError.configurationMissing("Payment reversal is server managed")
    }
}

public actor BackendPushDeviceRegistrationService: PushDeviceRegistrationService {
    private struct Input: Encodable, Sendable {
        let token: String
        let environment: String
        let app_version: String?
        let locale: String
    }
    private let api: BackendAPIClient
    private let environment: String

    public init(api: BackendAPIClient, environment: AppEnvironment) {
        self.api = api
        self.environment = environment == .production ? "production" : "sandbox"
    }

    public func register(deviceToken: Data) async throws {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else { throw AppError.invalidInput("Empty push token") }
        _ = try await api.call("register-push-device", body: Input(
            token: token,
            environment: environment,
            app_version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            locale: Locale.current.identifier
        ), as: IgnoredBackendResponse.self)
    }

    public func invalidate(deviceToken: Data) async {
        // Permanent provider rejection is also handled by the dispatch worker.
    }
}

@MainActor
@Observable
public final class BackendNotificationService: NotificationService {
    private struct Input: Encodable, Sendable {
        let daily_list_enabled: Bool
        let reminder_time: String
        let timezone: String
    }
    public private(set) var preferences: NotificationPreferences
    private let system: SystemNotificationService
    private let api: BackendAPIClient

    public init(system: SystemNotificationService = .init(), api: BackendAPIClient) {
        self.system = system
        self.api = api
        self.preferences = system.preferences
    }

    public func requestAuthorization() async -> Bool { await system.requestAuthorization() }
    public func registerForRemoteNotifications() { system.registerForRemoteNotifications() }

    public func updatePreferences(_ preferences: NotificationPreferences) async throws {
        let reminder = String(format: "%02d:%02d:00", preferences.localHour, preferences.localMinute)
        _ = try await api.call("update-notification-preferences", body: Input(
            daily_list_enabled: preferences.isDailyReminderEnabled,
            reminder_time: reminder,
            timezone: preferences.timeZoneIdentifier
        ), as: IgnoredBackendResponse.self)
        try await system.updatePreferences(preferences)
        self.preferences = preferences
    }
}
