import Foundation
import Observation

@MainActor
@Observable
final class HomeViewModel {
    enum RequestState: Equatable {
        case idle
        case listening
        case finding
        case clarification(ClarificationQuestion)
    }

    var query = ""
    var requestState: RequestState = .idle
    var listState: LoadableState<ActiveList> = .idle
    var errorMessage: String?
    var isOffline = false

    let userID: UUID
    private let parser: any IntentParsingService
    private let speech: any SpeechTranscriptionService
    private let listStore: any ActiveListStore
    private let preferenceService: any PreferenceService
    private let analytics: any AnalyticsService
    private let router: AppRouter
    private let beginReplacement: @MainActor (ActiveListItem) -> Void

    init(
        userID: UUID,
        parser: any IntentParsingService,
        speech: any SpeechTranscriptionService,
        listStore: any ActiveListStore,
        preferenceService: any PreferenceService,
        analytics: any AnalyticsService,
        router: AppRouter,
        beginReplacement: @escaping @MainActor (ActiveListItem) -> Void = { _ in }
    ) {
        self.userID = userID
        self.parser = parser
        self.speech = speech
        self.listStore = listStore
        self.preferenceService = preferenceService
        self.analytics = analytics
        self.router = router
        self.beginReplacement = beginReplacement
    }

    var currentList: ActiveList? {
        switch listState {
        case let .loaded(list), let .offline(.some(list)): list
        default: nil
        }
    }

    var canSubmit: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && requestState != .finding
    }

    func loadList() async {
        if currentList == nil { listState = .loading }
        do {
            let list = try await listStore.currentList(for: userID)
            listState = list.items.isEmpty ? .loaded(list) : .loaded(list)
            isOffline = false
        } catch let error as AppError where error == .offline {
            isOffline = true
            listState = .offline(currentList)
        } catch {
            listState = .failed(message: "We couldn't load your current list.")
        }
    }

    func submit(source: Need.Source = .text) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, requestState != .finding else { return }
        requestState = .finding
        errorMessage = nil

        do {
            let intent = try await parser.parse(text)
            if let clarification = intent.clarification {
                requestState = .clarification(clarification)
            } else {
                query = ""
                requestState = .idle
                router.navigate(to: .candidates(intent))
                await analytics.track(
                    source == .voice ? .voiceNeedCreated : .needCreated,
                    properties: ["category": intent.category]
                )
            }
        } catch let error as AppError where error == .offline {
            isOffline = true
            requestState = .idle
            errorMessage = "Connect to the internet to find products. Your current list is safe."
        } catch {
            requestState = .idle
            errorMessage = "We couldn't understand that request. Try saying it another way."
        }
    }

    func answerClarification(_ option: String) async {
        guard case let .clarification(question) = requestState else { return }
        query += " \(question.attributeKey): \(option)"
        requestState = .idle
        await submit()
    }

    func toggleVoice() async {
        if requestState == .listening {
            speech.stopTranscribing()
            query = speech.transcript
            requestState = .idle
            await submit(source: .voice)
            return
        }

        guard requestState == .idle else { return }
        let allowed = await speech.requestAuthorization()
        guard allowed else {
            errorMessage = "Microphone and speech access are needed to add an item by voice."
            return
        }

        do {
            try speech.startTranscribing()
            requestState = .listening
        } catch {
            errorMessage = "We couldn't start listening. You can type your item instead."
        }
    }

    func syncTranscript() async {
        guard requestState == .listening else { return }
        query = speech.transcript
        if !speech.isListening, !query.isEmpty {
            requestState = .idle
            await submit(source: .voice)
        }
    }

    func updateQuantity(item: ActiveListItem, quantity: Int) async {
        do {
            let list = try await listStore.updateQuantity(itemID: item.id, quantity: quantity, userID: userID)
            listState = .loaded(list)
        } catch {
            errorMessage = "We couldn't update that quantity."
        }
    }

    func remove(item: ActiveListItem) async {
        do {
            let list = try await listStore.remove(itemID: item.id, userID: userID)
            listState = .loaded(list)
            _ = try? await preferenceService.recordSignal(
                userID: userID,
                product: item.product,
                kind: .removal,
                idempotencyKey: "removal:\(item.id.uuidString)",
                expectedMemoryEpoch: nil
            )
            await analytics.track(.itemRemoved, properties: ["category": item.intent.category])
        } catch {
            errorMessage = "We couldn't remove that item."
        }
    }

    func replace(item: ActiveListItem) {
        beginReplacement(item)
        router.navigate(to: .candidates(item.intent))
    }

    func checkout() {
        guard let list = currentList, !list.items.isEmpty else { return }
        router.navigate(to: .checkout(listID: list.id))
    }
}
