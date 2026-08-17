import SwiftUI

struct NeedsRootView: View {
    @State var model: NeedsAppModel

    var body: some View {
        switch model.phase {
        case .launching:
            LaunchView()
        case let .onboarding(onboardingModel):
            OnboardingFlowView(model: onboardingModel)
        case .ready:
            ReadyRootView(model: model)
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: NeedsSpacing.large) {
            NeedsLogo()
            ProgressView()
                .tint(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NeedsTheme.background)
        .accessibilityIdentifier("app.launching")
    }
}

private struct ReadyRootView: View {
    @State var model: NeedsAppModel

    var body: some View {
        @Bindable var router = model.router

        NavigationStack(path: $router.path) {
            TabView(selection: $router.selectedTab) {
                if let homeModel = model.homeModel {
                    HomeView(model: homeModel, isPlus: model.isPlus) {
                        model.router.navigate(to: .plus)
                    }
                    .tag(AppTab.home)
                    .tabItem {
                        Label("tab.home", systemImage: "house")
                            .accessibilityIdentifier("tab.home")
                    }
                }

                if let ordersModel = model.ordersModel {
                    OrdersView(model: ordersModel)
                        .tag(AppTab.orders)
                        .tabItem {
                            Label("tab.orders", systemImage: "bag")
                                .accessibilityIdentifier("tab.orders")
                        }
                }

                if let settingsModel = model.settingsModel {
                    SettingsView(model: settingsModel)
                        .tag(AppTab.settings)
                        .tabItem {
                            Label("tab.settings", systemImage: "gearshape")
                                .accessibilityIdentifier("tab.settings")
                        }
                }
            }
            .onChange(of: router.selectedTab) { _, tab in
                Task {
                    switch tab {
                    case .home:
                        await model.homeModel?.loadList()
                    case .orders:
                        await model.ordersModel?.load()
                    case .settings:
                        await model.settingsModel?.load()
                    }
                }
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .home:
                    EmptyView()
                case let .candidates(intent):
                    CandidateSelectionView(model: model.candidateModel(for: intent))
                case let .checkout(listID):
                    CheckoutView(model: model.checkoutModel(listID: listID))
                case let .order(id):
                    TrackingView(model: model.trackingModel(orderID: id))
                case .plus:
                    PlusView(model: model.plusModel())
                case .settings:
                    EmptyView()
                }
            }
        }
    }
}
