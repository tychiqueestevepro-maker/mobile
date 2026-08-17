import SwiftUI

struct PrimaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NeedsSpacing.small) {
                if isLoading {
                    ProgressView()
                        .tint(NeedsTheme.background)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(NeedsTheme.background)
        .background(isDisabled ? Color.secondary : Color.primary, in: RoundedRectangle(cornerRadius: NeedsTheme.controlRadius, style: .continuous))
        .disabled(isDisabled || isLoading)
        .animation(.easeOut(duration: 0.2), value: isLoading)
    }
}

struct SecondaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NeedsSpacing.small) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(NeedsTheme.surface, in: RoundedRectangle(cornerRadius: NeedsTheme.controlRadius, style: .continuous))
    }
}

