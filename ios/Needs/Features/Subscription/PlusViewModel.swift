import Foundation
import Observation

@MainActor
@Observable
final class PlusViewModel {
    var isPurchasing = false
    var errorMessage: String?

    private let subscriptionManager: any SubscriptionManaging
    private let analytics: any AnalyticsService
    private let completed: @MainActor () -> Void

    init(
        subscriptionManager: any SubscriptionManaging,
        analytics: any AnalyticsService,
        completed: @escaping @MainActor () -> Void
    ) {
        self.subscriptionManager = subscriptionManager
        self.analytics = analytics
        self.completed = completed
    }

    var localizedPrice: String? { subscriptionManager.localizedPrice }
    var isPlus: Bool { subscriptionManager.entitlements.tier == .plus }

    func load() async {
        await analytics.track(.plusViewed, properties: [:])
        await subscriptionManager.loadProducts()
    }

    func purchase() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        errorMessage = nil
        do {
            try await subscriptionManager.purchasePlus()
            await analytics.track(.plusStarted, properties: [:])
            completed()
        } catch is CancellationError {
            // The user dismissed the payment sheet; no error is needed.
        } catch {
            errorMessage = "We couldn't start Plus. Please try again."
        }
        isPurchasing = false
    }

    func restore() async {
        do {
            try await subscriptionManager.restorePurchases()
            if isPlus { completed() }
        } catch {
            errorMessage = "We couldn't restore purchases."
        }
    }
}
