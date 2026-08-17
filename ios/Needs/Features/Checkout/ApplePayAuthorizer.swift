@preconcurrency import PassKit
import Foundation

/// Bridges the system payment sheet to server confirmation. The sheet's
/// result handler intentionally remains pending until `complete(success:)`.
@MainActor
final class PaymentAuthorizationContext {
    let payload: PaymentAuthorizationPayload
    private var didComplete = false
    private let result: @MainActor (Bool) -> Void

    init(payload: PaymentAuthorizationPayload, result: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.payload = payload
        self.result = result
    }

    func complete(success: Bool) {
        guard !didComplete else { return }
        didComplete = true
        result(success)
    }
}

@MainActor
final class ApplePayAuthorizer: NSObject, @preconcurrency PKPaymentAuthorizationControllerDelegate {
    private var continuation: CheckedContinuation<PaymentAuthorizationContext, Error>?
    private var authorizationCompletion: ((PKPaymentAuthorizationResult) -> Void)?
    private var controller: PKPaymentAuthorizationController?
    private var requestFactory: ApplePayRequestFactory?

    func authorize(
        checkout: CheckoutSession,
        merchantIdentifier: String,
        countryCode: String = "US"
    ) async throws -> PaymentAuthorizationContext {
        guard continuation == nil, authorizationCompletion == nil else {
            throw AppError.conflict("Payment sheet is already open")
        }

        let factory = ApplePayRequestFactory(
            merchantIdentifier: merchantIdentifier,
            countryCode: countryCode
        )
        guard factory.canMakePayments else { throw AppError.unavailable("Apple Pay is unavailable") }
        requestFactory = factory

        let controller = PKPaymentAuthorizationController(paymentRequest: factory.makeRequest(for: checkout))
        controller.delegate = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.present { [weak self] presented in
                guard !presented else { return }
                self?.finish(throwing: AppError.unavailable("Payment sheet could not be presented"))
            }
        }
    }

    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        guard let requestFactory else {
            completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
            return
        }
        authorizationCompletion = completion
        let context = PaymentAuthorizationContext(payload: requestFactory.payload(from: payment.token)) { [self] success in
            let status: PKPaymentAuthorizationStatus = success ? .success : .failure
            authorizationCompletion?(PKPaymentAuthorizationResult(status: status, errors: nil))
            authorizationCompletion = nil
        }
        finish(returning: context)
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        if continuation != nil { finish(throwing: CancellationError()) }
        if let authorizationCompletion {
            authorizationCompletion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
            self.authorizationCompletion = nil
        }
        controller.dismiss {}
        self.controller = nil
        requestFactory = nil
    }

    private func finish(returning context: PaymentAuthorizationContext) {
        continuation?.resume(returning: context)
        continuation = nil
    }

    private func finish(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

