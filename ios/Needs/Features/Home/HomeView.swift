import SwiftUI

struct HomeView: View {
    @State var model: HomeViewModel
    let isPlus: Bool
    let showPlus: () -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NeedsSpacing.large) {
                header
                requestInput

                if model.isOffline {
                    offlineBanner
                }

                if let error = model.errorMessage {
                    InlineErrorView(message: error) {
                        model.errorMessage = nil
                    }
                }

                clarification
                currentListContent
            }
            .needsPage()
            .padding(.top, NeedsSpacing.medium)
            .padding(.bottom, model.currentList?.items.isEmpty == false ? 110 : NeedsSpacing.xLarge)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(NeedsTheme.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let list = model.currentList, !list.items.isEmpty {
                ListCheckoutBar(list: list, isPlus: isPlus, checkout: model.checkout, showPlus: showPlus)
            }
        }
        .task { await model.loadList() }
        .task(id: model.requestState) {
            guard model.requestState == .listening else { return }
            while !Task.isCancelled && model.requestState == .listening {
                await model.syncTranscript()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        .refreshable { await model.loadList() }
    }

    private var header: some View {
        HStack {
            NeedsLogo(compact: true)
            Spacer()
            if isPlus {
                Text("Plus")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(NeedsTheme.surface, in: Capsule())
                    .accessibilityLabel("Plus membership active")
            }
        }
    }

    private var requestInput: some View {
        VStack(alignment: .leading, spacing: NeedsSpacing.medium) {
            Text("home.title")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .accessibilityIdentifier("home.title")

            HStack(spacing: NeedsSpacing.small) {
                TextField("home.input", text: $model.query, axis: .vertical)
                    .font(.title3)
                    .lineLimit(1...3)
                    .submitLabel(.search)
                    .focused($inputFocused)
                    .onSubmit { Task { await model.submit() } }
                    .disabled(model.requestState == .finding)
                    .accessibilityIdentifier("home.input")

                Button {
                    Task { await model.toggleVoice() }
                } label: {
                    Image(systemName: model.requestState == .listening ? "stop.fill" : "mic.fill")
                        .font(.headline)
                        .frame(width: 46, height: 46)
                        .foregroundStyle(model.requestState == .listening ? NeedsTheme.background : .primary)
                        .background(model.requestState == .listening ? Color.primary : NeedsTheme.background, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.requestState == .listening ? "Stop listening" : "Add by voice")
                .accessibilityIdentifier("home.microphone")

                if model.canSubmit && model.requestState != .listening {
                    Button {
                        inputFocused = false
                        Task { await model.submit() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.headline.bold())
                            .frame(width: 46, height: 46)
                            .foregroundStyle(NeedsTheme.background)
                            .background(Color.primary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Find products")
                    .accessibilityIdentifier("home.submit")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(NeedsSpacing.small)
            .padding(.leading, NeedsSpacing.xSmall)
            .background(NeedsTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                if model.requestState == .listening {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.primary.opacity(0.4), lineWidth: 2)
                }
            }

            switch model.requestState {
            case .listening:
                Label("home.listening", systemImage: "waveform")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .accessibilityIdentifier("home.listening_label")
            case .finding:
                HStack(spacing: NeedsSpacing.small) {
                    ProgressView()
                    Text("home.finding")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("home.finding")
            default:
                EmptyView()
            }
        }
        .animation(.smooth, value: model.requestState)
    }

    @ViewBuilder
    private var clarification: some View {
        if case let .clarification(question) = model.requestState {
            VStack(alignment: .leading, spacing: NeedsSpacing.medium) {
                Text(question.prompt)
                    .font(.headline)
                FlowLayout(spacing: NeedsSpacing.small) {
                    ForEach(question.options.prefix(5), id: \.self) { option in
                        Button(option) {
                            Task { await model.answerClarification(option) }
                        }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                    }
                }
            }
            .needsCard()
            .accessibilityIdentifier("home.clarification")
        }
    }

    @ViewBuilder
    private var currentListContent: some View {
        VStack(alignment: .leading, spacing: NeedsSpacing.medium) {
            Text("home.list")
                .font(.title2.bold())
                .accessibilityIdentifier("home.current_list")

            switch model.listState {
            case .idle, .loading:
                LoadingRowsView(count: 2)
            case let .loaded(list), let .offline(.some(list)):
                if list.items.isEmpty {
                    Text("home.empty_list")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, NeedsSpacing.large)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.items.enumerated()), id: \.element.id) { index, item in
                            CurrentListRow(
                                item: item,
                                change: { model.replace(item: item) },
                                decrement: { Task { await model.updateQuantity(item: item, quantity: item.quantity - 1) } },
                                increment: { Task { await model.updateQuantity(item: item, quantity: item.quantity + 1) } },
                                remove: { Task { await model.remove(item: item) } }
                            )
                            if index < list.items.count - 1 {
                                Divider().padding(.leading, 72)
                            }
                        }
                    }
                    .background(NeedsTheme.surface, in: RoundedRectangle(cornerRadius: NeedsTheme.cardRadius, style: .continuous))
                    .accessibilityIdentifier("home.list.items")
                }
            case .empty:
                Text("home.empty_list")
                    .foregroundStyle(.secondary)
            case .offline(.none):
                StateMessageView(
                    systemImage: "wifi.slash",
                    title: "You're offline",
                    message: "Your current list will appear when the local cache is ready.",
                    retryTitle: "common.retry"
                ) { Task { await model.loadList() } }
            case let .failed(message):
                StateMessageView(
                    systemImage: "exclamationmark.circle",
                    title: "List unavailable",
                    message: message,
                    retryTitle: "common.retry"
                ) { Task { await model.loadList() } }
            }
        }
    }

    private var offlineBanner: some View {
        Label("home.offline", systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .needsCard()
            .accessibilityIdentifier("home.offline")
    }
}

private struct CurrentListRow: View {
    let item: ActiveListItem
    let change: () -> Void
    let decrement: () -> Void
    let increment: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: NeedsSpacing.small) {
            ProductArtwork(imageURL: item.product.imageURL, category: item.product.category, size: 54)

            Button(action: change) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.intent.normalizedQuery.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(item.product.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(CurrencyFormatter.string(amount: item.lineTotal, currency: item.product.currency))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose a different product")

            Menu {
                Button(action: increment) { Label("Add one", systemImage: "plus") }
                if item.quantity > 1 {
                    Button(action: decrement) { Label("Remove one", systemImage: "minus") }
                }
                Divider()
                Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") }
            } label: {
                Text("×\(item.quantity)")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 38, minHeight: 38)
                    .background(NeedsTheme.background, in: Capsule())
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("Quantity \(item.quantity)")
        }
        .padding(NeedsSpacing.small)
        .accessibilityIdentifier("list.item.\(item.id.uuidString)")
        .swipeActions {
            Button(role: .destructive, action: remove) {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

private struct ListCheckoutBar: View {
    let list: ActiveList
    let isPlus: Bool
    let checkout: () -> Void
    let showPlus: () -> Void

    var body: some View {
        VStack(spacing: NeedsSpacing.small) {
            HStack {
                HStack(spacing: 4) {
                    Text("\(list.itemCount) \(list.itemCount == 1 ? "item" : "items")")
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(list.formattedSubtotal)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("home.checkout_summary")
                Spacer()
                if !isPlus {
                    Button("See Plus", action: showPlus)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.semibold))

            PrimaryButton(title: isPlus ? "list.optimize" : "list.get_now", action: checkout)
                .accessibilityIdentifier("home.checkout")
        }
        .padding(.horizontal, NeedsTheme.pageInset)
        .padding(.top, NeedsSpacing.small)
        .padding(.bottom, NeedsSpacing.small)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var points: [CGPoint] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: proposal.width ?? x, height: y + lineHeight), points)
    }
}
