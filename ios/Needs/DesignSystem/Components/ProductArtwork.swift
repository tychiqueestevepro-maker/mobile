import SwiftUI

struct ProductArtwork: View {
    let imageURL: URL?
    let category: String
    var size: CGFloat = 84

    var body: some View {
        AsyncImage(url: imageURL, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            case .empty:
                ProgressView()
                    .controlSize(.small)
            case .failure:
                placeholder
            @unknown default:
                placeholder
            }
        }
        .frame(width: size, height: size)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.32, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private var symbol: String {
        switch category.lowercased() {
        case let value where value.contains("tooth"): "mouth.fill"
        case let value where value.contains("trash"): "trash.fill"
        case let value where value.contains("egg"): "oval.fill"
        case let value where value.contains("milk"): "waterbottle.fill"
        case let value where value.contains("coffee"): "cup.and.saucer.fill"
        case let value where value.contains("battery"): "battery.75percent"
        case let value where value.contains("paper"): "scroll.fill"
        default: "shippingbox.fill"
        }
    }
}

