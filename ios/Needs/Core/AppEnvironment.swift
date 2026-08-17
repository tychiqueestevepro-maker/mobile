import Foundation

public enum AppEnvironment: String, Codable, CaseIterable, Sendable {
    case development
    case staging
    case production
}

/// Values in this type are safe to ship in the application bundle. Provider
/// credentials and signing keys deliberately have no representation here.
public struct PublicConfiguration: Codable, Hashable, Sendable {
    public var environment: AppEnvironment
    public var backendURL: URL?
    public var publishableKey: String?
    public var storeKitProductIdentifier: String
    public var applePayMerchantIdentifier: String?
    public var deepLinkScheme: String

    public init(
        environment: AppEnvironment,
        backendURL: URL? = nil,
        publishableKey: String? = nil,
        storeKitProductIdentifier: String = "com.tychi.mobile.plus.monthly",
        applePayMerchantIdentifier: String? = nil,
        deepLinkScheme: String = "app"
    ) {
        self.environment = environment
        self.backendURL = backendURL
        self.publishableKey = publishableKey
        self.storeKitProductIdentifier = storeKitProductIdentifier
        self.applePayMerchantIdentifier = applePayMerchantIdentifier
        self.deepLinkScheme = deepLinkScheme
    }

    public static let development = PublicConfiguration(environment: .development)

    public static func runtime(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) throws -> PublicConfiguration {
        let rawEnvironment = processInfo.environment["NEEDS_ENVIRONMENT"]
            ?? bundle.object(forInfoDictionaryKey: "NeedsEnvironment") as? String
            ?? AppEnvironment.development.rawValue
        guard let environment = AppEnvironment(rawValue: rawEnvironment.lowercased()) else {
            throw AppError.configurationMissing("Unknown app environment: \(rawEnvironment)")
        }
        if environment == .development { return .development }

        let rawURL = (processInfo.environment["NEEDS_BACKEND_URL"]
            ?? bundle.object(forInfoDictionaryKey: "NeedsBackendURL") as? String
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (processInfo.environment["NEEDS_PUBLISHABLE_KEY"]
            ?? bundle.object(forInfoDictionaryKey: "NeedsPublishableKey") as? String
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawMerchant = (processInfo.environment["NEEDS_MERCHANT_IDENTIFIER"]
            ?? bundle.object(forInfoDictionaryKey: "NeedsMerchantIdentifier") as? String
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let merchant = rawMerchant.flatMap { $0.isEmpty ? nil : $0 }
        let product = bundle.object(forInfoDictionaryKey: "NeedsPlusProductIdentifier") as? String
            ?? "com.tychi.mobile.plus.monthly"
        guard let rawURL, !rawURL.isEmpty,
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false,
              let key, !key.isEmpty else {
            throw AppError.configurationMissing("Connected environment is missing public configuration")
        }
        return PublicConfiguration(
            environment: environment,
            backendURL: url,
            publishableKey: key,
            storeKitProductIdentifier: product,
            applePayMerchantIdentifier: merchant
        )
    }
}
