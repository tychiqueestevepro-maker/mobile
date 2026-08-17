import SwiftUI

struct PriceSummaryRow: View {
    let title: LocalizedStringKey
    let value: String
    var emphasized = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(emphasized ? .headline : .body)
        .foregroundStyle(emphasized ? .primary : .secondary)
        .accessibilityElement(children: .combine)
    }
}

