import Foundation
import Observation

public actor MockEntitlementService: EntitlementService {
    private var tier: MembershipTier

    public init(tier: MembershipTier = .free) { self.tier = tier }

    public func currentEntitlements() async -> Entitlements {
        tier == .plus ? .plus : .free
    }

    public func refresh() async throws -> Entitlements { await currentEntitlements() }

    public func setTier(_ tier: MembershipTier) { self.tier = tier }
}

@MainActor
@Observable
public final class MockSubscriptionManager: SubscriptionManaging {
    public private(set) var entitlements: Entitlements
    public private(set) var localizedPrice: String?
    public private(set) var isLoading: Bool = false
    private let onTierChanged: @Sendable (MembershipTier) async -> Void

    public init(
        tier: MembershipTier = .free,
        localizedPrice: String = "$9.99",
        onTierChanged: @escaping @Sendable (MembershipTier) async -> Void = { _ in }
    ) {
        self.entitlements = tier == .plus ? .plus : .free
        self.localizedPrice = localizedPrice
        self.onTierChanged = onTierChanged
    }

    public func loadProducts() async {
        isLoading = true
        await Task.yield()
        isLoading = false
    }

    public func purchasePlus() async throws {
        isLoading = true
        defer { isLoading = false }
        entitlements = .plus
        await onTierChanged(.plus)
    }

    public func restorePurchases() async throws {
        isLoading = true
        defer { isLoading = false }
        await onTierChanged(entitlements.tier)
    }

    public func simulateDowngrade() async {
        entitlements = .free
        await onTierChanged(.free)
    }
}
