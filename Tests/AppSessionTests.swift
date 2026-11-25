#if !SWIFT_PACKAGE
import XCTest
#if targetEnvironment(simulator)
import LocalAuthentication
import Security
import SwiftUI
#endif
@testable import Locker

final class AppSessionTests: VaultTestCase {
    #if targetEnvironment(simulator)
    func testPasscodeAndBiometricsRequestOnlyTheSelectedSystemMethod() async throws {
        final class RecordingContext: LAContext {
            var policies: [LAPolicy] = []
            var controls: [SecAccessControl] = []
            var allow = true

            override func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool {
                policies.append(policy)
                return allow
            }

            override func evaluateAccessControl(_ accessControl: SecAccessControl, operation: LAAccessControlOperation,
                                                localizedReason: String) async throws -> Bool {
                XCTAssertEqual(operation, .useItem)
                controls.append(accessControl)
                return allow
            }
        }
        let code = RecordingContext()
        try await VaultAuthenticationMethod.passcode.confirm(using: code, reason: "Test")
        let expected = try XCTUnwrap(SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                                    .devicePasscode, nil))
        XCTAssertEqual(code.controls.count, 1)
        XCTAssertTrue(CFEqual(try XCTUnwrap(code.controls.first), expected))
        XCTAssertTrue(code.policies.isEmpty)
        XCTAssertTrue(code.interactionNotAllowed)

        let bio = RecordingContext()
        try await VaultAuthenticationMethod.biometrics.confirm(using: bio, reason: "Test")
        XCTAssertEqual(bio.policies, [.deviceOwnerAuthenticationWithBiometrics])
        XCTAssertTrue(bio.controls.isEmpty)

