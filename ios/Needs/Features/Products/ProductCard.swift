import SwiftUI

struct ProductCard: View {
    let product: ProductCandidate
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: NeedsSpacing.medium) {
                ProductArtwork(imageURL: product.imageURL, category: product.category)

                VStack(alignment: .leading, spacing: NeedsSpacing.xSmall) {
                    if let badgeTitle {
                        Text(badgeTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                    Text(product.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(product.brand)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(product.formatSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let highlight {
                        Text(highlight)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text(product.formattedPrice)
                            .font(.headline)
                            .monospacedDigit()
                        Spacer()
                        Text(product.retailerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(NeedsSpacing.medium)
            .background(NeedsTheme.surface, in: RoundedRectangle(cornerRadius: NeedsTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NeedsTheme.cardRadius, style: .continuous)
                    .stroke(NeedsTheme.separator, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: NeedsTheme.cardRadius, style: .continuous))
            .accessibilityElement(children: .ignore)
        }
        .buttonStyle(ProductPressStyle())
        .disabled(!product.availability.isPurchasable)
        .opacity(product.availability.isPurchasable ? 1 : 0.55)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(product.availability.isPurchasable ? "Adds this product to your current list" : "Unavailable")
        .accessibilityIdentifier("candidate.\(product.id.uuidString)")
    }

    private var badgeTitle: String? {
        switch product.kind {
        case .bestMatch: "Best match"
        case .bestValue: "Best value"
        case .discovery: "Worth discovering"
        case .standard: nil
        }
    }

    private var highlight: String? {
        let preferredKeys = ["durability", "feature", "flavor", "material"]
        return preferredKeys.compactMap { product.attributes[$0] }.first ??
            (product.productDescription.isEmpty ? nil : product.productDescription)
    }

    private var accessibilityLabel: String {
        [badgeTitle, product.name, product.brand, product.formatSummary, product.formattedPrice, product.retailerName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

private struct ProductPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

