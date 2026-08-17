import Foundation
import Observation

public enum AppTab: String, Codable, CaseIterable, Hashable, Sendable {
    case home
    case orders
    case settings
}

public enum AppRoute: Hashable, Codable, Sendable {
    case home
    case candidates(NeedIntent)
    case checkout(listID: UUID)
    case order(id: UUID)
    case plus
    case settings

    public init?(deepLink url: URL) {
        guard url.scheme?.lowercased() == "app" else { return nil }
        let host = url.host?.lowercased()

        switch host {
        case "home":
            self = .home
        case "checkout":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard let rawID = components?.queryItems?.first(where: { $0.name == "list_id" })?.value,
                  let id = UUID(uuidString: rawID) else { return nil }
            self = .checkout(listID: id)
        case "order":
            guard let rawID = url.pathComponents.dropFirst().first,
                  let id = UUID(uuidString: rawID) else { return nil }
            self = .order(id: id)
        case "plus":
            self = .plus
        case "settings":
            self = .settings
        default:
            return nil
        }
    }
}

@MainActor
@Observable
public final class AppRouter {
    public var selectedTab: AppTab
    public var path: [AppRoute]

    public init(selectedTab: AppTab = .home, path: [AppRoute] = []) {
        self.selectedTab = selectedTab
        self.path = path
    }

    public func navigate(to route: AppRoute) {
        switch route {
        case .home:
            selectedTab = .home
            path.removeAll()
        case .settings:
            selectedTab = .settings
            path.removeAll()
        default:
            path.append(route)
        }
    }

    @discardableResult
    public func handle(url: URL) -> Bool {
        guard let route = AppRoute(deepLink: url) else { return false }
        navigate(to: route)
        return true
    }

    public func popToRoot() {
        path.removeAll()
    }
}
