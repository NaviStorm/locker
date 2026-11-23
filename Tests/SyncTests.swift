import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

private actor MemoryReplica: VaultReplica {
    var records: [UUID: RemoteDocument] = [:]
    let root: URL
    var available = true
    var conflictOnce = false

    init(root: URL) { self.root = root }
    func offline(_ value: Bool) { available = !value }
    func rejectNextWrite() { conflictOnce = true }
    func identifiers() throws -> Set<UUID> {
        guard available else { throw URLError(.notConnectedToInternet) }
        return Set(records.keys)
    }
    func fetch(_ id: UUID, withFile: Bool) -> RemoteDocument? { records[id] }
    func put(_ id: UUID, envelope: Data, file: URL?, replacing version: String?) throws {
        if conflictOnce { conflictOnce = false; throw ReplicaError.conflict }
        guard records[id]?.version == version else { throw ReplicaError.conflict }
        let copy = file.map { _ in root.appendingPathComponent(UUID().uuidString) }
        if let file, let copy { try FileManager.default.copyItem(at: file, to: copy) }
        if let prior = records[id]?.file { try FileManager.default.removeItem(at: prior) }
        records[id] = RemoteDocument(version: UUID().uuidString, envelope: envelope, file: copy)
    }
}

final class SyncTests: VaultTestCase {
    func testTwoDevicesConflictOfflineDeletionAndRetry() async throws {
        let keys = VaultKeys()
        let a = try VaultStore(root: location("a"), keys: keys, create: true)
        let b = try VaultStore(root: location("b"), keys: VaultKeys(code: keys.recoveryCode), create: true)
        let cloud = MemoryReplica(root: location("."))
        let data = Data("Fichier médical fictif".utf8)
        let id = try await a.importData(data, name: "exemple.txt")
        await cloud.offline(true)
        do { try await a.synchronize(with: cloud); XCTFail("Réseau indisponible") } catch {}
        await cloud.offline(false)
        await cloud.rejectNextWrite()
        try await a.synchronize(with: cloud)
        let remote = await cloud.fetch(id, withFile: true)
        XCTAssertNil(remote?.envelope.range(of: Data("exemple.txt".utf8)))
        XCTAssertNil(try Data(contentsOf: XCTUnwrap(remote?.file)).range(of: data))
        try await b.synchronize(with: cloud)
        let copy = try await b.preview(id)
        XCTAssertEqual(copy, data)
        try await a.change(id, labels: Labels(name: "version A"))
        try await b.change(id, labels: Labels(name: "version B"))
        try await a.synchronize(with: cloud)
        try await b.synchronize(with: cloud)
        try await a.synchronize(with: cloud)
        let left = try await a.list()
        let right = try await b.list()
        XCTAssertEqual(left, right)
        try await a.change(id, labels: nil)
        try await b.change(id, labels: Labels(name: "retard"))
        try await a.synchronize(with: cloud)
        try await b.synchronize(with: cloud)
        let final = try await b.list()
        XCTAssertTrue(final.isEmpty)
        let deleted = await cloud.fetch(id, withFile: true)
        XCTAssertNil(deleted?.file)
    }

    func testFoldersSurviveOfflineReopeningAndSync() async throws {
        let keys = VaultKeys()
        let root = location("origine")
        let store = try VaultStore(root: root, keys: keys, create: true)
        let name = try await store.createFolder("  Archives fictives  ")
        XCTAssertEqual(name, "Archives fictives")
        for invalid in ["  ", "archives fictives"] {
            do { _ = try await store.createFolder(invalid); XCTFail("Nom accepté") } catch {}
        }
        let scan = try await store.importData(Data([1]), name: "scan", folder: name)
        let source = location("document.txt")
        try Data([2]).write(to: source)
        let version = try await store.importFile(source, versionOf: scan)
        let imported = try await store.importCoordinated(source, parent: nil, folder: name)
        let library = try await store.library()
        XCTAssertEqual(library.documents.map(\.labels.folder), [name, name, name])
        try await store.change(scan, labels: Labels(name: "scan", folder: "Ancien classement"))
        try await store.change(version, labels: nil)
        try await store.change(imported, labels: nil)
        let reopened = try VaultStore(root: root, keys: keys)
        let offline = try await reopened.library()
        XCTAssertEqual(offline.folders, ["Ancien classement", name])
        XCTAssertEqual(offline.documents.count, 1)
        XCTAssertNil(try Data(contentsOf: root.appendingPathComponent("catalog.v1")).range(of: Data(name.utf8)))
        let replica = MemoryReplica(root: location("."))
        let other = try VaultStore(root: location("copie"), keys: keys, create: true)
        try await reopened.synchronize(with: replica)
        try await other.synchronize(with: replica)
        let synced = try await other.library()
        XCTAssertEqual(synced.folders, offline.folders)
        XCTAssertEqual(synced.documents, offline.documents)
    }

    func testForeignVaultCannotReadCloud() async throws {
        let cloud = MemoryReplica(root: location("."))
        let a = try VaultStore(root: location("a"), keys: VaultKeys(), create: true)
        _ = try await a.importData(Data([1]), name: "A")
        try await a.synchronize(with: cloud)
        let b = try VaultStore(root: location("b"), keys: VaultKeys(), create: true)
        do { try await b.synchronize(with: cloud); XCTFail("Clé étrangère acceptée") } catch {}
        let result = try await b.list()
        XCTAssertTrue(result.isEmpty)
    }
}
