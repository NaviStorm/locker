import Foundation
import LocalAuthentication

extension LockerModel {
    func rotatePersonal() async throws {
        guard let source = store, await source.family == nil, !opening else { throw FamilyError.denied }
        let id = UUID().uuidString
        let staging = base.appendingPathComponent("rotation-" + id)
        let destination = base.appendingPathComponent(id)
        let auth = LAContext()
        let gate = SessionGate()
        opening = true
        defer { auth.invalidate(); gate.revoke(); opening = false }
        guard try await auth.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Créer une nouvelle clé pour ce coffre")
        else { throw VaultError.locked }
        try source.gate.check()
        let device = DeviceKeychain(account: id, protectNewKey: requiresAuthentication)
        let target = try await Task.detached {
            try VaultAccess.open(.create, at: staging, device: device, context: auth, gate: gate)
        }.value
        defer { if FileManager.default.fileExists(atPath: staging.path) { try? FileManager.default.removeItem(at: staging) } }
        try await source.copyPersonalContents(to: target)
        try source.gate.check()
        let newCode = try await target.recoveryCode()
        try FileManager.default.moveItem(at: staging, to: destination)
        if !slots.contains(id) { slots.append(id) }
        try await configure(ProviderSettings(), credential: nil)
        try source.gate.check()
        lock()
        let session = try VaultStore(root: destination, keys: VaultKeys(code: newCode))
        try await adoptRotated(session, slotID: id, code: newCode)
    }
}
