import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

final class IdentityTests: XCTestCase {
    func testRecipientAndSenderBinding() throws {
        let alice = try DeviceIdentity(hardware: false)
        let bob = try DeviceIdentity(hardware: false)
        let eve = try DeviceIdentity(hardware: false)
        let secret = VaultKeys().secret
        let sealed = try SealedGrant(secret, for: bob.card)
        let signed = try SignedObject(sealed, by: alice, domain: "invitation")
        XCTAssertNil(signed.bytes.range(of: secret))
        let checked = try signed.verified(SealedGrant.self, by: alice.card, domain: "invitation")
        XCTAssertEqual(try bob.decrypt(checked), secret)
        XCTAssertThrowsError(try eve.decrypt(checked))
        XCTAssertThrowsError(try signed.verified(SealedGrant.self, by: eve.card, domain: "invitation"))
        XCTAssertThrowsError(try signed.verified(SealedGrant.self, by: alice.card, domain: "opération"))
        XCTAssertEqual(try PublicIdentity(card: alice.card.card).fingerprint, alice.card.fingerprint)
    }
}
