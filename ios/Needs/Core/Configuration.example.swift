import Foundation

/// Copy the values relevant to the selected build configuration. Only public
/// client configuration belongs in this file.
public enum ConfigurationExample {
    public static let staging = PublicConfiguration(
        environment: .staging,
        backendURL: URL(string: "https://YOUR_PROJECT.example.co"),
        publishableKey: "YOUR_PUBLIC_CLIENT_KEY",
        storeKitProductIdentifier: "com.tychi.mobile.plus.monthly",
        applePayMerchantIdentifier: "merchant.com.example.needs",
        deepLinkScheme: "app"
    )
}
