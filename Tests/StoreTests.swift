import Foundation
import ImageIO
import UniformTypeIdentifiers
import LocalAuthentication
import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

class VaultTestCase: XCTestCase {
    private var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try VaultFiles.directory(scratch)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: scratch) }
    func location(_ name: String) -> URL { scratch.appendingPathComponent(name) }
}

final class StoreTests: VaultTestCase {
    func testDocumentSortFieldsInBothDirections() {
        func row(_ name: String, _ day: Double?, _ size: Int64) -> ListedDocument {
            let id = UUID()
            return ListedDocument(lineage: id, created: day.map(Date.init(timeIntervalSince1970:)),
                                  id: id, labels: Labels(name: name), size: size)
        }
        let a = row("Note 2", 30, 3), b = row("Note 10", 10, 500), c = row("Projet", 20, 1)
        let rows = [b, a, c]
        for (field, expected): (DocumentSortField, [ListedDocument]) in [
            (.name, [a, b, c]), (.date, [b, c, a]), (.size, [c, a, b])
        ] {
            XCTAssertEqual(field.sorted(rows, ascending: true), expected)
            XCTAssertEqual(field.sorted(rows, ascending: false), Array(expected.reversed()))
        }
        let undated = row("Ancien", nil, 3)
        for ascending in [true, false] {
            XCTAssertEqual(DocumentSortField.date.sorted([undated, a], ascending: ascending).last, undated)
        }
        XCTAssertEqual(DocumentSortField.size.sorted([a, undated], ascending: true), [undated, a])
    }

    func testHistorySelectsSuccessorWhenDeviceClocksDisagree() {
        let original = UUID(), child = UUID()
        let labels = Labels(name: "Note.txt")
        let first = ListedDocument(lineage: original, created: .now, id: original, labels: labels, size: 1)
        let next = ListedDocument(parent: original, lineage: original, created: .distantPast, id: child, labels: labels, size: 1)
        for rows in [[first, next], [next, first]] {
            let library = VaultLibrary(documents: rows)
            XCTAssertEqual(library.documents.map(\.id), [child])
            XCTAssertEqual(library.versions(of: original).map(\.id), [child, original])
        }
    }

    func testDeletingFolderCleansOnlyHistoriesOfItsVisibleDocuments() async throws {
        let store = try VaultStore(root: location("dossiers"), keys: VaultKeys(), create: true)
        let folder = try await store.createFolder("Archives")
        let a = try await store.importData(Data([1]), name: "A.txt")
        let b = try await store.importData(Data([2]), name: "B.txt", folder: folder)
        let newA = try await store.importData(Data([3]), name: "A.txt", versionOf: a)
        let newB = try await store.importData(Data([4]), name: "B.txt", versionOf: b)
        try await store.moveDocument(newA, to: folder)
        try await store.moveDocument(newB, to: "")
        try await store.deleteFolder(folder)
        let library = try await store.library()
        XCTAssertEqual(library.documents.map(\.id), [newB])
        XCTAssertTrue(library.folders.isEmpty)
        XCTAssertTrue(library.versions(of: a).isEmpty)
        XCTAssertEqual(library.versions(of: b).map(\.id), [newB, b])
    }

