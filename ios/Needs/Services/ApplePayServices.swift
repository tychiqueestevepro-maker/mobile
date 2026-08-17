import Foundation
@preconcurrency import PassKit

@MainActor
public struct ApplePayRequestFactory {
    public let merchantIdentifier: String
    public let countryCode: String
    public let supportedNetworks: [PKPaymentNetwork]

    public init(
        merchantIdentifier: String,
        countryCode: String = "US",
        supportedNetworks: [PKPaymentNetwork] = [.amex, .masterCard, .visa, .discover]
    ) {
        self.merchantIdentifier = merchantIdentifier
        self.countryCode = countryCode
        self.supportedNetworks = supportedNetworks
    }

    public var canMakePayments: Bool {
        PKPaymentAuthorizationController.canMakePayments(usingNetworks: supportedNetworks)
    }

    public func makeRequest(for checkout: CheckoutSession) -> PKPaymentRequest {
        let request = PKPaymentRequest()
        request.merchantIdentifier = merchantIdentifier
        request.countryCode = countryCode
        request.currencyCode = checkout.currency
        request.merchantCapabilities = .capability3DS
        request.supportedNetworks = supportedNetworks
        request.paymentSummaryItems = [
            PKPaymentSummaryItem(label: "Items", amount: checkout.subtotal as NSDecimalNumber),
            PKPaymentSummaryItem(label: "Delivery", amount: checkout.deliveryFee as NSDecimalNumber),
            PKPaymentSummaryItem(label: "Service fee", amount: checkout.serviceFee as NSDecimalNumber),
            PKPaymentSummaryItem(label: "Needs", amount: checkout.total as NSDecimalNumber)
        ]
        return request
    }

    public func payload(from token: PKPaymentToken) -> PaymentAuthorizationPayload {
        PaymentAuthorizationPayload(
            paymentData: token.paymentData,
            transactionIdentifier: token.transactionIdentifier
        )
    }
}
