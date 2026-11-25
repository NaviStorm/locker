import Foundation
import Security
import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

final class LocalVaultRemovalTests: VaultTestCase {
    func testOfflineRemovalOnlyAffectsTheConfirmedSlotAndCanFinishAfterInterruption() async throws {
        let base = location("vaults"), slot = UUID().uuidString
        let root = base.appendingPathComponent(slot)
        let keys = VaultKeys()
        let store = try VaultStore(root: root, keys: keys, create: true)
        _ = try await store.importData(Data([1]), name: "Document fictif")
        let other = try VaultStore(root: base.appendingPathComponent(UUID().uuidString), keys: keys, create: true)
        let keep = try await other.importData(Data([2]), name: "À garder")
        XCTAssertEqual(VaultKind.cached(in: root), .personal)
        do { _ = try await store.retireUnsharedVault(in: base, slot: other.root.lastPathComponent); XCTFail("Mauvais coffre") }
        catch VaultError.unavailable {}
        let removal = try await store.retireUnsharedVault(in: base, slot: slot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertThrowsError(try store.gate.check())
        XCTAssertThrowsError(try removal.finish(removeItem: { _ in throw VaultError.unavailable }))
        let resumed = try XCTUnwrap(LocalVaultRemoval(directory: removal.directory))
        var accounts = [String]()
        final class MockDefaults: UserDefaults {
            override func removeObject(forKey name: String) {}
        }
        try resumed.finish(removeItem: { query in
            accounts.append(try XCTUnwrap(query[kSecAttrAccount as String] as? String))
        }, preferences: MockDefaults())
        XCTAssertEqual(Set(accounts), [slot, "identity-" + slot + "-" + keys.identifier, "oauth-stage-" + slot])
        XCTAssertFalse(FileManager.default.fileExists(atPath: removal.directory.path))
        let data = try await other.preview(keep)
        XCTAssertEqual(data, Data([2]))
    }

    func testFamilyNameMigrationAndProtectionEvenWithOutdatedHintOrSession() async throws {
        let base = location("vaults"), slot = UUID().uuidString
        let root = base.appendingPathComponent(slot), keys = VaultKeys()
        let owner = try DeviceIdentity(hardware: false), guest = try DeviceIdentity(hardware: false)
        let host = try VaultStore(root: root, keys: keys, create: true)
        let stale = try VaultStore(root: root, keys: keys)
        try await host.createFamily(using: owner)
        XCTAssertEqual(VaultKind.cached(in: root), .unsharedFamily)
        try await host.changeMembership(card: guest.card, role: .reader, scope: nil, using: owner)
        XCTAssertEqual(VaultKind.cached(in: root), .family)
        VaultKind.personal.cache(in: root)
        do { _ = try await stale.retireUnsharedVault(in: base, slot: slot); XCTFail("Partage supprimé") }
        catch is TransportError {}
        try FileManager.default.removeItem(at: root.appendingPathComponent("kind.v1"))
        let reopened = try VaultStore(root: root, keys: keys)
        XCTAssertEqual(VaultKind.cached(in: root)?.title, "Coffre familial")
        let family = await reopened.family
        let ticket = try FamilyInvitation.make(state: XCTUnwrap(family), for: guest.card, by: owner)
        let guestSlot = UUID().uuidString
        let joined = try VaultStore(root: base.appendingPathComponent(guestSlot), keys: VaultKeys(), create: true)
        try await joined.joinFamily(ticket, from: owner.card, using: guest)
        XCTAssertEqual(VaultKind.cached(in: base.appendingPathComponent(guestSlot)), .family)
        do { _ = try await joined.retireUnsharedVault(in: base, slot: guestSlot); XCTFail("Coffre rejoint supprimé") }
        catch is TransportError {}
        try joined.gate.check()
        try reopened.gate.check()
    }

    func testFamilyWithoutAnInviteCanBeRemovedAndLockedStoreCannot() async throws {
        let base = location("vaults"), slot = UUID().uuidString
        let root = base.appendingPathComponent(slot), keys = VaultKeys()
        let store = try VaultStore(root: root, keys: keys, create: true)
        try await store.createFamily(using: DeviceIdentity(hardware: false))
        store.gate.revoke()
        do { _ = try await store.retireUnsharedVault(in: base, slot: slot); XCTFail("Suppression verrouillée") }
        catch VaultError.locked {}
        let reopened = try VaultStore(root: root, keys: keys)
        _ = try await reopened.retireUnsharedVault(in: base, slot: slot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
