import SwiftUI

struct OrdersView: View {
    @State var model: OrdersViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NeedsSpacing.large) {
                Text("orders.title")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .accessibilityIdentifier("orders.title")

                content
            }
            .needsPage()
            .padding(.vertical, NeedsSpacing.large)
        }
        .background(NeedsTheme.background)
        .navigationBarHidden(true)
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            LoadingRowsView(count: 3)
        case .empty:
            StateMessageView(
                systemImage: "bag",
                title: "No orders yet",
                message: "Your active and past orders will appear here."
            )
        case .offline:
            StateMessageView(
                systemImage: "wifi.slash",
                title: "You're offline",
                message: "Your saved orders will appear when available.",
                retryTitle: "common.retry"
            ) { Task { await model.load() } }
        case let .failed(message):
            StateMessageView(
                systemImage: "exclamationmark.circle",
                title: "Orders unavailable",
                message: message,
                retryTitle: "common.retry"
            ) { Task { await model.load() } }
        case .loaded:
            if !model.activeOrders.isEmpty {
                OrderSection(title: "Active", orders: model.activeOrders, open: model.open)
            }
            if !model.pastOrders.isEmpty {
                OrderSection(title: "Past", orders: model.pastOrders, open: model.open)
            }
        }
    }
}

private struct OrderSection: View {
    let title: String
    let orders: [Order]
    let open: (Order) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NeedsSpacing.small) {
            Text(title)
                .font(.title2.bold())
            VStack(spacing: NeedsSpacing.small) {
                ForEach(orders) { order in
                    OrderCard(order: order) { open(order) }
                }
            }
        }
    }
}

private struct OrderCard: View {
    let order: Order
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: NeedsSpacing.medium) {
                HStack(alignment: .firstTextBaseline) {
                    Text(order.createdAt, format: .dateTime.month(.abbreviated).day())
                        .font(.headline)
                    Spacer()
                    Text(CurrencyFormatter.string(amount: order.total, currency: order.currency))
                        .font(.headline.monospacedDigit())
                }
                HStack {
                    Label("\(order.items.reduce(0) { $0 + $1.quantity }) items", systemImage: "bag")
                    Spacer()
                    Text(order.status.displayName)
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .needsCard()
            .contentShape(RoundedRectangle(cornerRadius: NeedsTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens order details")
        .accessibilityIdentifier("order.\(order.id.uuidString)")
    }
}

extension OrderStatus {
    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .confirmed: "Confirmed"
        case .actionRequired: "Needs attention"
        case .preparing: "Being prepared"
        case .delivering: "On the way"
        case .delivered: "Delivered"
        case .cancelled: "Cancelled"
        case .failed: "Couldn't be completed"
        }
    }
}

