#if !SWIFT_PACKAGE
import CryptoKit
import UniformTypeIdentifiers
import XCTest
@testable import Locker

final class IncomingShareTests: VaultTestCase {
    func testProviderFilesRemainEncryptedUntilImportedIntoChosenFolder() async throws {
        let inbox = ShareInbox(root: location("inbox"))
        try VaultFiles.directory(inbox.root)
        XCTAssertThrowsError(try ShareInbox.Writer(inbox))
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        try recipient.publicKey.rawRepresentation.write(to: inbox.recipient)
        let writer = try ShareInbox.Writer(inbox)
        let name = "Rapport-fictif.pdf"
        let source = location(name)
        let bytes = Data(repeating: 65, count: ShareInbox.chunkSize + 19)
        try bytes.write(to: source)

        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            return nil
        }
        do {
            _ = try await writer.receive(provider, checking: { throw CancellationError() })
            XCTFail("Une lecture annulée doit interrompre le partage.")
        } catch is CancellationError {}
        XCTAssertTrue(try inbox.pending().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: writer.staging.path).isEmpty)
        let first = try await writer.receive(provider)
        let second = try writer.store(name: "Vide.txt") { Data() }
        XCTAssertTrue(try inbox.pending().isEmpty)
        try writer.finish([first, second])
        XCTAssertEqual(try inbox.pending(), [writer.id])
        XCTAssertThrowsError(try inbox.open(writer.id, privateKey: .init()))
        let batch = inbox.directory(writer.id)
        for file in try FileManager.default.contentsOfDirectory(at: batch, includingPropertiesForKeys: nil) {
            let raw = try Data(contentsOf: file)
            XCTAssertNil(raw.range(of: Data(name.utf8)))
            XCTAssertNil(raw.range(of: bytes.prefix(100)))
        }

        let keys = VaultKeys()
        let vaultURL = location("coffre")
        let store = try VaultStore(root: vaultURL, keys: keys, create: true)
        let folder = try await store.createFolder("Archives")
        let replay = location("interruption")
        try FileManager.default.copyItem(at: batch, to: replay)
        store.gate.revoke()
        do { try await store.receive(writer.id, from: inbox, privateKey: recipient, folder: folder); XCTFail() }
        catch VaultError.locked {}
        let unlocked = try VaultStore(root: vaultURL, keys: keys)
        try await unlocked.receive(writer.id, from: inbox, privateKey: recipient, folder: folder)
        XCTAssertTrue(try inbox.pending().isEmpty)

        // Simulate a crash between the catalogue commit and removing the encrypted incoming batch.
        try FileManager.default.copyItem(at: replay, to: batch)
        let reopened = try VaultStore(root: vaultURL, keys: keys)
        try await reopened.receive(writer.id, from: inbox, privateKey: recipient, folder: folder)
        let list = try await reopened.library()
        XCTAssertTrue(list.documents(in: "").isEmpty)
        XCTAssertEqual(Set(list.documents(in: folder).map(\.labels.name)), [name, "Vide.txt"])
        XCTAssertEqual(list.documents.count, 2)
        let id = try XCTUnwrap(list.documents.first { $0.labels.name == name }?.id)
        let result = try await reopened.preview(id)
        XCTAssertEqual(result, bytes)
    }

    func testSharedFileWithNewNameOffersTheExistingDocument() async throws {
        let inbox = ShareInbox(root: location("inbox"))
        try VaultFiles.directory(inbox.root)
        let key = Curve25519.KeyAgreement.PrivateKey()
        try key.publicKey.rawRepresentation.write(to: inbox.recipient)
        let writer = try ShareInbox.Writer(inbox)
        let original = Data("Document partagé fictif".utf8)
        var payload = original
        let received = try writer.store(name: "Depuis Mail.txt") { defer { payload.removeAll() }; return payload }
        try writer.finish([received])
        let store = try VaultStore(root: location("coffre"), keys: VaultKeys(), create: true)
        let folder = try await store.createFolder("Factures")
        let existing = try await store.importData(original, name: "Déjà rangé.txt", folder: folder)
        do {
            try await store.receive(writer.id, from: inbox, privateKey: key, folder: "")
            XCTFail("Doublon attendu")
        } catch let duplicate as DuplicateImport {
            XCTAssertEqual(duplicate.existing.folder, folder)
            XCTAssertEqual(try inbox.pending(), [writer.id])
            let open = try await store.receive(writer.id, from: inbox, privateKey: key, folder: "",
                                               choices: [duplicate.id: .openExisting])
            XCTAssertEqual(open, existing)
            XCTAssertTrue(try inbox.pending().isEmpty)
            let docs = try await store.list()
            XCTAssertEqual(docs.map(\.id), [existing])
        }
    }

    func testDamagedSecondFileRollsBackEntireBatch() async throws {
        let inbox = ShareInbox(root: location("inbox"))
        try VaultFiles.directory(inbox.root)
        let key = Curve25519.KeyAgreement.PrivateKey()
        try key.publicKey.rawRepresentation.write(to: inbox.recipient)
        let writer = try ShareInbox.Writer(inbox)
        let first = try writer.store(name: "Vide") { Data() }
        var content = Data("Exemple".utf8)
        let second = try writer.store(name: "Exemple.txt") { defer { content.removeAll() }; return content }
        try writer.finish([first, second])
        try Data("Corrompu".utf8).write(to: second.url(in: inbox.directory(writer.id), at: 0))
        let store = try VaultStore(root: location("vault"), keys: VaultKeys(), create: true)
        do { try await store.receive(writer.id, from: inbox, privateKey: key, folder: ""); XCTFail() }
        catch {}
        let documents = try await store.list()
        XCTAssertTrue(documents.isEmpty)
        XCTAssertEqual(try inbox.pending(), [writer.id])
    }
}
#endif
