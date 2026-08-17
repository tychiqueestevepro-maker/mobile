import Foundation
import Observation

@MainActor
@Observable
final class TrackingViewModel {
    let orderID: UUID
    var orderState: LoadableState<Order> = .idle
    var delivery: Delivery?

    private let repository: any OrderRepository
    private let deliveryProvider: any DeliveryProvider
    private let analytics: any AnalyticsService

    init(
        orderID: UUID,
        repository: any OrderRepository,
        deliveryProvider: any DeliveryProvider,
        analytics: any AnalyticsService
    ) {
        self.orderID = orderID
        self.repository = repository
        self.deliveryProvider = deliveryProvider
        self.analytics = analytics
    }

    var order: Order? {
        guard case let .loaded(order) = orderState else { return nil }
        return order
    }

    func load() async {
        orderState = .loading
        guard let order = await fetchOrder() else {
            orderState = .empty
            return
        }
        orderState = .loaded(order)
        guard let deliveryID = order.deliveryID else { return }

        delivery = await deliveryProvider.delivery(id: deliveryID)
        for await update in await deliveryProvider.updates(for: deliveryID) {
            guard !Task.isCancelled else { break }
            delivery = update
            if update.status == .delivered,
               let updatedOrder = try? await repository.updateStatus(id: orderID, status: .delivered) {
                orderState = .loaded(updatedOrder)
                await analytics.track(.deliveryCompleted, properties: ["order_id": orderID.uuidString])
            } else if update.status == .cancelled || update.status == .failed,
                      let updatedOrder = try? await repository.updateStatus(id: orderID, status: .actionRequired) {
                orderState = .loaded(updatedOrder)
            }
        }
    }

    private func fetchOrder() async -> Order? {
        for attempt in 0..<6 {
            if let order = await repository.order(id: orderID) { return order }
            if attempt < 5 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        return nil
    }
}
