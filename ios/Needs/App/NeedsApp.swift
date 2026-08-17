import SwiftUI
import UserNotifications
import UIKit

@main
@MainActor
struct NeedsApp: App {
    @UIApplicationDelegateAdaptor(NeedsAppDelegate.self) private var appDelegate
    @State private var model: NeedsAppModel?
    private let startupMessage: String?

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-UITesting")
        if isUITesting {
            let container = DependencyContainer.development(persistentStorage: false)
            _model = State(initialValue: NeedsAppModel(container: container))
            startupMessage = nil
        } else {
            do {
                let container = try DependencyContainer.runtime()
                _model = State(initialValue: NeedsAppModel(container: container))
                startupMessage = nil
            } catch {
                _model = State(initialValue: nil)
                startupMessage = "This build is missing required configuration. Install a configured build or contact support."
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    NeedsRootView(model: model)
                        .task { await model.start() }
                        .onOpenURL { url in model.handle(url: url) }
                        .onReceive(NotificationCenter.default.publisher(for: .needsDeepLink)) { notification in
                            guard let url = notification.object as? URL else { return }
                            model.handle(url: url)
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .needsDeviceToken)) { notification in
                            guard let token = notification.object as? Data else { return }
                            Task { await model.register(deviceToken: token) }
                        }
                } else {
                    ConfigurationUnavailableView(message: startupMessage ?? "This build can't start safely.")
                }
            }
            .preferredColorScheme(nil)
            .tint(.primary)
        }
    }
}

private struct ConfigurationUnavailableView: View {
    let message: String

    var body: some View {
        StateMessageView(
            systemImage: "exclamationmark.shield",
            title: "Needs isn't ready",
            message: message
        )
        .background(NeedsTheme.background)
        .accessibilityIdentifier("app.configuration_error")
    }
}

@MainActor
final class NeedsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .needsDeviceToken, object: deviceToken)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = NotificationDeepLinkResolver.route(from: response.notification.request.content.userInfo) else { return }
        let url: URL?
        switch route {
        case .home:
            url = URL(string: "app://home")
        case let .checkout(listID):
            url = URL(string: "app://checkout?list_id=\(listID.uuidString)")
        case let .order(id):
            url = URL(string: "app://order/\(id.uuidString)")
        case .plus:
            url = URL(string: "app://plus")
        case .settings:
            url = URL(string: "app://settings")
        case .candidates:
            url = nil
        }
        if let url {
            NotificationCenter.default.post(name: .needsDeepLink, object: url)
        }
    }
}

extension Notification.Name {
    static let needsDeepLink = Notification.Name("needs.app.deep-link")
    static let needsDeviceToken = Notification.Name("needs.app.device-token")
}
