import Foundation
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
