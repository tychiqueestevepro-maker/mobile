import SwiftUI

enum NeedsTheme {
    static let background = Color(uiColor: .systemBackground)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let separator = Color.primary.opacity(0.08)
    static let accent = Color.accentColor

    static let cardRadius: CGFloat = 22
    static let controlRadius: CGFloat = 16
    static let pageInset: CGFloat = 20
    static let contentWidth: CGFloat = 620
}

enum NeedsSpacing {
    static let xSmall: CGFloat = 6
    static let small: CGFloat = 10
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 36
    static let xxLarge: CGFloat = 52
}

extension View {
    func needsPage() -> some View {
        frame(maxWidth: NeedsTheme.contentWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, NeedsTheme.pageInset)
    }

    func needsCard() -> some View {
        padding(NeedsSpacing.medium)
            .background(NeedsTheme.surface, in: RoundedRectangle(cornerRadius: NeedsTheme.cardRadius, style: .continuous))
    }
}

