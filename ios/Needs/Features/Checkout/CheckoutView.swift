import PassKit
import SwiftUI

struct CheckoutView: View {
    @State var model: CheckoutViewModel

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                VStack(spacing: NeedsSpacing.medium) {
                    ProgressView()
                    Text("Preparing your checkout...")
                        .foregroundStyle(.secondary)
                }
            case .empty:
                StateMessageView(
                    systemImage: "cart",
                    title: "This list is empty",
                    message: "Add an item before checking out."
                )
            case let .loaded(session):
                checkoutContent(session)
            case .offline:
                StateMessageView(
                    systemImage: "wifi.slash",
                    title: "Checkout needs a connection",
                    message: "Connect to verify availability, prices, and delivery.",
                    retryTitle: "common.retry"
                ) { Task { await model.load() } }
            case let .failed(message):
                StateMessageView(
                    systemImage: "exclamationmark.circle",
                    title: "Checkout unavailable",
                    message: message,
                    retryTitle: "common.retry"
                ) { Task { await model.load() } }
            }
        }
        .navigationTitle("checkout.title")
        .navigationBarTitleDisplayMode(.inline)
        .background(NeedsTheme.groupedBackground)
        .task { await model.load() }
        .interactiveDismissDisabled(model.isProcessing)
    }

    private func checkoutContent(_ session: CheckoutSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NeedsSpacing.large) {
                CheckoutSection(title: "Deliver to") {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.address.street).fontWeight(.semibold)
                            Text([model.address.city, model.address.region, model.address.postalCode].joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "location.fill")
                    }
                }

                CheckoutSection(title: "Items") {
                    VStack(spacing: NeedsSpacing.medium) {
                        ForEach(model.availableItems) { item in
                            Button { Task { await model.toggle(item) } } label: {
                                HStack(spacing: NeedsSpacing.small) {
                                    Image(systemName: model.selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(.primary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.product.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Text("\(item.product.brand) · ×\(item.quantity)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(CurrencyFormatter.string(amount: item.lineTotal, currency: item.product.currency))
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.primary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(model.selectedItemIDs.contains(item.id) ? "Included in this order" : "Carried forward to your next list")
                        }
                    }
                }

                CheckoutSection(title: "Summary") {
                    VStack(spacing: NeedsSpacing.small) {
                        PriceSummaryRow(title: "checkout.items", value: CurrencyFormatter.string(amount: session.subtotal, currency: session.currency))
                        PriceSummaryRow(title: "checkout.delivery", value: CurrencyFormatter.string(amount: session.deliveryFee, currency: session.currency))
                        PriceSummaryRow(title: "checkout.service_fee", value: CurrencyFormatter.string(amount: session.serviceFee, currency: session.currency))
                        Divider()
                        PriceSummaryRow(title: "checkout.total", value: CurrencyFormatter.string(amount: session.total, currency: session.currency), emphasized: true)
                    }
                }
                .accessibilityIdentifier("checkout.summary")


                if !session.unavailableItemIDs.isEmpty {
                    Label("An item changed availability. Review a replacement before paying.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .needsCard()
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .needsCard()
                        .accessibilityIdentifier("checkout.error")
                }

                VStack(spacing: NeedsSpacing.small) {
                    if ProcessInfo.processInfo.arguments.contains("-UITesting") {
                        PrimaryButton(title: "Pay with Apple Pay") {
                            Task { await model.pay() }
                        }
                        .disabled(model.isBusy || !session.unavailableItemIDs.isEmpty)
                        .opacity(model.isBusy ? 0.6 : 1)
                        .accessibilityIdentifier("checkout.pay")
                    } else {
                        ApplePayButton {
                            Task { await model.pay() }
                        }
                        .frame(height: 52)
                        .disabled(model.isBusy || !session.unavailableItemIDs.isEmpty)
                        .opacity(model.isBusy ? 0.6 : 1)
                        .accessibilityIdentifier("checkout.pay")
                    }

                    if model.isBusy {
                        HStack(spacing: NeedsSpacing.small) {
                            ProgressView()
                            Text(progressMessage)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    if model.selectedItemIDs.count < model.availableItems.count {
                        Text("Unselected items will stay on your current list.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .needsPage()
            .padding(.vertical, NeedsSpacing.large)
        }
    }

    private var progressMessage: String {
        if model.isRepricing { return "Refreshing total..." }
        switch model.paymentProgress {
        case .revalidating: return "Checking price and availability..."
        case .authorizing: return "Confirming payment..."
        case .placingOrder: return "Placing your order..."
        case .idle, .completed: return ""
        }
    }
}

private struct CheckoutSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NeedsSpacing.small) {
            Text(title)
                .font(.headline)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .needsCard()
        }
    }
}

struct ApplePayButton: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> PKPaymentButton {
        let button = PKPaymentButton(paymentButtonType: .buy, paymentButtonStyle: .automatic)
        button.cornerRadius = NeedsTheme.controlRadius
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: PKPaymentButton, context: Context) {}

    final class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}
