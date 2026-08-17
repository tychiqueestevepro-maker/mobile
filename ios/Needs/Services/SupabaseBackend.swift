import Foundation
import Supabase

public enum SupabaseClientFactory {
    public static func make(configuration: PublicConfiguration) throws -> SupabaseClient {
        guard configuration.environment != .development else {
            throw AppError.configurationMissing("Use development dependencies for the development environment")
        }
        guard let url = configuration.backendURL,
              let key = configuration.publishableKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty,
              !key.contains("YOUR_"),
              !key.lowercased().contains("service_role") else {
            throw AppError.configurationMissing("A public backend URL and publishable key are required")
        }
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw AppError.configurationMissing("Connected environments require HTTPS")
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }
}

public struct BackendErrorPayload: Decodable, Sendable {
    public let code: String
    public let message: String
    public let details: String?
}

private struct BackendEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    let data: Value?
    let error: BackendErrorPayload?
}

public struct IgnoredBackendResponse: Decodable, Sendable {
    public init(from decoder: any Decoder) throws {}
}

public actor BackendAPIClient {
    public let configuration: PublicConfiguration
    public let supabase: SupabaseClient
    private let session: URLSession

    public init(
        configuration: PublicConfiguration,
        supabase: SupabaseClient,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.supabase = supabase
        self.session = session
    }

    public func call<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ operation: String,
        body: Input,
        as outputType: Output.Type = Output.self
    ) async throws -> Output {
        guard let baseURL = configuration.backendURL,
              let publishableKey = configuration.publishableKey,
              !operation.isEmpty,
              !operation.contains("/") else {
            throw AppError.configurationMissing("Backend operation is not configured")
        }
        let authSession: Session
        do { authSession = try await supabase.auth.session }
        catch { throw AppError.authenticationRequired }

        let url = baseURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent(operation)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authSession.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("needs-ios/1", forHTTPHeaderField: "x-client-info")
        request.httpBody = try NeedsJSON.encoder().encode(body)

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw AppError.offline
        } catch {
            throw AppError.underlying("Network request failed: \(error)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.underlying("Invalid backend response")
        }
        let envelope: BackendEnvelope<Output>
        do { envelope = try NeedsJSON.decoder().decode(BackendEnvelope<Output>.self, from: data) }
        catch { throw AppError.underlying("Backend response could not be decoded: \(error)") }

        guard (200..<300).contains(http.statusCode), let value = envelope.data else {
            let message = envelope.error?.message ?? "Request failed with status \(http.statusCode)"
            switch http.statusCode {
            case 401, 403: throw AppError.authenticationRequired
            case 404: throw AppError.notFound
            case 409: throw AppError.conflict(message)
            case 400..<500: throw AppError.invalidInput(message)
            default: throw AppError.underlying(message)
            }
        }
        return value
    }
}

public actor SupabaseAuthService: AuthService {
    private struct EmptyRequest: Encodable, Sendable {}

    private let client: SupabaseClient
    private let backend: BackendAPIClient
    private let sessionStore: any SessionStore

    public init(client: SupabaseClient, backend: BackendAPIClient, sessionStore: any SessionStore) {
        self.client = client
        self.backend = backend
        self.sessionStore = sessionStore
    }

    public func restoreSession() async throws -> UserSession? {
        do {
            let session = try await client.auth.session
            let result = map(session: session, preferredName: nil)
            try await sessionStore.save(result)
            return result
        } catch {
            try? await sessionStore.clear()
            return nil
        }
    }

    public func signInWithApple(request: AppleAuthRequest) async throws -> UserSession {
        guard let idToken = String(data: request.identityToken, encoding: .utf8),
              !idToken.isEmpty,
              !request.rawNonce.isEmpty else { throw AppError.invalidInput("Invalid Apple credential") }
        let session = try await client.auth.signInWithIdToken(credentials: OpenIDConnectCredentials(
            provider: .apple,
            idToken: idToken,
            nonce: request.rawNonce
        ))
        let fullName = [request.givenName, request.familyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !fullName.isEmpty {
            struct ProfileName: Encodable { let display_name: String }
            try? await client.from("profiles")
                .update(ProfileName(display_name: fullName))
                .eq("user_id", value: session.user.id)
                .execute()
        }
        let result = map(session: session, preferredName: fullName)
        try await sessionStore.save(result)
        return result
    }

    public func sendEmailCode(to email: String) async throws {
        guard email.contains("@") else { throw AppError.invalidInput("Invalid email") }
        try await client.auth.signInWithOTP(email: email)
    }

    public func verifyEmailCode(email: String, code: String) async throws -> UserSession {
        let response = try await client.auth.verifyOTP(email: email, token: code, type: .email)
        let session: Session
        switch response {
        case .session(let value): session = value
        case .user: session = try await client.auth.session
        }
        let result = map(session: session, preferredName: nil)
        try await sessionStore.save(result)
        return result
    }

    public func signOut() async throws {
        try await client.auth.signOut()
        try await sessionStore.clear()
    }

    public func deleteAccount() async throws {
        _ = try await backend.call("delete-account", body: EmptyRequest(), as: IgnoredBackendResponse.self)
        try await client.auth.signOut()
        try await sessionStore.clear()
    }

    private func map(session: Session, preferredName: String?) -> UserSession {
        let email = session.user.email ?? ""
        let fallbackName = email.split(separator: "@").first.map(String.init)?.capitalized ?? "Member"
        return UserSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: Date(timeIntervalSince1970: session.expiresAt),
            profile: UserProfile(
                id: session.user.id,
                name: preferredName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
                email: email,
                createdAt: session.user.createdAt
            )
        )
    }
}

public actor BackendSubscriptionSyncService: SubscriptionSyncService {
    private struct Request: Encodable, Sendable {
        let signed_transaction_info: String
        let app_account_token: UUID
    }
    private let api: BackendAPIClient

    public init(api: BackendAPIClient) { self.api = api }

    public func syncVerifiedTransaction(jwsRepresentation: String, appAccountToken: UUID) async throws {
        _ = try await api.call(
            "sync-subscription",
            body: Request(signed_transaction_info: jwsRepresentation, app_account_token: appAccountToken),
            as: IgnoredBackendResponse.self
        )
    }
}

public actor MockSubscriptionSyncService: SubscriptionSyncService {
    public private(set) var syncedTransactions: [String] = []
    public init() {}
    public func syncVerifiedTransaction(jwsRepresentation: String, appAccountToken: UUID) async throws {
        syncedTransactions.append(jwsRepresentation)
    }
}

public struct StaticAppAccountTokenProvider: AppAccountTokenProvider {
    private let token: UUID
    public init(token: UUID) { self.token = token }
    public func appAccountToken() async throws -> UUID { token }
}

public actor SupabaseAppAccountTokenProvider: AppAccountTokenProvider {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }
    public func appAccountToken() async throws -> UUID {
        do {
            let session = try await client.auth.session
            return session.user.id
        }
        catch { throw AppError.authenticationRequired }
    }
}

public actor SupabaseEntitlementService: EntitlementService {
    private let client: SupabaseClient
    private var cached: Entitlements = .free

    public init(client: SupabaseClient) { self.client = client }
    public func currentEntitlements() async -> Entitlements {
        (try? await refresh()) ?? cached
    }

    public func refresh() async throws -> Entitlements {
        let hasPlus: Bool = try await client.rpc("has_plus_entitlement").execute().value
        cached = hasPlus ? .plus : .free
        return cached
    }
}
