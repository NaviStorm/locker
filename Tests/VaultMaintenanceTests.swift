import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

final class VaultMaintenanceTests: VaultTestCase {
    func testOfflineBackupVerificationAndAtomicRestore() async throws {
        let keys = VaultKeys()
        let source = try VaultStore(root: location("source"), keys: keys, create: true)
        let folder = try await source.createFolder("Contrats fictifs")
        let first = try await source.importData(Data("texte confidentiel fictif".utf8), name: "note-fictive.txt", folder: folder)
        let latest = try await source.importData(Data(repeating: 91, count: BlockCipher.chunk + 17), name: "note-fictive.txt", versionOf: first)
        let removed = try await source.importData(Data([77]), name: "À récupérer")
        try await source.trashDocument(removed)
        let backup = try await source.writeBackup(in: location("."))
        let raw = try Data(contentsOf: backup)
        for plaintext in ["note-fictive.txt", "Contrats fictifs", "texte confidentiel fictif", keys.recoveryCode] {
            XCTAssertNil(raw.range(of: Data(plaintext.utf8)))
        }
        let targetRoot = location("copie")
        let copyKeys = VaultKeys()
        let target = try VaultStore(root: targetRoot, keys: copyKeys, create: true)
        let catalog = targetRoot.appendingPathComponent("catalog.v1")
        let initial = try Data(contentsOf: catalog)
        let verified = try await target.readBackup(backup, code: keys.recoveryCode, restore: false)
        XCTAssertEqual(verified, 4)
        XCTAssertEqual(try Data(contentsOf: catalog), initial)
        do { _ = try await target.readBackup(backup, code: copyKeys.recoveryCode, restore: true); XCTFail("Code erroné accepté") }
        catch is TransportError {}
        var broken = raw
        broken[broken.count - 1] ^= 1
        let bad = location("altérée.lockerbackup")
        try broken.write(to: bad)
        do { _ = try await target.readBackup(bad, code: keys.recoveryCode, restore: true); XCTFail("Bloc altéré accepté") } catch {}
        XCTAssertEqual(try Data(contentsOf: catalog), initial)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: targetRoot.path).contains { $0.hasSuffix(".blob") })
        _ = try await target.readBackup(backup, code: keys.recoveryCode, restore: true)
        let reopened = try VaultStore(root: targetRoot, keys: copyKeys)
        let library = try await reopened.library()
        XCTAssertEqual(library.folders, [folder])
        XCTAssertEqual(library.versions(of: first).map(\.id), [latest, first])
        let contents = try await reopened.preview(first)
        XCTAssertEqual(contents, Data("texte confidentiel fictif".utf8))
        let trash = try await reopened.trashItems()
        XCTAssertEqual(trash.map(\.name), ["À récupérer"])
        do { _ = try await reopened.readBackup(backup, code: keys.recoveryCode, restore: true); XCTFail("Coffre existant écrasé") }
        catch is TransportError {}
    }

    func testFolderTrashAndRestoreOnAnotherDevice() async throws {
        let keys = VaultKeys()
        let first = try VaultStore(root: location("premier"), keys: keys, create: true)
        let other = try VaultStore(root: location("autre"), keys: keys, create: true)
        let bucket = FakeBucket()
        let a = try ObjectReplica(bucket: bucket, cache: location("cacheA"), gate: first.gate)
        let b = try ObjectReplica(bucket: bucket, cache: location("cacheB"), gate: other.gate)
        let folder = try await first.createFolder("Famille")
        let inner = try await first.createFolder("Photos", in: folder)
        let id = try await first.importData(Data([1]), name: "souvenir", folder: inner)
        let version = try await first.importData(Data([2]), name: "souvenir", versionOf: id)
        try await first.synchronize(with: a)
        try await other.synchronize(with: b)
        try await first.deleteFolder(folder)
        try await first.synchronize(with: a)
        try await other.synchronize(with: b)
        let hidden = try await other.library()
        XCTAssertTrue(hidden.documents.isEmpty && hidden.folders.isEmpty)
        let items = try await other.trashItems()
        XCTAssertEqual(items.count, 1)
        try await other.restoreTrash(XCTUnwrap(items.first))
        try await other.synchronize(with: b)
        try await first.synchronize(with: a)
        let restored = try await first.library()
        XCTAssertEqual(Set(restored.folders), [folder, inner])
        XCTAssertEqual(restored.versions(of: id).map(\.id), [version, id])
        XCTAssertEqual(restored.documents(in: inner).first?.id, version)
        let meter = first.syncProgress.snapshot
        XCTAssertEqual(meter.completed, meter.total)
        try await first.trashDocument(version)
        let deleted = try await first.trashItems()
        try await first.purgeTrash(XCTUnwrap(deleted.first))
        try await first.synchronize(with: a)
        try await other.synchronize(with: b)
        let remaining = try await other.trashItems()
        let documents = try await other.list()
        XCTAssertTrue(remaining.isEmpty && documents.isEmpty)
    }

    func testMemberNamesAndRemovalReasonsSurviveRestart() async throws {
        let keys = VaultKeys()
        let root = location("partage")
        let host = try VaultStore(root: root, keys: keys, create: true)
        let owner = try DeviceIdentity(hardware: false)
        let peer = try DeviceIdentity(hardware: false)
        try await host.createFamily(using: owner)
        try await host.changeMembership(card: peer.card, role: .reader, scope: nil, using: owner)
        try await host.nameDevice(peer.card.fingerprint, name: "Mac de Camille")
        let reopened = try VaultStore(root: root, keys: keys)
        let named = try await reopened.removalProtectionReason()
        XCTAssertTrue(named?.contains("Mac de Camille") == true)
        try await reopened.changeMembership(card: peer.card, role: nil, scope: nil, using: owner)
        let pending = try await reopened.removalProtectionReason()
        XCTAssertTrue(pending?.contains("synchronisation") == true)
        try await reopened.synchronizeFamily(bucket: FakeBucket(), identity: owner)
        let clear = try await reopened.removalProtectionReason()
        XCTAssertNil(clear)
    }

    func testSharedTrashHonorsRightsAndBackupContainsOnlyAuthorizedFiles() async throws {
        let host = try VaultStore(root: location("administrateur"), keys: VaultKeys(), create: true)
        let guestKeys = VaultKeys()
        let guest = try VaultStore(root: location("lecteur"), keys: guestKeys, create: true)
        let owner = try DeviceIdentity(hardware: false)
        let peer = try DeviceIdentity(hardware: false)
        let bucket = FakeBucket()
        try await host.createFamily(using: owner)
        let shared = try await host.importData(Data([1]), name: "Visible")
        _ = try await host.importData(Data([2]), name: "Privé")
        try await host.changeMembership(card: peer.card, role: .reader, scope: [shared], using: owner)
        let state = await host.family
        let ticket = try FamilyInvitation.make(state: XCTUnwrap(state), for: peer.card, by: owner)
        try await guest.joinFamily(ticket, from: owner.card, using: peer)
        try await host.synchronizeFamily(bucket: bucket, identity: owner)
        try await guest.synchronizeFamily(bucket: bucket, identity: peer)
        let backup = try await guest.writeBackup(in: location("."))
        let restored = try VaultStore(root: location("copie"), keys: VaultKeys(), create: true)
        let count = try await restored.readBackup(backup, code: guestKeys.recoveryCode, restore: true)
        XCTAssertEqual(count, 1)
        let visible = try await restored.list()
        XCTAssertEqual(visible.map(\.id), [shared])
        let restoredMembers = try await restored.members()
        XCTAssertTrue(restoredMembers.isEmpty)
        try await host.trashDocument(shared)
        try await host.synchronizeFamily(bucket: bucket, identity: owner)
        try await guest.synchronizeFamily(bucket: bucket, identity: peer)
        let trash = try await guest.trashItems()
        let item = try XCTUnwrap(trash.first)
        do { try await guest.restoreTrash(item); XCTFail("Restauration en lecture seule") }
        catch FamilyError.denied {}
        do { try await guest.purgeTrash(item); XCTFail("Suppression en lecture seule") }
        catch FamilyError.denied {}
        try await host.restoreTrash(item)
        try await host.synchronizeFamily(bucket: bucket, identity: owner)
        try await guest.synchronizeFamily(bucket: bucket, identity: peer)
        let files = try await guest.list()
        XCTAssertEqual(files.map(\.id), [shared])
    }

    func testLastSuccessIsPersistentAndSpecificToProvider() async throws {
        let keys = VaultKeys()
        let root = location("rapports")
        let store = try VaultStore(root: root, keys: keys, create: true)
        let initial = try await store.lastSuccessfulSync()
        XCTAssertNil(initial)
        try await store.recordSuccessfulSync(for: ProviderSettings().destination)
        try await store.configure(ProviderSettings(provider: .cloud), credential: nil)
        let cloud = try await store.lastSuccessfulSync()
        XCTAssertNil(cloud)
        let reopened = try VaultStore(root: root, keys: keys)
        try await reopened.configure(ProviderSettings(), credential: nil)
        let remembered = try await reopened.lastSuccessfulSync()
        XCTAssertNotNil(remembered)
    }
}
