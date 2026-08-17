import SwiftUI

struct NeedsLogo: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 7 : 10) {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 9 : 13, style: .continuous)
                    .fill(Color.primary)
                Image(systemName: "checkmark")
                    .font(.system(size: compact ? 13 : 19, weight: .bold))
                    .foregroundStyle(NeedsTheme.background)
            }
            .frame(width: compact ? 30 : 44, height: compact ? 30 : 44)

            Text("app.name")
                .font(compact ? .headline : .system(size: 30, weight: .bold, design: .rounded))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("app.name"))
    }
}

#Preview {
    NeedsLogo()
        .padding()
}

