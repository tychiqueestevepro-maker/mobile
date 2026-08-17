import Foundation

public actor MockDeliveryProvider: DeliveryProvider {
    private let creationRegistry = IdempotencyRegistry<Delivery>()
    private let transitionDelays: [TimeInterval]
    private var deliveries: [UUID: Delivery] = [:]
    private var continuations: [UUID: [UUID: AsyncStream<Delivery>.Continuation]] = [:]
    private var simulationTasks: [UUID: Task<Void, Never>] = [:]
    private var shouldFailCreation = false

    public init(transitionDelays: [TimeInterval] = [2, 2, 3, 3, 3]) {
        self.transitionDelays = transitionDelays
    }

    public func setShouldFailCreation(_ shouldFail: Bool) { shouldFailCreation = shouldFail }

    public func quote(for order: Order) async throws -> DeliveryQuote {
        let pickup = Date.now.addingTimeInterval(12 * 60)
        return DeliveryQuote(
            fee: order.deliveryFee,
            currency: order.currency,
            estimatedPickupAt: pickup,
            estimatedDeliveryAt: pickup.addingTimeInterval(25 * 60),
            expiresAt: .now.addingTimeInterval(10 * 60)
        )
    }

    public func createDelivery(for order: Order, quote: DeliveryQuote, idempotencyKey: String) async throws -> Delivery {
        let shouldFail = shouldFailCreation
        let created = try await creationRegistry.perform(key: idempotencyKey) {
            if shouldFail { throw AppError.unavailable("Delivery could not be created") }
            return Delivery(
                orderID: order.id,
                status: .confirmed,
                estimatedArrival: quote.estimatedDeliveryAt,
                externalReference: "delivery_\(UUID().uuidString)"
            )
        }
        deliveries[created.id] = created
        if simulationTasks[created.id] == nil {
            simulationTasks[created.id] = Task { [weak self] in
                await self?.simulate(deliveryID: created.id)
            }
        }
        return created
    }

    public func cancelDelivery(id: UUID) async throws {
        guard var delivery = deliveries[id] else { throw AppError.notFound }
        simulationTasks[id]?.cancel()
        delivery.status = .cancelled
        delivery.updatedAt = .now
        deliveries[id] = delivery
        publish(delivery)
        finishStreams(for: id)
    }

    public func delivery(id: UUID) async -> Delivery? { deliveries[id] }

    public func updates(for id: UUID) async -> AsyncStream<Delivery> {
        let (stream, continuation) = AsyncStream<Delivery>.makeStream()
        let observerID = UUID()
        continuations[id, default: [:]][observerID] = continuation
        if let current = deliveries[id] { continuation.yield(current) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(deliveryID: id, observerID: observerID) }
        }
        return stream
    }

    private func simulate(deliveryID: UUID) async {
        let statuses: [DeliveryStatus] = [.courierAssigned, .pickedUp, .onTheWay, .arriving, .delivered]
        for (index, status) in statuses.enumerated() {
            let delay = index < transitionDelays.count ? transitionDelays[index] : 0
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard var delivery = deliveries[deliveryID], !Task.isCancelled else { return }
            delivery.status = status
            delivery.updatedAt = .now
            if status == .courierAssigned {
                delivery.courierFirstName = "Sam"
                delivery.vehicleDescription = "Silver hatchback"
            }
            deliveries[deliveryID] = delivery
            publish(delivery)
        }
        finishStreams(for: deliveryID)
        simulationTasks[deliveryID] = nil
    }

    private func publish(_ delivery: Delivery) {
        continuations[delivery.id]?.values.forEach { $0.yield(delivery) }
    }

    private func finishStreams(for id: UUID) {
        continuations[id]?.values.forEach { $0.finish() }
        continuations[id] = nil
    }

    private func removeContinuation(deliveryID: UUID, observerID: UUID) {
        continuations[deliveryID]?[observerID] = nil
        if continuations[deliveryID]?.isEmpty == true { continuations[deliveryID] = nil }
    }
}

public enum DeliveryStatusMapper {
    public static func normalizedStatus(from providerStatus: String) -> DeliveryStatus {
        switch providerStatus.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "pending", "created": .pending
        case "confirmed", "accepted": .confirmed
        case "courier_assigned", "driver_assigned": .courierAssigned
        case "courier_heading_to_pickup", "en_route_to_pickup": .courierHeadingToPickup
        case "picked_up", "pickup_complete": .pickedUp
        case "on_the_way", "en_route_to_dropoff": .onTheWay
        case "arriving", "near_dropoff": .arriving
        case "delivered", "complete": .delivered
        case "cancelled", "canceled": .cancelled
        default: .failed
        }
    }
}
