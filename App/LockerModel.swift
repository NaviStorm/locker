import Foundation
import LocalAuthentication
import Observation

@MainActor @Observable
final class LockerModel {
    struct NewVaultSecret {
        let method: VaultAuthenticationMethod
        let value: String
    }

    struct NewVaultSetup: Identifiable {
        let id = UUID()
        let mode: AccessMode
        let newSlot: Bool
        let afterOpen: (() -> Void)?
    }

    var newVaultSetup: NewVaultSetup?
    typealias OpenSession = (AccessMode, URL, LAContext, SessionGate, Bool, VaultAuthenticationMethod, NewVaultSecret?) async throws -> VaultStore
    @ObservationIgnored private let openSession: OpenSession
    let base: URL
    var vaultNames: [String: String] = [:]
    private(set) var vaultKinds: [String: VaultKind] = [:]
    private(set) var removingVault = false
    var removalRequest: String?
    var slots: [String] = []
    var slot = "" {
        didSet { if slot != oldValue { authenticationMethod = Self.method(for: slot) } }
    }
    private(set) var authenticationMethod = VaultAuthenticationMethod.passcode

    static func method(for slot: String) -> VaultAuthenticationMethod {
        guard !slot.isEmpty else { return .passcode }
        return DeviceKeychain(account: slot).customMethod() ?? .preferred(for: slot)
    }

    func rememberAuthenticationMethod(_ method: VaultAuthenticationMethod) {
        guard store != nil, !authenticationMethod.isCustom, !method.isCustom else { return }
        method.remember(for: slot)
        authenticationMethod = method
    }

    var store: VaultStore?
    var familyMode = false {
        didSet {
            if let store {
                vaultKinds[slot] = VaultKind.cached(in: store.root) ?? (familyMode ? .family : .personal)
            }
        }
    }
    var library = VaultLibrary()
    var documents: [ListedDocument] { library.documents }
    var vaultTitle: String { name(of: slot) }

    private func name(of id: String) -> String {
        if let name = vaultNames[id] { return name }
        if store != nil && id == slot { return (familyMode ? VaultKind.family : .personal).title }
        return vaultKinds[id]?.title ?? "Coffre"
    }

    func pickerTitle(for id: String) -> String {
        let title = name(of: id)
        return slots.contains { $0 != id && name(of: $0) == title } ? title + " · " + id.prefix(8) : title
    }
    var extracting = false
    var reviewingImport = false
    var duplicateImport: DuplicateImport?
    var openAfterImport: UUID?
    @ObservationIgnored var importAnswer: CheckedContinuation<DuplicateChoice?, Never>?

    var pendingArchivePlacement: SelectedImport?
    var pendingNearbyRole: NearbyRole?
    var opening = false
    private(set) var changingProtection = false
    private(set) var requiresAuthentication = true
    var repairSelected = false
    var problem: String?
    var configuration = ProviderSettings()
    var syncStatus = ""
    var syncing = false
    var recovery: String?
    var timeout: Int = UserDefaults.standard.integer(forKey: "idleSeconds") {
        didSet { UserDefaults.standard.set(timeout, forKey: "idleSeconds"); activity() }
    }
    @ObservationIgnored private var accessGate: SessionGate?
    @ObservationIgnored private var context: LAContext?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivity = ContinuousClock.now
    @ObservationIgnored private var nextSync = ContinuousClock.now

    init(base: URL = URL.applicationSupportDirectory.appendingPathComponent("Locker/vaults", isDirectory: true),
         openSession: @escaping OpenSession = LockerModel.authenticateAndOpen) {
        self.openSession = openSession
        self.base = base
        if timeout <= 0 { timeout = 120 }
        let directories = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for path in directories where path.hasPrefix(".removing.") {
            do { try LocalVaultRemoval(directory: base.appendingPathComponent(path))?.finish() }
            catch { problem = "Le nettoyage d’un coffre supprimé reprendra à la prochaine ouverture." }
        }
        slots = directories.filter { UUID(uuidString: $0) != nil }.sorted()
        for id in slots {
            vaultKinds[id] = VaultKind.cached(in: base.appendingPathComponent(id))
            if let bytes = try? Self.nameItem(id).read() { vaultNames[id] = String(data: bytes, encoding: .utf8) }
        }
        slot = slots.first ?? ""
        authenticationMethod = Self.method(for: slot)
    }

