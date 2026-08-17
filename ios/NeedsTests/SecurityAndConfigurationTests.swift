import XCTest
@testable import Needs

final class SecurityAndConfigurationTests: XCTestCase {
    func testAppleNonceUsesSHA256AndSecureLength() throws {
        let nonce = try AppleSignInNonce.generate(length: 32)
        XCTAssertEqual(nonce.rawValue.count, 32)
        XCTAssertEqual(nonce.sha256.count, 64)
        XCTAssertNotEqual(nonce.rawValue, nonce.sha256)
        XCTAssertTrue(nonce.sha256.allSatisfy { $0.isHexDigit })
    }

    @MainActor
    func testConnectedContainerFailsClosedWithoutPublicConfiguration() {
        let configuration = PublicConfiguration(
            environment: .production,
            backendURL: nil,
            publishableKey: nil
        )
        XCTAssertThrowsError(try DependencyContainer.make(configuration: configuration))
    }
}