    func testThumbnailFromEncryptedPhotoIsDownsampledAndRequiresOpenVault() async throws {
        let store = try VaultStore(root: location("vignettes"), keys: VaultKeys(), create: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 960, height: 480, bitsPerComponent: 8,
            bytesPerRow: 960 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 480))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let id = try await store.importData(data as Data, name: "Photo.png")
        let thumbnail = try await store.photoThumbnail(id)
        XCTAssertEqual(thumbnail.width, 384)
        XCTAssertEqual(thumbnail.height, 192)
        store.gate.revoke()
        do { _ = try await store.photoThumbnail(id); XCTFail("Aperçu après verrouillage") }
        catch VaultError.locked {}
    }

    func testMultipleDocumentMoveIsAtomicAndPersists() async throws {
        let root = location("deplacements")
        let keys = VaultKeys()
        let store = try VaultStore(root: root, keys: keys, create: true)
        let parent = try await store.createFolder("Archives")
        let folder = try await store.createFolder("2026", in: parent)
        let a = try await store.importData(Data([1]), name: "A.txt")
        let b = try await store.importData(Data([2]), name: "B.txt")
        let other = try await store.importData(Data([3]), name: "C.txt")
        do { try await store.moveDocuments([a, b, UUID()], to: folder); XCTFail("Document manquant") }
        catch VaultError.unavailable {}
        let afterFailure = try await store.library()
        XCTAssertEqual(Set(afterFailure.documents(in: "").map(\.id)), [a, b, other])
        try await store.moveDocuments([a, b], to: folder)
        let reopened = try VaultStore(root: root, keys: keys)
        let library = try await reopened.library()
        XCTAssertEqual(Set(library.documents(in: folder).map(\.id)), [a, b])
        XCTAssertEqual(library.documents(in: "").map(\.id), [other])
        try await reopened.moveDocuments([a, b], to: "")
        let restored = try await reopened.library()
        XCTAssertTrue(restored.documents(in: folder).isEmpty)
    }

    func testImportExportDeletionAndNoPlaintext() async throws {
        let root = location("vault")
        let keys = VaultKeys()
        let store = try VaultStore(root: root, keys: keys, create: true)
        let marker = "Confidentiel-unique-3742"
        let bytes = Data(String(repeating: marker, count: 100_000).utf8)
        let source = location(marker)
        try bytes.write(to: source)
        let id = try await store.importFile(source)
        try await store.change(id, labels: Labels(name: marker, folder: marker, category: marker, notes: marker))
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let raw = try Data(contentsOf: file)
            XCTAssertNil(raw.range(of: Data(marker.utf8)))
            XCTAssertNil(raw.range(of: keys.secret))
            XCTAssertFalse(file.lastPathComponent.contains(marker))
        }
        let restored = try VaultStore(root: root, keys: keys)
        let dest = location("explicit-export")
        try await restored.export(id, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), bytes)
        do { try await restored.export(id, to: dest); XCTFail("Écrasement") } catch {}
        try await restored.change(id, labels: nil)
        let entry = await restored.entries[id]
        XCTAssertNil(entry?.document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString + ".blob").path))
        XCTAssertThrowsError(try VaultStore(root: root, keys: VaultKeys()))
    }

    func testTruncationTrailingDataAndTampering() async throws {
        let store = try VaultStore(root: location("vault"), keys: VaultKeys(), create: true)
        let id = try await store.importData(Data(repeating: 7, count: BlockCipher.chunk + 10), name: "test")
        let url = await store.blob(id)
        let original = try Data(contentsOf: url)
        var flipped = original
        flipped[20] ^= 1
        for variant in [flipped, Data(original.dropLast(32)), original + Data([0])] {
            try variant.write(to: url)
            do { _ = try await store.preview(id); XCTFail("Altération acceptée") } catch {}
            let destination = location("export")
            do { try await store.export(id, to: destination); XCTFail("Export accepté") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
        let empty = try await store.importData(Data(), name: "vide")
        let plain = try await store.preview(empty)
        XCTAssertEqual(plain, Data())
    }

    func testAccessAndRecoveryAfterKeyLoss() async throws {
        final class MockKeys: DeviceKeyAccess {
            var value: VaultKeys?
            var allowed = true
            func read(context: LAContext) throws -> VaultKeys {
                guard allowed, let value else { throw VaultError.unavailable }
                return value
            }
            func install(_ keys: VaultKeys, context: LAContext) throws { value = keys }
        }
        let device = MockKeys()
        let root = location("vault")
        let context = LAContext()
        let gate = SessionGate()
        let store = try VaultAccess.open(.create, at: root, device: device, context: context, gate: gate)
        let code = try await store.recoveryCode()
        gate.revoke()
        do { _ = try await store.list(); XCTFail("Session utilisable") } catch {}
        device.allowed = false
        XCTAssertThrowsError(try VaultAccess.open(.unlock, at: root, device: device, context: context, gate: SessionGate()))
        device.allowed = true
        device.value = nil
        XCTAssertThrowsError(try VaultAccess.open(.unlock, at: root, device: device, context: context, gate: SessionGate()))
        XCTAssertThrowsError(try VaultAccess.open(.recover(VaultKeys().recoveryCode), at: root, device: device, context: context, gate: SessionGate()))
        let reopened = try VaultAccess.open(.recover(code), at: root, device: device, context: context, gate: SessionGate())
        let value = try await reopened.recoveryCode()
        XCTAssertEqual(value, code)
    }
}
