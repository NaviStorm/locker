import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

final class VaultSecretTests: XCTestCase {
    func testPINAndPasswordRules() throws {
        let pin = VaultAuthenticationMethod.numericCode
        for invalid in ["", "123456789", "123456789a", "12345 67890", "１２３４５６７８９０"] {
            XCTAssertThrowsError(try pin.validateNewSecret(invalid))
        }
        try pin.validateNewSecret("0123456789")
        try pin.validateNewSecret("001234567890123")
        let password = VaultAuthenticationMethod.vaultPassword
        for invalid in ["Aa3!trop", "sansmajuscule4!", "TOUTENMAJUSCULE4!", "SansChiffres!", "SansSymbole123", "Password123!", "Aa3!Aa3!Aa3!", "Bleu7!Bleu7!", "Passw0rd123!"] {
            XCTAssertThrowsError(try password.validateNewSecret(invalid))
        }
        try password.validateNewSecret("Voile!Azur72")
    }

    func testWrappedKeyRequiresExactSecretAndVault() throws {
        let keys = VaultKeys()
        let pin = "0164598237"
        let raw = try WrappedVaultKey.make(keys: keys, secret: pin, method: .numericCode, account: "test-A")
        let second = try WrappedVaultKey.make(keys: keys, secret: pin, method: .numericCode, account: "test-A")
        let envelope = try JSONDecoder().decode(WrappedVaultKey.self, from: raw)
        let other = try JSONDecoder().decode(WrappedVaultKey.self, from: second)
        XCTAssertNotEqual(envelope.salt, other.salt)
        XCTAssertNotEqual(envelope.sealed, other.sealed)
        XCTAssertNil(raw.range(of: Data(pin.utf8)))
        XCTAssertEqual(try envelope.open(secret: pin, account: "test-A").secret, keys.secret)
        XCTAssertThrowsError(try envelope.open(secret: "164598237", account: "test-A"))
        XCTAssertThrowsError(try envelope.open(secret: pin, account: "test-B"))
        var damaged = envelope.sealed
        damaged[damaged.count - 1] ^= 1
        let altered = WrappedVaultKey(version: 1, method: .numericCode, salt: envelope.salt, sealed: damaged)
        XCTAssertThrowsError(try altered.open(secret: pin, account: "test-A"))
    }

    func testPasswordSupportsAccentsAndPreservesWhitespace() throws {
        let keys = VaultKeys()
        let password = "  Érable#Ciel73"
        let raw = try WrappedVaultKey.make(keys: keys, secret: password, method: .vaultPassword, account: "test-C")
        let envelope = try JSONDecoder().decode(WrappedVaultKey.self, from: raw)
        XCTAssertEqual(try envelope.open(secret: password.decomposedStringWithCanonicalMapping, account: "test-C").secret, keys.secret)
        XCTAssertThrowsError(try envelope.open(secret: String(password.dropFirst(2)), account: "test-C"))
    }
}
