import CryptoKit
import Foundation
import Security

public struct AppleSignInNonce: Equatable, Sendable {
    public let rawValue: String
    public let sha256: String

    public init(rawValue: String) {
        self.rawValue = rawValue
        self.sha256 = SHA256.hash(data: Data(rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func generate(length: Int = 32) throws -> AppleSignInNonce {
        precondition(length > 0)
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var random = [UInt8](repeating: 0, count: 16)

        while result.count < length {
            let status = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
            guard status == errSecSuccess else {
                throw AppError.underlying("Secure random generation failed with status \(status)")
            }
            for byte in random where result.count < length {
                if byte < UInt8(alphabet.count) { result.append(alphabet[Int(byte)]) }
            }
        }
        return AppleSignInNonce(rawValue: result)
    }
}
