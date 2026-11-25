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

    func testRenameMoveAndDeleteSelectedDocumentOffline() async throws {
        let keys = VaultKeys()
        let root = location("local")
        let store = try VaultStore(root: root, keys: keys, create: true)
        let replica = MemoryReplica(root: location("."))
        let peer = try VaultStore(root: location("distant"), keys: keys, create: true)
        let folder = try await store.createFolder("Archives")
        let first = try await store.importData(Data([1]), name: "ancienne.txt")
        let source = location("nouvelle.txt")
        try Data([2]).write(to: source)
        let id = try await store.importFile(source, versionOf: first)
        try await store.change(id, labels: Labels(name: "nouvelle.txt", category: "Facture", notes: "Fictif"))
        try await store.synchronize(with: replica)
        try await peer.synchronize(with: replica)
        await replica.offline(true)
        for invalid in [" ", "../essai", ".", "..", "a\0b"] {
            do { try await store.renameDocument(id, to: invalid); XCTFail("Nom accepté") } catch {}
        }
        do { try await store.moveDocument(id, to: "Absent"); XCTFail("Dossier absent accepté") } catch {}
        try await store.renameDocument(id, to: "  facture.txt  ")
        try await store.moveDocument(id, to: folder)
        try await store.moveDocument(id, to: "")
        try await store.moveDocument(id, to: folder)
        let reopened = try VaultStore(root: root, keys: keys)
        let expected = Labels(name: "facture.txt", folder: folder, category: "Facture", notes: "Fictif")
        let offline = try await reopened.list()
        XCTAssertEqual(offline.first(where: { $0.id == id })?.labels, expected)
        let bytes = try await reopened.preview(id)
        XCTAssertEqual(bytes, Data([2]))
        await replica.offline(false)
        try await reopened.synchronize(with: replica)
        try await peer.synchronize(with: replica)
        let synced = try await peer.list()
        XCTAssertEqual(synced, offline)
        await replica.offline(true)
        try await reopened.change(id, labels: nil)
        let remaining = try await reopened.list()
        XCTAssertEqual(remaining.map(\.id), [first])
        XCTAssertEqual(remaining.first?.labels, Labels(name: "ancienne.txt"))
        await replica.offline(false)
        try await reopened.synchronize(with: replica)
        try await peer.synchronize(with: replica)
        let final = try await peer.list()
        XCTAssertEqual(final, remaining)
    }

    func testFolderContentsExcludeDocumentsFiledElsewhere() async throws {
        let root = location("classement")
        let keys = VaultKeys()
        let store = try VaultStore(root: root, keys: keys, create: true)
        let archives = try await store.createFolder("Archives")
        let factures = try await store.createFolder("Factures")
        let loose = try await store.importData(Data([1]), name: "libre.txt")
        let filed = try await store.importData(Data([2]), name: "classé.txt", folder: archives)
        var library = try await store.library()
        XCTAssertEqual(library.documents(in: "").map(\.id), [loose])
        XCTAssertEqual(library.documents(in: archives).map(\.id), [filed])
        XCTAssertTrue(library.documents(in: factures).isEmpty)
        try await store.moveDocument(loose, to: archives)
        try await store.moveDocument(filed, to: factures)
        let reopened = try VaultStore(root: root, keys: keys)
        library = try await reopened.library()
        XCTAssertTrue(library.documents(in: "").isEmpty)
        XCTAssertEqual(library.documents(in: archives).map(\.id), [loose])
        XCTAssertEqual(library.documents(in: factures).map(\.id), [filed])
        try await reopened.moveDocument(filed, to: "")
        library = try await reopened.library()
        XCTAssertEqual(library.documents(in: "").map(\.id), [filed])
        XCTAssertTrue(library.documents(in: factures).isEmpty)
    }

    func testNestedFolderNavigationAndImplicitParents() async throws {
        let store = try VaultStore(root: location("arbre"), keys: VaultKeys(), create: true)
        let first = try await store.createFolder("Famille")
        let second = try await store.createFolder("Impôts", in: first)
        _ = try await store.createFolder("2026", in: second)
        _ = try await store.createFolder("2026", in: first)
        _ = try await store.importData(Data([1]), name: "Photo.jpg", folder: "Voyages/Italie/Rome")
        let library = try await store.library()
        XCTAssertEqual(library.subfolders(in: ""), ["Famille", "Voyages"])
        XCTAssertEqual(Set(library.subfolders(in: first)), ["Famille/2026", "Famille/Impôts"])
        XCTAssertEqual(library.subfolders(in: second), ["Famille/Impôts/2026"])
        XCTAssertEqual(library.subfolders(in: "Voyages"), ["Voyages/Italie"])
        XCTAssertTrue(library.documents(in: "Voyages").isEmpty)
        for (name, parent) in [("impôts", first), ("Invalide/test", first), ("Essai", "Inconnu")] {
            do { _ = try await store.createFolder(name, in: parent); XCTFail("Création inattendue") }
            catch is TransportError {}
        }
    }

    func testFolderTreeRenameDeleteAndSync() async throws {
        let keys = VaultKeys()
        let root = location("local")
        let store = try VaultStore(root: root, keys: keys, create: true)
        let other = try VaultStore(root: location("autre"), keys: keys, create: true)
        let replica = MemoryReplica(root: location("."))
        _ = try await store.createFolder("Contrats")
        _ = try await store.createFolder("Vides", in: "Contrats")
        let doc = try await store.importData(Data([3]), name: "note.txt", folder: "Contrats/Archives")
        let sibling = try await store.importData(Data([4]), name: "ancienne.txt", folder: "Contrats 2020")
        try await store.synchronize(with: replica)
        try await other.synchronize(with: replica)
        for name in [" ", "..", "a/b", "contrats 2020"] {
            do { _ = try await store.renameFolder("Contrats", to: name); XCTFail("Nom accepté") } catch {}
        }
        _ = try await store.renameFolder("Contrats", to: " Documents ")
        _ = try await store.renameFolder("Documents/Archives", to: "Reçus")
        let reopened = try VaultStore(root: root, keys: keys)
        let library = try await reopened.library()
        XCTAssertEqual(Set(library.folders), ["Documents", "Documents/Vides", "Documents/Reçus", "Contrats 2020"])
        XCTAssertEqual(library.documents(in: "Documents/Reçus").map(\.id), [doc])
        let bytes = try await reopened.preview(doc)
        XCTAssertEqual(bytes, Data([3]))
        try await reopened.synchronize(with: replica)
        try await other.synchronize(with: replica)
        let renamed = try await other.library()
        XCTAssertEqual(renamed.folders, library.folders)
        XCTAssertEqual(renamed.documents, library.documents)
        try await reopened.deleteFolder("Documents")
        do { try await reopened.deleteFolder(""); XCTFail("Suppression de la racine") } catch {}
        try await reopened.synchronize(with: replica)
        try await other.synchronize(with: replica)
        let after = try await other.library()
        XCTAssertEqual(after.folders, ["Contrats 2020"])
        XCTAssertEqual(after.documents.map(\.id), [sibling])
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
