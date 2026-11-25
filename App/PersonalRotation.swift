import Foundation
import LocalAuthentication

extension LockerModel {
    func rotatePersonal(secret: String = "") async throws {
        guard let source = store, await source.family == nil, !opening else { throw FamilyError.denied }
        let id = UUID().uuidString
        let staging = base.appendingPathComponent("rotation-" + id)
        let destination = base.appendingPathComponent(id)
        let auth = LAContext()
        let gate = SessionGate()
        opening = true
        defer { auth.invalidate(); gate.revoke(); opening = false }
        let method = authenticationMethod
        if method.isCustom {
            let current = DeviceKeychain(account: slot, secret: secret)
            _ = try await Task.detached { try current.read(context: auth) }.value
        } else {
            try await method.confirm(using: auth, reason: "Créer une nouvelle clé pour ce coffre")
        }
        try source.gate.check()
        let device = DeviceKeychain(account: id, protectNewKey: requiresAuthentication, secret: method.isCustom ? secret : nil,
                                    newMethod: method.isCustom ? method : nil)
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
        rememberAuthenticationMethod(method)
    }
}
