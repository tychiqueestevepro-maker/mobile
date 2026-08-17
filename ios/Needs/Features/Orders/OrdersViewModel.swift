import Foundation
import Observation

@MainActor
@Observable
final class OrdersViewModel {
    var state: LoadableState<[Order]> = .idle

    private let userID: UUID
    private let repository: any OrderRepository
    private let router: AppRouter

    init(userID: UUID, repository: any OrderRepository, router: AppRouter) {
        self.userID = userID
        self.repository = repository
        self.router = router
    }

    var activeOrders: [Order] {
        orders.filter { ![.delivered, .cancelled, .failed].contains($0.status) }
    }

    var pastOrders: [Order] {
        orders.filter { [.delivered, .cancelled, .failed].contains($0.status) }
    }

    func load() async {
        if orders.isEmpty { state = .loading }
        let loaded = await repository.orders(for: userID)
        state = loaded.isEmpty ? .empty : .loaded(loaded)
    }

    func open(_ order: Order) {
        router.navigate(to: .order(id: order.id))
    }

    private var orders: [Order] {
        guard case let .loaded(orders) = state else { return [] }
        return orders
    }
}

