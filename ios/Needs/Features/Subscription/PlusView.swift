import SwiftUI

struct PlusView: View {
    @State var model: PlusViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NeedsSpacing.xLarge) {
                VStack(alignment: .leading, spacing: NeedsSpacing.medium) {
                    Text("Plus")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("plus.title")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text("plus.body")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: NeedsSpacing.large) {
                    PlusBenefit(icon: "shippingbox.fill", title: "Bundle purchases when it saves money")
                    PlusBenefit(icon: "sum", title: "Compare the full cost, not just item prices")
                    PlusBenefit(icon: "heart.fill", title: "Remember the products you prefer")
                    PlusBenefit(icon: "tag.fill", title: "Lower service fees")
                }
                .needsCard()

                if let error = model.errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                VStack(spacing: NeedsSpacing.small) {
                    if model.isPlus {
                        Label("Plus is active", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(NeedsTheme.surface, in: RoundedRectangle(cornerRadius: NeedsTheme.controlRadius, style: .continuous))
                    } else if let localizedPrice = model.localizedPrice {
                        PrimaryButton(
                            title: LocalizedStringKey("Start Plus — \(localizedPrice) / month"),
                            isLoading: model.isPurchasing
                        ) {
                            Task { await model.purchase() }
                        }
                        .accessibilityIdentifier("plus.start")
                    } else {
                        HStack(spacing: NeedsSpacing.small) {
                            ProgressView()
                            Text("Loading subscription...")
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(NeedsTheme.surface, in: RoundedRectangle(cornerRadius: NeedsTheme.controlRadius, style: .continuous))
                    }

                    Button("Restore purchases") { Task { await model.restore() } }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, NeedsSpacing.small)
                }

                Text("Subscription renews monthly until canceled. You can manage or cancel it in your account settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .needsPage()
            .padding(.vertical, NeedsSpacing.xLarge)
        }
        .background(NeedsTheme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }
}

private struct PlusBenefit: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: NeedsSpacing.medium) {
            Image(systemName: icon)
                .font(.headline)
                .frame(width: 34, height: 34)
                .background(NeedsTheme.background, in: Circle())
            Text(title)
                .font(.headline)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
