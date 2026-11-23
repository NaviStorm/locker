import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

final class KeysTests: XCTestCase {
    func testRecoveryAndTypingError() throws {
        let keys = VaultKeys()
        XCTAssertEqual(try VaultKeys(code: keys.recoveryCode).secret, keys.secret)
        XCTAssertNotEqual(keys.identifier, VaultKeys().identifier)
        XCTAssertThrowsError(try VaultKeys(code: String(keys.recoveryCode.dropLast()) + "!"))
        XCTAssertThrowsError(try VaultKeys(secret: Data()))
    }
}
