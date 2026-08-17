import Foundation

public enum PreferencePersistence: Hashable, Sendable {
    case ephemeral
    case userDefaults(suiteName: String?)
}

private struct PreferenceUserState: Codable, Sendable {
    var memoryEpoch: Int = 0
    var events: [PreferenceEvent] = []
    var processedIdempotencyKeys: Set<String> = []
}

public actor DeterministicPreferenceService: PreferenceService {
    private let defaults: UserDefaults?
    private let storageKey: String
    private let now: @Sendable () -> Date
    private var states: [UUID: PreferenceUserState]
    private let rankingEngine = ProductRankingEngine()

    public init(
        persistence: PreferencePersistence = .ephemeral,
        storageKey: String = "needs.product-memory.v1",
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.storageKey = storageKey
        self.now = now
        switch persistence {
        case .ephemeral:
            self.defaults = nil
            self.states = [:]
        case .userDefaults(let suiteName):
            let store = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
            self.defaults = store
            if let data = store.data(forKey: storageKey),
               let decoded = try? NeedsJSON.decoder().decode([UUID: PreferenceUserState].self, from: data) {
                self.states = decoded
            } else {
                self.states = [:]
            }
        }
    }

    @discardableResult
    public func recordSignal(
        userID: UUID,
        product: ProductCandidate,
        kind: PreferenceSignalKind,
        idempotencyKey: String,
        expectedMemoryEpoch: Int? = nil
    ) async throws -> LearnedPreferenceSummary {
        var state = states[userID] ?? PreferenceUserState()
        if let expectedMemoryEpoch, expectedMemoryEpoch != state.memoryEpoch {
            throw AppError.conflict("Stale memory epoch \(expectedMemoryEpoch); current epoch is \(state.memoryEpoch)")
        }
        if state.processedIdempotencyKeys.contains(idempotencyKey) {
            return makeSummary(userID: userID, state: state)
        }

        state.events.append(PreferenceEvent(
            userID: userID,
            product: product,
            kind: kind,
            memoryEpoch: state.memoryEpoch,
            occurredAt: now(),
            idempotencyKey: idempotencyKey
        ))
        state.processedIdempotencyKeys.insert(idempotencyKey)
        states[userID] = state
        persist()
        return makeSummary(userID: userID, state: state)
    }

    public func summary(for userID: UUID) async -> LearnedPreferenceSummary {
        makeSummary(userID: userID, state: states[userID] ?? PreferenceUserState())
    }

    public func rankCandidates(
        _ candidates: [ProductCandidate],
        for intent: NeedIntent,
        userID: UUID,
        useLearnedPreferences: Bool
    ) async -> [ProductCandidate] {
        let memory = makeSummary(userID: userID, state: states[userID] ?? PreferenceUserState())
        return rankingEngine.rank(
            candidates: candidates,
            for: intent,
            memory: memory,
            useLearnedPreferences: useLearnedPreferences
        )
    }

    public func removePreference(userID: UUID, preferenceID: String) async throws -> LearnedPreferenceSummary {
        var state = states[userID] ?? PreferenceUserState()
        guard let preference = makeSummary(userID: userID, state: state).entries.first(where: { $0.id == preferenceID }) else {
            throw AppError.notFound
        }
        state.memoryEpoch += 1
        state.events.removeAll { event in
            guard event.category == preference.category else { return false }
            switch preference.dimension {
            case .brand: return event.brand == preference.value
            case .size: return event.size == preference.value
            case .attribute: return event.attributes[preference.key] == preference.value
            }
        }
        states[userID] = state
        persist()
        return makeSummary(userID: userID, state: state)
    }

    public func resetProductMemory(userID: UUID) async throws -> LearnedPreferenceSummary {
        var state = states[userID] ?? PreferenceUserState()
        state.memoryEpoch += 1
        state.events.removeAll()
        states[userID] = state
        persist()
        return makeSummary(userID: userID, state: state)
    }

    private func makeSummary(userID: UUID, state: PreferenceUserState) -> LearnedPreferenceSummary {
        struct Aggregate {
            var score: Double = 0
            var count: Int = 0
        }

        let currentDate = now()
        var aggregates: [String: Aggregate] = [:]
        var descriptors: [String: (String, PreferenceDimension, String, String)] = [:]
        var positivePrices: [String: [(Decimal, String)]] = [:]

        func add(category: String, dimension: PreferenceDimension, key: String, value: String, weight: Double) {
            let aggregateKey = "\(category)|\(dimension.rawValue)|\(key)|\(value)"
            var aggregate = aggregates[aggregateKey] ?? Aggregate()
            aggregate.score += weight
            aggregate.count += 1
            aggregates[aggregateKey] = aggregate
            descriptors[aggregateKey] = (category, dimension, key, value)
        }

        for event in state.events where event.memoryEpoch <= state.memoryEpoch {
            let age = max(0, currentDate.timeIntervalSince(event.occurredAt))
            let ageInDays = age / 86_400
            let decay = pow(0.5, ageInDays / 180)
            let weight = event.kind.baseWeight * decay
            add(category: event.category, dimension: .brand, key: "brand", value: event.brand, weight: weight)
            if !event.size.isEmpty {
                add(category: event.category, dimension: .size, key: "size", value: event.size, weight: weight)
            }
            for (key, value) in event.attributes {
                add(category: event.category, dimension: .attribute, key: key, value: value, weight: weight)
            }
            if event.kind == .selection || event.kind == .purchase {
                positivePrices[event.category, default: []].append((event.price, event.currency))
            }
        }

        let entries = aggregates.compactMap { aggregateKey, aggregate -> LearnedPreference? in
            guard abs(aggregate.score) >= 0.01,
                  let descriptor = descriptors[aggregateKey] else { return nil }
            return LearnedPreference(
                category: descriptor.0,
                dimension: descriptor.1,
                key: descriptor.2,
                value: descriptor.3,
                score: aggregate.score,
                signalCount: aggregate.count
            )
        }.sorted { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            if abs(lhs.score) != abs(rhs.score) { return abs(lhs.score) > abs(rhs.score) }
            return lhs.id < rhs.id
        }

        let priceProfiles = positivePrices.compactMapValues { values -> AcceptedPriceProfile? in
            guard values.count >= 3, let currency = values.first?.1,
                  values.allSatisfy({ $0.1 == currency }) else { return nil }
            let sorted = values.map(\.0).sorted()
            return AcceptedPriceProfile(
                currency: currency,
                median: percentile(sorted, fraction: 0.5),
                lowerBound: percentile(sorted, fraction: 0.25),
                upperBound: percentile(sorted, fraction: 0.75),
                positiveSignalCount: sorted.count
            )
        }

        return LearnedPreferenceSummary(
            userID: userID,
            memoryEpoch: state.memoryEpoch,
            entries: entries,
            acceptedPricesByCategory: priceProfiles,
            updatedAt: currentDate
        )
    }

    private func percentile(_ sorted: [Decimal], fraction: Double) -> Decimal {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private func persist() {
        guard let defaults, let data = try? NeedsJSON.encoder().encode(states) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

public struct ProductRankingEngine: Sendable {
    public init() {}

    public func rank(
        candidates: [ProductCandidate],
        for intent: NeedIntent,
        memory: LearnedPreferenceSummary,
        useLearnedPreferences: Bool
    ) -> [ProductCandidate] {
        let eligible = candidates.filter {
            $0.availability.isPurchasable && !$0.isExplicitlyIncompatible && $0.category == intent.category
        }
        guard !eligible.isEmpty else { return [] }

        struct Scored {
            var product: ProductCandidate
            let adjustedScore: Double
        }

        let scored = eligible.map { product -> Scored in
            let adjustment = useLearnedPreferences ? memoryAdjustment(for: product, memory: memory) : 0
            return Scored(product: product, adjustedScore: product.matchScore + adjustment)
        }
        let ranked = scored.sorted { lhs, rhs in
            // History can reorder compatible choices, but cannot cross an intent-match tier.
            if lhs.product.matchTier != rhs.product.matchTier { return lhs.product.matchTier > rhs.product.matchTier }
            if lhs.adjustedScore != rhs.adjustedScore { return lhs.adjustedScore > rhs.adjustedScore }
            if lhs.product.price != rhs.product.price { return lhs.product.price < rhs.product.price }
            return lhs.product.id.uuidString < rhs.product.id.uuidString
        }

        var selected: [ProductCandidate] = []
        var used = Set<UUID>()

        if var best = ranked.first?.product {
            best.kind = .bestMatch
            selected.append(best)
            used.insert(best.id)
        }

        let strongRemaining = ranked.filter { !used.contains($0.product.id) && $0.product.matchTier >= .strong }
        let valuePool = strongRemaining.isEmpty ? ranked.filter { !used.contains($0.product.id) } : strongRemaining
        let highestPrice = valuePool
            .map { NSDecimalNumber(decimal: $0.product.price).doubleValue }
            .max() ?? 1
        let valueChoice = valuePool.sorted { lhs, rhs in
            let lhsPrice = NSDecimalNumber(decimal: lhs.product.price).doubleValue
            let rhsPrice = NSDecimalNumber(decimal: rhs.product.price).doubleValue
            let lhsAffordability = highestPrice > 0 ? 1 - (lhsPrice / highestPrice) : 0
            let rhsAffordability = highestPrice > 0 ? 1 - (rhsPrice / highestPrice) : 0
            let lhsValue = lhs.product.matchScore * 0.75 + lhsAffordability * 0.25
            let rhsValue = rhs.product.matchScore * 0.75 + rhsAffordability * 0.25
            if lhsValue != rhsValue { return lhsValue > rhsValue }
            return lhs.product.id.uuidString < rhs.product.id.uuidString
        }.first
        if var value = valueChoice?.product {
            value.kind = .bestValue
            selected.append(value)
            used.insert(value.id)
        }

        let favoriteBrand = useLearnedPreferences ? memory.strongestBrand(in: intent.category) : nil
        let remaining = ranked.filter { !used.contains($0.product.id) }
        let discovery = remaining.first(where: { candidate in
            guard let favoriteBrand else { return true }
            return candidate.product.brand.caseInsensitiveCompare(favoriteBrand) != .orderedSame
        }) ?? remaining.first
        if var product = discovery?.product {
            product.kind = .discovery
            selected.append(product)
        }

        return Array(selected.prefix(3))
    }

    private func memoryAdjustment(for product: ProductCandidate, memory: LearnedPreferenceSummary) -> Double {
        var affinity = 0.0
        for entry in memory.entries where entry.category == product.category {
            switch entry.dimension {
            case .brand where entry.value.caseInsensitiveCompare(product.brand) == .orderedSame:
                affinity += entry.score
            case .size where entry.value.caseInsensitiveCompare(product.size) == .orderedSame:
                affinity += entry.score * 0.5
            case .attribute where product.attributes[entry.key]?.caseInsensitiveCompare(entry.value) == .orderedSame:
                affinity += entry.score * 0.35
            default:
                continue
            }
        }

        var adjustment = tanh(affinity / 3) * 0.1
        if let price = memory.acceptedPricesByCategory[product.category], price.currency == product.currency {
            if product.price <= price.upperBound { adjustment += 0.01 }
            else { adjustment -= 0.02 }
        }
        return min(max(adjustment, -0.1), 0.1)
    }
}