    func adoptRotated(_ session: VaultStore, slotID: String, code: String) async throws {
        accessGate = session.gate
        let list = try await session.library()
        try session.gate.check()
        requiresAuthentication = DeviceKeychain(account: slotID).requiresAuthentication()
        slot = slotID
        store = session
        familyMode = await session.family != nil
        library = list
        recovery = code
        activity()
    }

    static func nameItem(_ slot: String) -> ProviderCredential {
        ProviderCredential(account: slot, serviceSuffix: ".vault-name")
    }

    func renameVault(_ proposed: String) throws {
        guard let store else { throw VaultError.locked }
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TransportError(message: "Saisissez un nom de coffre.") }
        try store.gate.authorized { try Self.nameItem(slot).save(Data(name.utf8)) }
        vaultNames[slot] = name
        activity()
    }

    func requestLocalRemoval() {
        guard let store, store.root.lastPathComponent == slot, !removingVault else { return }
        Task {
            do {
                let reason = try await store.removalProtectionReason()
                guard self.store === store else { return }
                if let reason { problem = reason } else { removalRequest = slot }
            } catch { if self.store === store { problem = error.localizedDescription } }
        }
    }

    func removeUnsharedVault(_ id: String) async {
        guard !removingVault, slot == id, let session = store else { return }
        removingVault = true
        defer { removingVault = false }
        do {
            syncTask?.cancel()
            await syncTask?.value
            guard store === session, slot == id else { return }
            syncing = false
            let removal = try await session.retireUnsharedVault(in: base, slot: id)
            if store === session { lock() }
            slots.removeAll { $0 == id }
            vaultKinds[id] = nil
            vaultNames[id] = nil
            if slot == id { slot = slots.first ?? "" }
            do { try removal.finish() }
            catch { problem = "Coffre retiré. Le nettoyage local reprendra à la prochaine ouverture." }
        } catch { if store === session { problem = error.localizedDescription } }
    }

    func activity() { lastActivity = .now }
    func tick(at now: ContinuousClock.Instant = .now) {
        guard store != nil else { return }
        if lastActivity.duration(to: now) >= .seconds(timeout) { lock(); return }
        if now >= nextSync { sync() }
    }

    func lock() {
        resolveDuplicate(nil)
        reviewingImport = false
        openAfterImport = nil
        newVaultSetup = nil
        removalRequest = nil
        if let store, let kind = VaultKind.cached(in: store.root) { vaultKinds[slot] = kind }
        accessGate?.revoke()
        context?.invalidate()
        context = nil
        changingProtection = false
        syncTask?.cancel()
        syncTask = nil
        accessGate = nil
        store = nil
        familyMode = false
        library = VaultLibrary()
        opening = false
        extracting = false
        pendingArchivePlacement = nil
        pendingNearbyRole = nil
        syncing = false
        configuration = ProviderSettings()
        recovery = nil
        problem = nil
        syncStatus = ""
    }

    nonisolated static func authenticateAndOpen(_ mode: AccessMode, at root: URL,
                                                context: LAContext, gate: SessionGate,
                                                protectNewKey: Bool, method: VaultAuthenticationMethod,
                                                newSecret: NewVaultSecret? = nil) async throws -> VaultStore {
        var device = DeviceKeychain(account: root.lastPathComponent, protectNewKey: protectNewKey)
        if let newSecret {
            switch mode {
            case .create, .recover: break
            case .unlock, .unlockWithSecret: throw VaultError.changed
            }
            guard protectNewKey, newSecret.method.isCustom else { throw VaultError.changed }
            try newSecret.method.validateNewSecret(newSecret.value)
            device.secret = newSecret.value
            device.newMethod = newSecret.method
        }
        switch mode {
        case let .unlockWithSecret(secret):
            guard device.customMethod() != nil else { throw VaultError.changed }
            device.secret = secret
            context.interactionNotAllowed = true
            let protectedDevice = device
            return try await Task.detached {
                try VaultAccess.open(mode, at: root, device: protectedDevice, context: context, gate: gate)
            }.value
        case .unlock:
            guard device.customMethod() == nil else { throw VaultSecretError.incorrect }
            device.protectNewKey = device.requiresAuthentication()
        case let .recover(code) where FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.v1").path):
            if device.customMethod() != nil {
                let keys = try VaultKeys(code: code)
                _ = try VaultStore.readCatalog(root.appendingPathComponent("catalog.v1"), keys: keys)
                if let newSecret {
                    try device.replaceKey(keys, method: newSecret.method, newSecret: newSecret.value,
                                          required: true, context: context, gate: gate)
                } else {
                    try await VaultAuthenticationMethod.passcode.confirm(using: context, reason: "Réparer la protection de ce coffre")
                    try device.replaceKey(keys, method: .passcode, newSecret: nil, required: true, context: context, gate: gate)
                    VaultAuthenticationMethod.passcode.remember(for: root.lastPathComponent)
                }
                return try VaultAccess.open(.unlock, at: root, device: device, context: context, gate: gate)
            }
            guard newSecret == nil else { throw VaultError.changed }
            device.protectNewKey = device.requiresAuthentication()
        default: break
        }
        if device.protectNewKey && newSecret == nil {
            try await method.confirm(using: context, reason: "Accéder à ce coffre sur cet appareil")
        }
        return try await Task.detached {
            try VaultAccess.open(mode, at: root, device: device, context: context, gate: gate)
        }.value
    }

    func setSecretProtection(to target: VaultAuthenticationMethod, required: Bool,
                             currentSecret: String, newSecret: String) async throws {
        guard let session = store, !opening, !changingProtection else { throw VaultError.unavailable }
        let current = authenticationMethod
        guard current.isCustom || target.isCustom else { throw VaultError.changed }
        if target.isCustom { try target.validateNewSecret(newSecret) }
        let auth = LAContext()
        activity()
        context = auth
        changingProtection = true
        defer {
            auth.invalidate()
            if context === auth { context = nil; changingProtection = false; activity() }
        }
        if !current.isCustom {
            try await current.confirm(using: auth, reason: "Modifier le déverrouillage du coffre")
        } else if !target.isCustom && required {
            try await target.confirm(using: auth, reason: "Confirmer la nouvelle méthode de déverrouillage")
        }
        let device = DeviceKeychain(account: slot, secret: current.isCustom ? currentSecret : nil)
        try await Task.detached {
            try session.gate.check()
            let keys = try device.read(context: auth)
            try device.replaceKey(keys, method: target, newSecret: newSecret, required: required,
                                  context: auth, gate: session.gate)
        }.value
        guard store === session else { throw VaultError.locked }
        target.remember(for: slot)
        authenticationMethod = target
        requiresAuthentication = required
    }

    func setAuthenticationRequired(_ required: Bool) async throws {
        guard let session = store, !opening, !changingProtection, required != requiresAuthentication else { return }
        let auth = LAContext()
        let device = DeviceKeychain(account: slot)
        activity()
        context = auth
        changingProtection = true
        defer {
            auth.invalidate()
            if context === auth { context = nil; changingProtection = false; activity() }
        }
        try await device.changeProtection(required: required, method: authenticationMethod, context: auth, gate: session.gate)
        if store === session { requiresAuthentication = required }
    }

    func completeNewVaultSetup(_ setup: NewVaultSetup, with credential: NewVaultSecret) {
        guard newVaultSetup?.id == setup.id else { return }
        newVaultSetup = nil
        open(setup.mode, newSlot: setup.newSlot, newSecret: credential, afterOpen: setup.afterOpen)
    }

    func open(_ mode: AccessMode, newSlot: Bool = false, protectNewKey: Bool = true,
              newSecret: NewVaultSecret? = nil, afterOpen: (() -> Void)? = nil) {
        guard !opening, store == nil else { return }
        #if targetEnvironment(simulator)
        // The simulator cannot evaluate the device-passcode access control (LA error -1020).
        if newSecret == nil {
            switch mode {
            case .create where newSlot && protectNewKey,
                 .recover where (newSlot ? protectNewKey : authenticationMethod.isCustom):
                newVaultSetup = NewVaultSetup(mode: mode, newSlot: newSlot, afterOpen: afterOpen)
                return
            default: break
            }
        }
        #endif
        let selected = newSlot ? UUID().uuidString : slot
        guard UUID(uuidString: selected) != nil else { return }
        let root = base.appendingPathComponent(selected)
        let method = Self.method(for: selected)
        let gate = SessionGate()
        let auth = LAContext()
        auth.localizedReason = "Ouvrir le coffre documentaire"
        context = auth
        accessGate = gate
        opening = true
        Task {
            defer { if accessGate === gate { opening = false; auth.invalidate(); context = nil } }
            do {
                let session = try await openSession(mode, root, auth, gate, protectNewKey, method, newSecret)
                let list = try await session.library()
                let shared = await session.family != nil
                let config: ProviderSettings
                var transportIssue: String?
                do { try await session.resumeDropboxAuthorization(); config = try await session.settings() }
                catch {
                    config = ProviderSettings()
                    transportIssue = "Les réglages de synchronisation sont illisibles. Le coffre est ouvert en mode local."
                }
                let code: String?
                if case .create = mode { code = try await session.recoveryCode() } else { code = nil }
                try gate.check()
                requiresAuthentication = DeviceKeychain(account: selected).requiresAuthentication()
                slot = selected
                authenticationMethod = Self.method(for: selected)
                if !slots.contains(selected) { slots.append(selected) }
                library = list
                configuration = config
                problem = transportIssue
                recovery = code
                store = session
                familyMode = shared
                afterOpen?()
                activity()
                sync()
            } catch { if accessGate === gate { problem = error.localizedDescription } }
        }
    }

    func perform(_ operation: @escaping (VaultStore) async throws -> Void) {
        guard let session = store else { return }
        activity()
        Task {
            do {
                try await operation(session)
                let updated = try await session.library()
                guard store === session else { return }
                library = updated
                nextSync = .now
            } catch { if store === session { problem = error.localizedDescription } }
        }
    }

    func sync() {
        guard removalRequest == nil, !removingVault, !syncing, configuration.provider != .local, let session = store else { return }
        syncing = true
        session.syncProgress.begin("Connexion au fournisseur…")
        let provider = configuration.provider
        syncTask = Task {
            do {
                try await session.syncConfigured()
                let updated = try await session.library()
                guard store === session, !Task.isCancelled else { return }
                library = updated
                vaultKinds[slot] = VaultKind.cached(in: session.root)
                syncStatus = "À jour · " + Date.now.formatted(date: .omitted, time: .shortened)
            } catch {
                guard store === session, !Task.isCancelled else { return }
                let refreshed = try? await session.library()
                guard store === session, !Task.isCancelled else { return }
                if let refreshed { library = refreshed }
                syncStatus = "\(provider.rawValue) en attente · \(error.localizedDescription)"
            }
            syncing = false
            nextSync = .now.advanced(by: .seconds(30))
        }
    }

    func prepareOAuth() async throws -> OAuthHandoff {
        guard let session = store else { throw VaultError.locked }
        let card = try await session.publicIdentity()
        try session.gate.check()
        return OAuthHandoff(slot: slot, recipient: card)
    }

    func finishOAuth(_ handoff: OAuthHandoff, config: ProviderSettings, refresh: String) async throws {
        try handoff.finish(config: config, refresh: refresh)
        guard slot == handoff.slot, let session = store else { return }
        syncTask?.cancel()
        await syncTask?.value
        try await session.resumeDropboxAuthorization()
        try session.gate.check()
        configuration = config
        syncing = false
        sync()
    }

    func configure(_ config: ProviderSettings, credential: String?) async throws {
        guard let session = store else { throw VaultError.locked }
        // Finish cancellation before replacing a destination. Offline reads and writes remain available.
        syncTask?.cancel()
        await syncTask?.value
        try await session.configure(config, credential: credential)
        try session.gate.check()
        syncing = false
        configuration = config
        syncStatus = ""
        sync()
    }
}
