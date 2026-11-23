#if !SWIFT_PACKAGE
import XCTest
#if targetEnvironment(simulator)
import Security
import SwiftUI
#endif
@testable import Locker

final class AppSessionTests: VaultTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testClosedDuoReturnButtons() async throws {
        guard #available(iOS 27.1, *),
              ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4" else {
            throw XCTSkip("Nécessite un simulateur iPhone Duo.")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let presenter = try XCTUnwrap(scene.keyWindow?.rootViewController)
        let model = LockerModel(base: location("navigation"))
        let screens = [("Réglages du coffre", AnyView(SettingsScreen(model: model))),
                       ("Partage familial", AnyView(FamilyScreen(model: model)))]
        for (name, screen) in screens {
            var closed: Bool?
            let host = UIHostingController(rootView: screen.onHingeChange { _, context in
                closed = context.hinge?.status == .closed
            })
            host.modalPresentationStyle = .fullScreen
            presenter.present(host, animated: false)
            defer { host.dismiss(animated: false) }
            var back: UIView?
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(50))
                func findBack(_ view: UIView) -> UIView? {
                    if view.accessibilityLabel == "Retour" { return view }
                    return view.subviews.lazy.compactMap { findBack($0) }.first
                }
                back = findBack(host.view.window ?? host.view)
                if back != nil { break }
            }
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let capture = XCTAttachment(image: image)
            capture.name = name
            capture.lifetime = .keepAlways
            add(capture)
            if closed == false { throw XCTSkip("Replier le simulateur pour vérifier le retour latéral.") }
            XCTAssertEqual(closed, true, name)
            let button = try XCTUnwrap(back, name)
            let frame = button.convert(button.bounds, to: host.view)
            XCTAssertLessThan(min(frame.midX, host.view.bounds.width - frame.midX), 55, name)
        }
    }

    @MainActor func testNewFolderHasItsOwnToolbarButton() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let presenter = try XCTUnwrap(scene.keyWindow?.rootViewController)
        let model = LockerModel(base: location("barre"))
        let host = UIHostingController(rootView: LibraryScreen(model: model))
        host.modalPresentationStyle = .fullScreen
        presenter.present(host, animated: false)
        defer { host.dismiss(animated: false) }

        func toolbarButton(_ label: String, in view: UIView) -> UIView? {
            if view.accessibilityLabel == label && view.accessibilityTraits.contains(.button) { return view }
            return view.subviews.lazy.compactMap { toolbarButton(label, in: $0) }.first
        }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            if let folder = toolbarButton("Nouveau dossier", in: host.view),
               let add = toolbarButton("Ajouter", in: host.view) {
                let frame = folder.convert(folder.bounds, to: host.view)
                XCTAssertTrue(host.view.bounds.intersects(frame))
                XCTAssertFalse(frame.intersects(add.convert(add.bounds, to: host.view)))
                return
            }
        }
        XCTFail("Les deux commandes doivent être accessibles sans ouvrir de menu.")
    }

    @MainActor func testArchiveDestinationSwitchUnlocksOrCreatesBeforeExtraction() async throws {
        let base = location("destinations")
        let keys = VaultKeys()
        let originalID = UUID().uuidString
        let otherID = UUID().uuidString
        let originalRoot = base.appendingPathComponent(originalID)
        let otherRoot = base.appendingPathComponent(otherID)
        let original = try VaultStore(root: originalRoot, keys: keys, create: true)
        _ = try VaultStore(root: otherRoot, keys: keys, create: true)
        var deny = true
        let model = LockerModel(base: base) { mode, root, _, gate in
            if deny { throw VaultError.locked }
            switch mode {
            case .unlock: return try VaultStore(root: root, keys: keys, gate: gate)
            case .create: return try VaultStore(root: root, keys: VaultKeys(), create: true, gate: gate)
            case .recover: throw VaultError.unavailable
            }
        }
        let zip = location("exemple.zip")
        try XCTUnwrap(Data(base64Encoded: ArchiveTests.zip)).write(to: zip)
        let files = SelectedImport([zip])
        func settle() async throws {
            for _ in 0..<200 {
                if !model.opening && !model.extracting && (model.problem != nil || !model.documents.isEmpty) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Import inachevé")
        }
        try await model.adoptRotated(original, slotID: originalID, code: "fictif")
        model.extract(files, to: .existing(otherID), folder: "Source")
        try await settle()
        XCTAssertNil(model.store)
        let untouched = try await VaultStore(root: otherRoot, keys: keys).list()
        XCTAssertTrue(untouched.isEmpty)
        deny = false
        model.lock()
        try await model.adoptRotated(VaultStore(root: originalRoot, keys: keys), slotID: originalID, code: "fictif")
        model.extract(files, to: .existing(otherID), folder: "Source")
        try await settle()
        XCTAssertEqual(model.slot, otherID)
        XCTAssertEqual(model.library.documents(in: "").map(\.labels.name), ["note.txt"])
        model.extract(files, to: .new, folder: "Source")
        try await settle()
        XCTAssertEqual(model.slots.count, 3)
        XCTAssertNotEqual(model.slot, otherID)
        XCTAssertNotNil(model.recovery)
        XCTAssertEqual(model.documents.count, 2)
        let source = try await VaultStore(root: originalRoot, keys: keys).list()
        XCTAssertTrue(source.isEmpty)
    }

    @MainActor func testRenameSurvivesLockAndRelaunch() async throws {
        let base = location("coffres")
        let slot = UUID().uuidString
        let store = try VaultStore(root: base.appendingPathComponent(slot), keys: VaultKeys(), create: true)
        defer { SecItemDelete(LockerModel.nameItem(slot).query as CFDictionary) }
        let model = LockerModel(base: base)
        try await model.adoptRotated(store, slotID: slot, code: "fictif")
        XCTAssertThrowsError(try model.renameVault("   "))
        try model.renameVault("  Test personnel  ")
        XCTAssertEqual(model.vaultTitle, "Test personnel")
        model.lock()
        XCTAssertThrowsError(try model.renameVault("Autre"))
        let reopened = LockerModel(base: base)
        XCTAssertEqual(reopened.slot, slot)
        XCTAssertEqual(reopened.vaultNames[slot], "Test personnel")
    }

    func testSavedPasswordBelongsToSelectedNASAndAccount() async throws {
        let store = try VaultStore(root: location("test-nas"), keys: VaultKeys(), create: true)
        var config = ProviderSettings(provider: .webdav, endpoint: "https://nas.invalid/Documents/", username: "test")
        let initial = try await store.hasSavedWebDAVPassword(for: config)
        XCTAssertFalse(initial)
        let account = await store.credentialAccount(config)
        defer { SecItemDelete(ProviderCredential(account: account).query as CFDictionary) }
        try await store.configure(config, credential: "mot-de-passe-fictif")
        try await store.configure(config, credential: nil)
        let saved = try await store.hasSavedWebDAVPassword(for: config)
        XCTAssertTrue(saved)
        config.username = "autre"
        let otherUser = try await store.hasSavedWebDAVPassword(for: config)
        XCTAssertFalse(otherUser)
        config.username = "test"
        config.endpoint = "https://autre.invalid/Documents/"
        let otherServer = try await store.hasSavedWebDAVPassword(for: config)
        XCTAssertFalse(otherServer)
        store.gate.revoke()
        do { _ = try await store.hasSavedWebDAVPassword(for: config); XCTFail("Coffre verrouillé") }
        catch VaultError.locked {}
    }
    #endif

    @MainActor func testAutomaticLockRemovesPreviewAccessAndDisplayedSecrets() async throws {
        let store = try VaultStore(root: location("app"), keys: VaultKeys(), create: true)
        let id = try await store.importData(Data([9]), name: "document-fictif")
        let model = LockerModel()
        try await model.adoptRotated(store, slotID: "simulation", code: "fictif")
        XCTAssertEqual(model.documents.count, 1)
        model.tick(at: .now.advanced(by: .seconds(model.timeout + 1)))
        XCTAssertNil(model.store)
        XCTAssertNil(model.recovery)
        XCTAssertTrue(model.documents.isEmpty)
        do { _ = try await store.preview(id); XCTFail("Lecture après expiration") } catch VaultError.locked {}
    }
}
#endif
