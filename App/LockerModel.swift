import Foundation
import LocalAuthentication
import Observation

@MainActor @Observable
final class LockerModel {
    let base = URL.applicationSupportDirectory.appendingPathComponent("Locker/vaults", isDirectory: true)
    var slots: [String] = []
    var slot = ""
    var store: VaultStore?
    var documents: [ListedDocument] = []
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

    init() {
        if timeout <= 0 { timeout = 120 }
        slots = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { UUID(uuidString: $0) != nil }.sorted()
        slot = slots.first ?? ""
    }

    func adoptRotated(_ session: VaultStore, slotID: String, code: String) async throws {
        accessGate = session.gate
        let list = try await session.list()
        try session.gate.check()
        slot = slotID
        store = session
        documents = list
        recovery = code
        activity()
    }

    func activity() { lastActivity = .now }
    func tick() {
        guard store != nil else { return }
        if lastActivity.duration(to: .now) >= .seconds(timeout) { lock(); return }
        if ContinuousClock.now >= nextSync { sync() }
    }

    func lock() {
        accessGate?.revoke()
        context?.invalidate()
        context = nil
        syncTask?.cancel()
        syncTask = nil
        accessGate = nil
        store = nil
        documents = []
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
                let list = try await session.list()
                let config = try await session.settings()
                let code: String?
                if case .create = mode { code = try await session.recoveryCode() } else { code = nil }
                try gate.check()
                slot = selected
                if !slots.contains(selected) { slots.append(selected) }
                documents = list
                configuration = config
                recovery = code
                store = session
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
                let updated = try await session.list()
                guard store === session else { return }
                documents = updated
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
                let updated = try await session.list()
                guard store === session, !Task.isCancelled else { return }
                documents = updated
                syncStatus = "À jour · " + Date.now.formatted(date: .omitted, time: .shortened)
            } catch {
                guard store === session, !Task.isCancelled else { return }
                syncStatus = "\(provider.rawValue) en attente · \(error.localizedDescription)"
            }
            syncing = false
            nextSync = .now.advanced(by: .seconds(30))
        }
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
