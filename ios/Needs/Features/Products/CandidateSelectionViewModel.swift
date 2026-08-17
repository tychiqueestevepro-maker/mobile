import Foundation
import Observation

@MainActor
@Observable
final class CandidateSelectionViewModel {
    let intent: NeedIntent
    var candidates: LoadableState<[ProductCandidate]> = .idle
    var selectedID: UUID?
    var isSaving = false
    var errorMessage: String?

    private let search: @MainActor (NeedIntent) async throws -> [ProductCandidate]
    private let select: @MainActor (NeedIntent, ProductCandidate) async throws -> Void
    private let reject: @MainActor (NeedIntent, ProductCandidate) async -> Void
    private let completed: @MainActor () -> Void

    init(
        intent: NeedIntent,
        search: @escaping @MainActor (NeedIntent) async throws -> [ProductCandidate],
        select: @escaping @MainActor (NeedIntent, ProductCandidate) async throws -> Void,
        reject: @escaping @MainActor (NeedIntent, ProductCandidate) async -> Void = { _, _ in },
        completed: @escaping @MainActor () -> Void
    ) {
        self.intent = intent
        self.search = search
        self.select = select
        self.reject = reject
        self.completed = completed
    }

    var title: String {
        intent.normalizedQuery
            .split(separator: " ")
            .prefix(4)
            .map(String.init)
            .joined(separator: " ")
            .capitalized
    }

    func load() async {
        guard candidates == .idle || isFailure else { return }
        candidates = .loading
        errorMessage = nil
        do {
            let results = Array(try await search(intent).prefix(3))
            candidates = results.isEmpty ? .empty : .loaded(results)
        } catch let error as AppError where error == .offline {
            candidates = .offline(nil)
        } catch {
            candidates = .failed(message: "We couldn't find products right now.")
        }
    }

    func choose(_ product: ProductCandidate) async {
        guard !isSaving else { return }
        isSaving = true
        selectedID = product.id
        errorMessage = nil
        do {
            try await select(intent, product)
            try? await Task.sleep(for: .milliseconds(650))
            completed()
        } catch {
            selectedID = nil
            errorMessage = "We couldn't add that item. Please try again."
        }
        isSaving = false
    }

    func explicitlyReject(_ product: ProductCandidate) async {
        await reject(intent, product)
        guard case let .loaded(current) = candidates else { return }
        let remaining = current.filter { $0.id != product.id }
        candidates = remaining.isEmpty ? .empty : .loaded(remaining)
    }

    private var isFailure: Bool {
        switch candidates {
        case .failed, .offline: true
        default: false
        }
    }
}