        let denied = RecordingContext()
        denied.allow = false
        do {
            try await VaultAuthenticationMethod.passcode.confirm(using: denied, reason: "Test")
            XCTFail("Un code refusé doit laisser le coffre fermé.")
        } catch VaultError.locked {}
        XCTAssertTrue(denied.policies.isEmpty)
    }

    func testDeviceOnlyVaultUsesItsOwnKeychainProtection() async throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4" else {
            throw XCTSkip("Ce test utilise le Trousseau du simulateur iPhone Duo.")
        }
        final class ConfirmedContext: LAContext {
            override func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool {
                XCTAssertEqual(policy, .deviceOwnerAuthenticationWithBiometrics)
                return true
            }

            override func evaluateAccessControl(_ accessControl: SecAccessControl, operation: LAAccessControlOperation,
                                                localizedReason: String) async throws -> Bool {
                XCTAssertEqual(operation, .useItem)
                return true
            }
        }
        let id = UUID().uuidString
        let root = location(id)
        let device = DeviceKeychain(account: id)
        defer { SecItemDelete(device.query as CFDictionary) }
        func silentContext() -> LAContext {
            let context = LAContext()
            context.interactionNotAllowed = true
            return context
        }
        let opened = try await LockerModel.authenticateAndOpen(.create, at: root, context: silentContext(),
                                                               gate: SessionGate(), protectNewKey: false, method: .biometrics)
        let document = try await opened.importData(Data([42]), name: "Exemple")
        opened.gate.revoke()
        XCTAssertFalse(device.requiresAuthentication())
        let reopened = try await LockerModel.authenticateAndOpen(.unlock, at: root, context: silentContext(),
                                                                 gate: SessionGate(), protectNewKey: true, method: .biometrics)
        let contents = try await reopened.preview(document)
        XCTAssertEqual(contents, Data([42]))
        XCTAssertTrue(DeviceKeychain(account: UUID().uuidString).requiresAuthentication())
        do {
            try await device.changeProtection(required: true, method: .biometrics, context: silentContext(), gate: reopened.gate)
            XCTFail("La modification doit demander confirmation")
        } catch {}
        XCTAssertFalse(device.requiresAuthentication())
        do {
            try await device.changeProtection(required: true, method: .biometrics, context: ConfirmedContext(), gate: opened.gate)
            XCTFail("Un coffre fermé doit refuser le changement de protection")
        } catch VaultError.locked {}
        XCTAssertFalse(device.requiresAuthentication())
        try await device.changeProtection(required: true, method: .biometrics, context: ConfirmedContext(), gate: reopened.gate)
        XCTAssertTrue(device.requiresAuthentication())
        let byCode = try await LockerModel.authenticateAndOpen(.unlock, at: root, context: ConfirmedContext(),
                                                               gate: SessionGate(), protectNewKey: true, method: .passcode)
        let codeContents = try await byCode.preview(document)
        XCTAssertEqual(codeContents, contents)
        byCode.gate.revoke()
        var lookup = device.query
        lookup[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(lookup as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
        do {
            _ = try await LockerModel.authenticateAndOpen(.unlock, at: root, context: silentContext(),
                                                          gate: SessionGate(), protectNewKey: false, method: .biometrics)
            XCTFail("L’ouverture protégée exige une authentification, même si la création propose un autre choix.")
        } catch {}
        try await device.changeProtection(required: false, method: .biometrics, context: ConfirmedContext(), gate: reopened.gate)
        let restored = try await LockerModel.authenticateAndOpen(.unlock, at: root, context: silentContext(),
                                                                 gate: SessionGate(), protectNewKey: true, method: .biometrics)
        let afterChange = try await restored.preview(document)
        XCTAssertEqual(afterChange, contents)
    }

    @MainActor func testFirstProtectedVaultOnDuoSimulator() async throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4" else {
            throw XCTSkip("Trousseau du simulateur iPhone Duo uniquement.")
        }
        let base = location("premier-coffre")
        let model = LockerModel(base: base)
        var finished = false
        model.open(.create, newSlot: true) { finished = true }
        let setup = try XCTUnwrap(model.newVaultSetup)
        XCTAssertTrue(model.slots.isEmpty)
        XCTAssertNil(model.store)
        XCTAssertFalse(finished)
        model.lock()
        XCTAssertNil(model.newVaultSetup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))

        func settle() async throws {
            for _ in 0..<200 where model.opening { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(model.opening)
        }

        model.completeNewVaultSetup(setup, with: .init(method: .numericCode, value: "0198374652"))
        XCTAssertFalse(model.opening)
        model.open(.create, newSlot: true)
        model.completeNewVaultSetup(try XCTUnwrap(model.newVaultSetup), with: .init(method: .numericCode, value: "1234"))
        try await settle()
        XCTAssertNil(model.store)
        XCTAssertTrue(model.slots.isEmpty)
        XCTAssertEqual(model.problem, VaultSecretError.invalidPIN.localizedDescription)
        model.lock()

        for (method, value) in [(VaultAuthenticationMethod.numericCode, "0198374652"), (.vaultPassword, "Rosée!Fictive72")] {
            finished = false
            model.open(.create, newSlot: true) { finished = true }
            model.completeNewVaultSetup(try XCTUnwrap(model.newVaultSetup), with: .init(method: method, value: value))
            try await settle()
            let vault = try XCTUnwrap(model.store, model.problem ?? "")
            let device = DeviceKeychain(account: model.slot)
            defer { SecItemDelete(device.query as CFDictionary) }
            XCTAssertTrue(finished)
            let recovery = try XCTUnwrap(model.recovery)
            XCTAssertTrue(device.requiresAuthentication())
            XCTAssertEqual(device.customMethod(), method)
            XCTAssertThrowsError(try device.read(context: LAContext()))
            let doc = try await vault.importData(Data([42]), name: "Exemple")
            model.lock()
            model.open(.unlockWithSecret("0000000000"))
            try await settle()
            XCTAssertNil(model.store)
            model.open(.unlockWithSecret(value))
            try await settle()
            let reopened = try XCTUnwrap(model.store)
            let data = try await reopened.preview(doc)
            XCTAssertEqual(data, Data([42]))
            model.lock()
            let replacement = LockerModel.NewVaultSecret(method: .numericCode, value: "4028951673")
            model.open(.recover(VaultKeys().recoveryCode))
            model.completeNewVaultSetup(try XCTUnwrap(model.newVaultSetup), with: replacement)
            try await settle()
            XCTAssertNil(model.store)
            XCTAssertEqual(device.customMethod(), method)
            model.open(.recover(recovery))
            let repair = try XCTUnwrap(model.newVaultSetup)
            model.completeNewVaultSetup(repair, with: replacement)
            try await settle()
            XCTAssertNotNil(model.store)
            model.lock()
            model.open(.unlockWithSecret(replacement.value))
            try await settle()
            let repaired = try XCTUnwrap(model.store)
            let restored = try await repaired.preview(doc)
            XCTAssertEqual(restored, data)
            model.lock()
        }
    }

    @MainActor func testCustomVaultMethodsOnDuoKeychain() async throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4" else {
            throw XCTSkip("Trousseau du simulateur iPhone Duo uniquement.")
        }
        final class TestDevicePasscode: LAContext {
            override func evaluateAccessControl(_ accessControl: SecAccessControl, operation: LAAccessControlOperation,
                                                localizedReason: String) async throws -> Bool { true }
        }
        let id = UUID().uuidString
        let base = location("identification")
        let root = base.appendingPathComponent(id)
        let device = DeviceKeychain(account: id, protectNewKey: false)
        let pin = "0198374652"
        let password = "Rosée!Fictive72"
        defer {
            SecItemDelete(device.query as CFDictionary)
            UserDefaults.standard.removeObject(forKey: "authenticationMethod." + id)
        }
        let first = try VaultAccess.open(.create, at: root, device: device, context: LAContext(), gate: SessionGate())
        let doc = try await first.importData(Data([1, 3, 5]), name: "Document fictif")
        let recovery = try await first.recoveryCode()
        try device.replaceKey(try device.read(context: LAContext()), method: .numericCode, newSecret: pin,
                              required: true, context: LAContext(), gate: first.gate)
        first.gate.revoke()
        XCTAssertEqual(device.customMethod(), .numericCode)
        XCTAssertThrowsError(try device.read(context: LAContext()))
        func open(_ mode: AccessMode) async throws -> VaultStore {
            try await LockerModel.authenticateAndOpen(mode, at: root, context: TestDevicePasscode(),
                                                       gate: SessionGate(), protectNewKey: false, method: .passcode)
        }
        do { _ = try await open(.unlock); XCTFail("Ouverture sans le secret du coffre") } catch VaultSecretError.incorrect {}
        do { _ = try await open(.unlockWithSecret("9999999999")); XCTFail("Code incorrect accepté") } catch VaultSecretError.incorrect {}
        let session = try await open(.unlockWithSecret(pin))
        let model = LockerModel(base: base)
        try await model.adoptRotated(session, slotID: id, code: recovery)
        do {
            try await model.setSecretProtection(to: .passcode, required: false, currentSecret: "0000000000", newSecret: "")
            XCTFail("Désactivation sans le code actuel")
        } catch VaultSecretError.incorrect {}
        XCTAssertEqual(device.customMethod(), .numericCode)
        try await model.setSecretProtection(to: .vaultPassword, required: true, currentSecret: pin, newSecret: password)
        model.lock()
        XCTAssertEqual(device.customMethod(), .vaultPassword)
        do { _ = try await open(.unlockWithSecret(pin)); XCTFail("Ancien code accepté") } catch VaultSecretError.incorrect {}
        let reopened = try await open(.unlockWithSecret(password))
        let data = try await reopened.preview(doc)
        XCTAssertEqual(data, Data([1, 3, 5]))
        reopened.gate.revoke()
        do { _ = try await open(.recover(VaultKeys().recoveryCode)); XCTFail("Mauvais code de récupération accepté") } catch {}
        XCTAssertEqual(device.customMethod(), .vaultPassword)
        let repaired = try await open(.recover(recovery))
        XCTAssertNil(device.customMethod())
        XCTAssertTrue(device.requiresAuthentication())
        let afterRecovery = try await repaired.preview(doc)
        XCTAssertEqual(afterRecovery, data)
    }

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
        model.library = VaultLibrary(documents: [
            ListedDocument(lineage: UUID(), created: nil, id: UUID(),
                           labels: Labels(name: "Contrat habitation.pdf", category: "Assurance"), size: 482_000),
            ListedDocument(lineage: UUID(), created: nil, id: UUID(),
                           labels: Labels(name: "Inventaire.xlsx", category: "Maison"), size: 24_000)
        ], folders: ["Administration", "Maison"])
        let host = UIHostingController(rootView: LibraryScreen(model: model).tint(Color.lockerTint))
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
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let capture = XCTAttachment(image: image)
                capture.name = "Bibliothèque iPhone"
                capture.lifetime = .keepAlways
                self.add(capture)
                return
            }
        }
        XCTFail("Les deux commandes doivent être accessibles sans ouvrir de menu.")
    }

    @MainActor private func button(_ label: String, in host: UIViewController) async throws -> NSObject {
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            var visited = Set<ObjectIdentifier>()
            func find(_ node: NSObject) -> NSObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.accessibilityLabel?.contains(label) == true, node.accessibilityTraits.contains(.button),
                   !node.accessibilityTraits.contains(.notEnabled) {
                    return node
                }
                let count = node.accessibilityElementCount()
                var children = (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
                if count > 0 && count != NSNotFound {
                    children += (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
                }
                children += (node as? UIView)?.subviews ?? []
                for child in children { if let match = find(child) { return match } }
                return nil
            }
            if let match = find(host.presentedViewController?.view ?? host.view) { return match }
        }
        throw TransportError(message: "Bouton absent : " + label)
    }

    @MainActor func testPhotoEditorSavesFromDocumentScreen() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let presenter = try XCTUnwrap(scene.keyWindow?.rootViewController)
        let model = LockerModel(base: location("photos"))
        let store = try VaultStore(root: location("coffre"), keys: VaultKeys(), create: true)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40)).pngData { renderer in
            UIColor.orange.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
        let id = try await store.importData(data, name: "Image.png")
        model.store = store
        model.library = try await store.library()
        let photo = try XCTUnwrap(model.documents.first)
        var selected: UUID?
        let host = UIHostingController(rootView: NavigationStack {
            DocumentScreen(model: model, item: photo, select: { selected = $0 }, addVersion: {}, actions: EmptyView())
        })
        host.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { done in presenter.present(host, animated: false) { done.resume() } }
        addTeardownBlock { @MainActor in
            if let transition = host.presentedViewController?.transitionCoordinator {
                await withCheckedContinuation { done in
                    if !transition.animate(alongsideTransition: nil, completion: { _ in done.resume() }) {
                        done.resume()
                    }
                }
            }
            if presenter.presentedViewController === host {
                await withCheckedContinuation { done in presenter.dismiss(animated: false) { done.resume() } }
            }
        }
        for label in ["Modifier la photo", "Rotation à droite", "Recadrer", "Appliquer le cadre", "Enregistrer"] {
            let control = try await button(label, in: host)
            if let button = control as? UIControl { button.sendActions(for: .primaryActionTriggered) }
            else { XCTAssertTrue(control.accessibilityActivate(), label) }
        }
        for _ in 0..<40 where selected == nil { try await Task.sleep(for: .milliseconds(50)) }
        let editedID = try XCTUnwrap(selected)
        XCTAssertNotEqual(editedID, id)
        XCTAssertEqual(model.documents.map(\.id), [editedID])
        XCTAssertEqual(model.library.versions(of: id).map(\.id), [editedID, id])
        let image = try await store.photoEditingPreview(editedID)
        XCTAssertLessThan(image.width, image.height)
    }

    @MainActor func testThumbnailGridAllowsMarkingTwoDocuments() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let presenter = try XCTUnwrap(scene.keyWindow?.rootViewController)
        let model = LockerModel(base: location("grille"))
        let store = try VaultStore(root: location("coffre"), keys: VaultKeys(), create: true)
        for name in ["Premier.txt", "Second.txt"] { _ = try await store.importData(Data([1]), name: name) }
        model.store = store
        model.library = try await store.library()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "libraryShowsThumbnails")
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UIHostingController(rootView: LibraryScreen(model: model).defaultAppStorage(defaults))
        host.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { done in presenter.present(host, animated: false) { done.resume() } }
        defer { host.dismiss(animated: false) }

        for label in ["Sélectionner", "Premier.txt", "Second.txt"] {
            let control = try await button(label, in: host)
            XCTAssertTrue(control.accessibilityActivate(), label)
        }
        _ = try await button("Déplacer (2)", in: host)
    }

    @MainActor func testImportScreenOffersDecompressionBeforeChoosingAFile() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let presenter = try XCTUnwrap(scene.keyWindow?.rootViewController)
        let model = LockerModel(base: location("import"))
        let host = UIHostingController(rootView: DocumentImportScreen(model: model, folder: ""))
        await withCheckedContinuation { done in
            presenter.present(host, animated: false) { done.resume() }
        }
        var buttons = Set<String>()
        var labels = Set<String>()
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            var visited = Set<ObjectIdentifier>()
            func inspect(_ node: NSObject) {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return }
                if let label = node.accessibilityLabel {
                    labels.insert(label)
                    if node.accessibilityTraits.contains(.button) { buttons.insert(label) }
                }
                if let view = node as? UIView { view.subviews.forEach(inspect) }
                for child in node.accessibilityElements ?? [] {
                    if let object = child as? NSObject { inspect(object) }
                }
                let count = node.accessibilityElementCount()
                if count > 0 && count != NSNotFound {
                    for index in 0..<count {
                        if let child = node.accessibilityElement(at: index) as? NSObject { inspect(child) }
                    }
                }
            }
            inspect(host.view)
            if buttons.isSuperset(of: ["Décompresser une archive…", "Choisir des fichiers…"]) { break }
        }
        XCTAssertTrue(buttons.isSuperset(of: ["Décompresser une archive…", "Choisir des fichiers…"]),
                      "Éléments affichés : \(labels.sorted())")
        await withCheckedContinuation { done in
            host.dismiss(animated: false) { done.resume() }
        }
    }

    @MainActor func testArchiveDestinationSwitchUnlocksOrCreatesBeforeExtraction() async throws {
        let base = location("destinations")
        let keys = VaultKeys()
        let originalID = UUID().uuidString
        let otherID = UUID().uuidString
        let originalRoot = base.appendingPathComponent(originalID)
        let otherRoot = base.appendingPathComponent(otherID)
        let original = try VaultStore(root: originalRoot, keys: keys, create: true)
        let other = try VaultStore(root: otherRoot, keys: keys, create: true)
        _ = try await other.createFolder("Archives")
        var deny = true
        var newProtection: Bool?
        VaultAuthenticationMethod.biometrics.remember(for: otherID)
        defer { UserDefaults.standard.removeObject(forKey: "authenticationMethod." + otherID) }
        var requestedMethods: [VaultAuthenticationMethod] = []
        let model = LockerModel(base: base) { mode, root, _, gate, protectNewKey, method, _ in
            requestedMethods.append(method)
            if deny { throw VaultError.locked }
            switch mode {
            case .unlock, .unlockWithSecret: return try VaultStore(root: root, keys: keys, gate: gate)
            case .create:
                newProtection = protectNewKey
                return try VaultStore(root: root, keys: VaultKeys(), create: true, gate: gate)
            case .recover: throw VaultError.unavailable
            }
        }
        let zip = location("exemple.zip")
        try XCTUnwrap(Data(base64Encoded: ArchiveTests.zip)).write(to: zip)
        let files = SelectedImport([zip])
        func settle(_ ready: () -> Bool) async throws {
            for _ in 0..<200 {
                if !model.opening && !model.extracting && ready() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Import inachevé")
        }
        try await model.adoptRotated(original, slotID: originalID, code: "fictif")
        model.chooseArchiveFolder(files, in: otherID)
        try await settle { model.problem != nil }
        XCTAssertNil(model.store)
        XCTAssertNil(model.pendingArchivePlacement)
        let untouched = try await other.list()
        XCTAssertTrue(untouched.isEmpty)
        deny = false
        model.lock()
        try await model.adoptRotated(VaultStore(root: originalRoot, keys: keys), slotID: originalID, code: "fictif")
        model.chooseArchiveFolder(files, in: otherID)
        try await settle { model.pendingArchivePlacement != nil }
        XCTAssertEqual(model.slot, otherID)
        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertEqual(model.library.folders, ["Archives"])
        let pending = try XCTUnwrap(model.pendingArchivePlacement)
        model.pendingArchivePlacement = nil
        model.importArchive(pending, inNewVault: false, folder: "Archives", extract: true)
        try await settle { model.documents.count == 2 }
        XCTAssertEqual(model.library.documents(in: "Archives").map(\.labels.name), ["note.txt"])
        XCTAssertTrue(model.library.documents(in: "").isEmpty)
        model.importArchive(files, inNewVault: false, folder: "", extract: true)
        try await settle { model.documents.count == 4 }
        XCTAssertEqual(model.library.documents(in: "").map(\.labels.name), ["note.txt"])
        model.importArchive(files, inNewVault: false, folder: "Archives", extract: false)
        try await settle { model.documents.count == 5 }
        let archived = try XCTUnwrap(model.library.documents(in: "Archives").first { $0.labels.name == "exemple.zip" })
        let destinationStore = try XCTUnwrap(model.store)
        let storedBytes = try await destinationStore.preview(archived.id)
        XCTAssertEqual(storedBytes, try Data(contentsOf: zip))
        model.importArchive(files, inNewVault: true, folder: "Archives", extract: true, protectNewKey: false)
        try await settle { model.slot != otherID && model.documents.count == 2 }
        XCTAssertEqual(newProtection, false)
        XCTAssertEqual(requestedMethods, [.biometrics, .biometrics, .passcode])
        XCTAssertEqual(VaultAuthenticationMethod.preferred(for: otherID), .biometrics)
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
