import Foundation

public actor MockAuthService: AuthService {
    private let sessionStore: any SessionStore
    private var pendingEmail: String?
    private let demoProfile: UserProfile

    public init(sessionStore: any SessionStore, demoProfile: UserProfile = .demo) {
        self.sessionStore = sessionStore
        self.demoProfile = demoProfile
    }

    public func restoreSession() async throws -> UserSession? {
        try await sessionStore.load()
    }

    public func signInWithApple(request: AppleAuthRequest) async throws -> UserSession {
        guard !request.identityToken.isEmpty else { throw AppError.invalidInput("Missing identity token") }
        guard !request.rawNonce.isEmpty else { throw AppError.invalidInput("Missing sign-in nonce") }
        let fullName = [request.givenName, request.familyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let profile = UserProfile(
            id: demoProfile.id,
            name: fullName.isEmpty ? demoProfile.name : fullName,
            email: demoProfile.email,
            createdAt: demoProfile.createdAt
        )
        let session = makeSession(profile: profile)
        try await sessionStore.save(session)
        return session
    }

    public func sendEmailCode(to email: String) async throws {
        guard email.contains("@"), email.contains(".") else { throw AppError.invalidInput("Invalid email") }
        pendingEmail = email.lowercased()
    }

    public func verifyEmailCode(email: String, code: String) async throws -> UserSession {
        guard pendingEmail == email.lowercased(), code == "123456" else {
            throw AppError.invalidInput("Invalid verification code")
        }
        let profile = UserProfile(id: demoProfile.id, name: demoProfile.name, email: email.lowercased())
        let session = makeSession(profile: profile)
        pendingEmail = nil
        try await sessionStore.save(session)
        return session
    }

    public func signOut() async throws {
        pendingEmail = nil
        try await sessionStore.clear()
    }

    public func deleteAccount() async throws {
        pendingEmail = nil
        try await sessionStore.clear()
    }

    private func makeSession(profile: UserProfile) -> UserSession {
        UserSession(
            accessToken: "development-access-\(UUID().uuidString)",
            refreshToken: "development-refresh-\(UUID().uuidString)",
            expiresAt: .now.addingTimeInterval(60 * 60),
            profile: profile
        )
    }
}

public actor InMemorySessionStore: SessionStore {
    private var session: UserSession?
    public init(session: UserSession? = nil) { self.session = session }
    public func load() async throws -> UserSession? { session }
    public func save(_ session: UserSession) async throws { self.session = session }
    public func clear() async throws { session = nil }
}
