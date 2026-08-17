import Foundation
import Observation
import StoreKit

@MainActor
@Observable
public final class SubscriptionManager: SubscriptionManaging {
    public private(set) var entitlements: Entitlements = .free
    public private(set) var localizedPrice: String?
    public private(set) var isLoading = false
    public private(set) var lastErrorMessage: String?

    private let productIdentifier: String
    private let appAccountTokenProvider: any AppAccountTokenProvider
    private let syncService: any SubscriptionSyncService
    private let onTierChanged: @Sendable (MembershipTier) async -> Void
    @ObservationIgnored private var product: Product?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    public init(
        productIdentifier: String = "com.tychi.mobile.plus.monthly",
        appAccountTokenProvider: any AppAccountTokenProvider,
        syncService: any SubscriptionSyncService,
        onTierChanged: @escaping @Sendable (MembershipTier) async -> Void = { _ in }
    ) {
        self.productIdentifier = productIdentifier
        self.appAccountTokenProvider = appAccountTokenProvider
        self.syncService = syncService
        self.onTierChanged = onTierChanged
        observeTransactions()
    }

    public func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            product = try await Product.products(for: [productIdentifier]).first
            localizedPrice = product?.displayPrice
            await refreshEntitlements()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func purchasePlus() async throws {
        guard let product else { throw AppError.configurationMissing("Subscription product is unavailable") }
        isLoading = true
        defer { isLoading = false }
        let accountToken = try await appAccountTokenProvider.appAccountToken()
        let result = try await product.purchase(options: [.appAccountToken(accountToken)])
        switch result {
        case .success(let verification):
            try await process(verification)
            await refreshEntitlements()
        case .pending:
            return
        case .userCancelled:
            return
        @unknown default:
            throw AppError.underlying("Unknown purchase result")
        }
    }

    public func restorePurchases() async throws {
        isLoading = true
        defer { isLoading = false }
        try await AppStore.sync()
        await refreshEntitlements()
    }

    private func observeTransactions() {
        updatesTask = Task { [weak self] in
            for await verification in Transaction.updates {
                guard let self else { return }
                do {
                    try await self.process(verification)
                    await self.refreshEntitlements()
                } catch {
                    self.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func refreshEntitlements() async {
        var hasPlus = false
        guard let accountToken = try? await appAccountTokenProvider.appAccountToken() else {
            entitlements = .free
            return
        }
        for await verification in Transaction.currentEntitlements {
            guard let transaction = try? verified(verification),
                  transaction.productID == productIdentifier,
                  transaction.revocationDate == nil else { continue }
            if let expirationDate = transaction.expirationDate, expirationDate <= .now { continue }
            do {
                try await syncService.syncVerifiedTransaction(
                    jwsRepresentation: verification.jwsRepresentation,
                    appAccountToken: accountToken
                )
                hasPlus = true
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
        entitlements = hasPlus ? .plus : .free
        await onTierChanged(hasPlus ? .plus : .free)
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): value
        case .unverified(_, let error): throw error
        }
    }

    private func process(_ verification: VerificationResult<Transaction>) async throws {
        let transaction = try verified(verification)
        guard transaction.productID == productIdentifier else { return }
        let accountToken = try await appAccountTokenProvider.appAccountToken()
        if let transactionToken = transaction.appAccountToken,
           transactionToken != accountToken {
            throw AppError.conflict("Transaction belongs to another account")
        }
        try await syncService.syncVerifiedTransaction(
            jwsRepresentation: verification.jwsRepresentation,
            appAccountToken: accountToken
        )
        await transaction.finish()
    }
}
