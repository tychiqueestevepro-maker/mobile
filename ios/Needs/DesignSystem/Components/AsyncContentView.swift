import SwiftUI

enum ViewLoadState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case offline
    case failed(message: String)
}

struct StateMessageView: View {
    let systemImage: String
    let title: String
    let message: String
    var retryTitle: LocalizedStringKey?
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let retryTitle, let retry {
                Button(retryTitle, action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
            }
        }
    }
}

struct InlineErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: NeedsSpacing.small) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: NeedsSpacing.xSmall) {
                Text(message)
                    .font(.subheadline)
                Button("common.retry", action: retry)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .needsCard()
        .accessibilityElement(children: .combine)
    }
}

struct LoadingRowsView: View {
    var count = 3

    var body: some View {
        VStack(spacing: NeedsSpacing.small) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: NeedsTheme.cardRadius, style: .continuous)
                    .fill(NeedsTheme.surface)
                    .frame(height: 112)
                    .overlay {
                        ProgressView()
                            .tint(.secondary)
                    }
            }
        }
        .accessibilityLabel("Loading")
    }
}

