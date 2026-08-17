import Foundation
import Security

public actor KeychainSessionStore: SessionStore {
    private let service: String
    private let account: String

    public init(service: String = "com.tychi.mobile.needs", account: String = "user-session") {
        self.service = service
        self.account = account
    }

    public func load() async throws -> UserSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppError.underlying("Keychain read failed with status \(status)")
        }
        return try NeedsJSON.decoder().decode(UserSession.self, from: data)
    }

    public func save(_ session: UserSession) async throws {
        let data = try NeedsJSON.encoder().encode(session)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = baseQuery
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AppError.underlying("Keychain write failed with status \(addStatus)")
            }
        } else if status != errSecSuccess {
            throw AppError.underlying("Keychain update failed with status \(status)")
        }
    }

    public func clear() async throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.underlying("Keychain delete failed with status \(status)")
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
