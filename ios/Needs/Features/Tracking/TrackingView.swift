import SwiftUI

struct TrackingView: View {
    @State var model: TrackingViewModel

    var body: some View {
        Group {
            switch model.orderState {
            case .idle, .loading:
                ProgressView("Loading order...")
            case .empty:
                StateMessageView(
                    systemImage: "bag",
                    title: "Order unavailable",
                    message: "This order may have been removed."
                )
            case .offline:
                StateMessageView(
                    systemImage: "wifi.slash",
                    title: "You're offline",
                    message: "Reconnect for the latest delivery update."
                )
            case let .failed(message):
                StateMessageView(
                    systemImage: "exclamationmark.circle",
                    title: "Order unavailable",
                    message: message
                )
            case let .loaded(order):
                orderContent(order)
            }
        }
        .navigationTitle("Order")
        .navigationBarTitleDisplayMode(.inline)
        .background(NeedsTheme.background)
        .task { await model.load() }
    }

    private func orderContent(_ order: Order) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NeedsSpacing.large) {
                VStack(alignment: .leading, spacing: NeedsSpacing.xSmall) {
                    Text(order.status.displayName)
                        .font(.largeTitle.bold())
                    if let eta = model.delivery?.estimatedArrival, model.delivery?.status != .delivered {
                        Text("Estimated arrival \(eta.formatted(date: .omitted, time: .shortened))")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                if order.status == .actionRequired {
                    Label("Your order needs attention. Support will help resolve it before delivery.", systemImage: "exclamationmark.circle.fill")
                        .needsCard()
                }

                DeliveryTimeline(status: model.delivery?.status ?? statusForOrder(order.status))

                if let courier = model.delivery?.courierFirstName {
                    VStack(alignment: .leading, spacing: NeedsSpacing.small) {
                        Text("Your courier").font(.headline)
                        HStack(spacing: NeedsSpacing.medium) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 42))
                            VStack(alignment: .leading) {
                                Text(courier).fontWeight(.semibold)
                                if let vehicle = model.delivery?.vehicleDescription {
                                    Text(vehicle).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .needsCard()
                }

                VStack(alignment: .leading, spacing: NeedsSpacing.medium) {
                    Text("Items").font(.headline)
                    ForEach(order.items) { item in
                        HStack {
                            Text("\(item.quantity)×")
                                .foregroundStyle(.secondary)
                            Text(item.name)
                            Spacer()
                            Text(CurrencyFormatter.string(amount: item.totalPrice, currency: order.currency))
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                    Divider()
                    PriceSummaryRow(title: "checkout.total", value: CurrencyFormatter.string(amount: order.total, currency: order.currency), emphasized: true)
                }
                .needsCard()

                VStack(alignment: .leading, spacing: NeedsSpacing.small) {
                    Text("Deliver to").font(.headline)
                    Text(order.deliveryAddress.singleLine)
                        .foregroundStyle(.secondary)
                }
                .needsCard()
            }
            .needsPage()
            .padding(.vertical, NeedsSpacing.large)
        }
    }

    private func statusForOrder(_ status: OrderStatus) -> DeliveryStatus {
        switch status {
        case .pending: .pending
        case .confirmed, .preparing: .confirmed
        case .delivering: .onTheWay
        case .delivered: .delivered
        case .cancelled: .cancelled
        case .failed, .actionRequired: .failed
        }
    }
}

private struct DeliveryTimeline: View {
    let status: DeliveryStatus

    private let steps: [(DeliveryStatus, String, String)] = [
        (.confirmed, "Order confirmed", "checkmark.circle.fill"),
        (.courierAssigned, "Picking up your order", "bag.fill"),
        (.onTheWay, "On the way", "car.fill"),
        (.arriving, "Arriving soon", "location.fill"),
        (.delivered, "Delivered", "house.fill")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let reached = progressRank(status) >= progressRank(step.0)
                HStack(alignment: .top, spacing: NeedsSpacing.medium) {
                    VStack(spacing: 0) {
                        Image(systemName: step.2)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(reached ? NeedsTheme.background : .secondary)
                            .frame(width: 34, height: 34)
                            .background(reached ? Color.primary : NeedsTheme.surface, in: Circle())
                        if index < steps.count - 1 {
                            Rectangle()
                                .fill(reached ? Color.primary : NeedsTheme.separator)
                                .frame(width: 2, height: 40)
                        }
                    }
                    Text(step.1)
                        .font(.headline)
                        .foregroundStyle(reached ? .primary : .secondary)
                        .padding(.top, 7)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(step.1), \(reached ? "completed" : "upcoming")")
            }
        }
        .needsCard()
        .animation(.smooth, value: status)
        .accessibilityIdentifier("tracking.timeline")
    }

    private func progressRank(_ status: DeliveryStatus) -> Int {
        switch status {
        case .pending: 0
        case .confirmed: 1
        case .courierAssigned, .courierHeadingToPickup, .pickedUp: 2
        case .onTheWay: 3
        case .arriving: 4
        case .delivered: 5
        case .cancelled, .failed: 0
        }
    }
}

