import Foundation
import LocalAuthentication
import Observation

@MainActor @Observable
final class LockerModel {
    let base: URL
    var vaultNames: [String: String] = [:]
    var slots: [String] = []
    var slot = ""
    var store: VaultStore?
    var familyMode = false
    var library = VaultLibrary()
    var documents: [ListedDocument] { library.documents }
    var vaultTitle: String { vaultNames[slot] ?? (familyMode ? "Coffre familial" : "Coffre personnel") }
    var opening = false
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

    init(base: URL = URL.applicationSupportDirectory.appendingPathComponent("Locker/vaults", isDirectory: true)) {
        self.base = base
        if timeout <= 0 { timeout = 120 }
        slots = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { UUID(uuidString: $0) != nil }.sorted()
        for id in slots {
            if let bytes = try? Self.nameItem(id).read() { vaultNames[id] = String(data: bytes, encoding: .utf8) }
        }
        slot = slots.first ?? ""
    }

    func adoptRotated(_ session: VaultStore, slotID: String, code: String) async throws {
        accessGate = session.gate
        let list = try await session.library()
        try session.gate.check()
        slot = slotID
        store = session
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

    func activity() { lastActivity = .now }
    func tick(at now: ContinuousClock.Instant = .now) {
        guard store != nil else { return }
        if lastActivity.duration(to: now) >= .seconds(timeout) { lock(); return }
        if now >= nextSync { sync() }
    }

    func lock() {
        accessGate?.revoke()
        context?.invalidate()
        context = nil
        syncTask?.cancel()
        syncTask = nil
        accessGate = nil
        store = nil
        familyMode = false
        library = VaultLibrary()
        opening = false
        syncing = false
        configuration = ProviderSettings()
        recovery = nil
        problem = nil
        syncStatus = ""
    }

    func open(_ mode: AccessMode, newSlot: Bool = false) {
        guard !opening, store == nil else { return }
        let selected = newSlot ? UUID().uuidString : slot
        guard UUID(uuidString: selected) != nil else { return }
        let root = base.appendingPathComponent(selected)
        let device = DeviceKeychain(account: selected)
        let gate = SessionGate()
        let auth = LAContext()
        auth.localizedReason = "Ouvrir le coffre documentaire"
        context = auth
        accessGate = gate
        opening = true
        Task {
            defer { if accessGate === gate { opening = false; auth.invalidate(); context = nil } }
            do {
                if case .unlock = mode {} else {
                    guard try await auth.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Autoriser ce coffre sur cet appareil")
                    else { throw VaultError.locked }
                }
                let session = try await Task.detached {
                    try VaultAccess.open(mode, at: root, device: device, context: auth, gate: gate)
                }.value
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
                slot = selected
                if !slots.contains(selected) { slots.append(selected) }
                library = list
                configuration = config
                problem = transportIssue
                recovery = code
                store = session
                familyMode = shared
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
        guard !syncing, configuration.provider != .local, let session = store else { return }
        syncing = true
        let provider = configuration.provider
        syncTask = Task {
            do {
                try await session.syncConfigured()
                let updated = try await session.library()
                guard store === session, !Task.isCancelled else { return }
                library = updated
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
