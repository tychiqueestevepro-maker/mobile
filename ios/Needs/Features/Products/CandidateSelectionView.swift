import SwiftUI

struct CandidateSelectionView: View {
    @State var model: CandidateSelectionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NeedsSpacing.large) {
                VStack(alignment: .leading, spacing: NeedsSpacing.xSmall) {
                    Text(model.title)
                        .font(.largeTitle.bold())
                    Text("Choose one")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                content

                if let error = model.errorMessage {
                    InlineErrorView(message: error) {
                        Task { await model.load() }
                    }
                }
            }
            .needsPage()
            .padding(.vertical, NeedsSpacing.large)
        }
        .background(NeedsTheme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .sensoryFeedback(.success, trigger: model.selectedID)
        .overlay {
            if let selectedID = model.selectedID, model.isSaving {
                AddedOverlay(selectedID: selectedID)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.smooth, value: model.selectedID)
    }

    @ViewBuilder
    private var content: some View {
        switch model.candidates {
        case .idle, .loading:
            VStack(spacing: NeedsSpacing.medium) {
                HStack(spacing: NeedsSpacing.small) {
                    ProgressView()
                    Text("home.finding")
                        .foregroundStyle(.secondary)
                }
                LoadingRowsView()
            }
        case .empty:
            StateMessageView(
                systemImage: "shippingbox",
                title: "No close matches",
                message: "Try describing the item a different way.",
                retryTitle: "common.retry"
            ) { Task { await model.load() } }
        case let .loaded(products):
            VStack(spacing: NeedsSpacing.small) {
                ForEach(products.prefix(3)) { product in
                    let card = ProductCard(product: product)
                    Button {
                        Task { await model.choose(product) }
                    } label: {
                        card
                    }
                    .buttonStyle(ProductPressStyle())
                    .disabled(!product.availability.isPurchasable)
                    .accessibilityIdentifier("candidate.\(product.id.uuidString)")
                    .accessibilityLabel(card.accessibilityLabel)
                    .accessibilityHint(product.availability.isPurchasable ? "Adds this product to your current list" : "Unavailable")
                    .accessibilityElement(children: .combine)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await model.explicitlyReject(product) }
                        } label: {
                            Label("Not for me", systemImage: "hand.thumbsdown")
                        }
                    }
                }
            }
            .accessibilityIdentifier("candidates.list")
            .accessibilityElement(children: .contain)
        case .offline:
            StateMessageView(
                systemImage: "wifi.slash",
                title: "You're offline",
                message: "Connect to the internet to find products. Your current list is safe.",
                retryTitle: "common.retry"
            ) { Task { await model.load() } }
        case let .failed(message):
            StateMessageView(
                systemImage: "exclamationmark.circle",
                title: "Products unavailable",
                message: message,
                retryTitle: "common.retry"
            ) { Task { await model.load() } }
        }
    }
}

private struct AddedOverlay: View {
    let selectedID: UUID

    var body: some View {
        VStack(spacing: NeedsSpacing.small) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54, weight: .semibold))
            Text("candidates.added")
                .font(.headline)
        }
        .padding(NeedsSpacing.xLarge)
        .foregroundStyle(NeedsTheme.background)
        .background(.primary.opacity(0.94), in: RoundedRectangle(cornerRadius: NeedsTheme.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 30, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("candidate.added.\(selectedID.uuidString)")
    }
}

