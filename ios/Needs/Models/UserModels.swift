import Foundation

public struct UserProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var email: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, email: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.email = email
        self.createdAt = createdAt
    }

    public static let demo = UserProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "John",
        email: "john@example.com"
    )
}

public struct UserSession: Codable, Hashable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let profile: UserProfile

    public init(accessToken: String, refreshToken: String, expiresAt: Date, profile: UserProfile) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.profile = profile
    }
}

public struct AppleAuthRequest: Sendable {
    public let identityToken: Data
    public let authorizationCode: Data?
    public let rawNonce: String
    public let givenName: String?
    public let familyName: String?

    public init(
        identityToken: Data,
        authorizationCode: Data?,
        rawNonce: String,
        givenName: String? = nil,
        familyName: String? = nil
    ) {
        self.identityToken = identityToken
        self.authorizationCode = authorizationCode
        self.rawNonce = rawNonce
        self.givenName = givenName
        self.familyName = familyName
    }
}

public struct Address: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var street: String
    public var apartment: String?
    public var city: String
    public var postalCode: String
    public var region: String
    public var country: String
    public var isDefault: Bool

    public init(
        id: UUID = UUID(),
        street: String,
        apartment: String? = nil,
        city: String,
        postalCode: String,
        region: String,
        country: String = "US",
        isDefault: Bool = true
    ) {
        self.id = id
        self.street = street
        self.apartment = apartment
        self.city = city
        self.postalCode = postalCode
        self.region = region
        self.country = country
        self.isDefault = isDefault
    }

    public var singleLine: String {
        [street, apartment, city, region, postalCode].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: ", ")
    }

    public static let demo = Address(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        street: "123 Market Street",
        city: "San Francisco",
        postalCode: "94105",
        region: "CA"
    )
}
