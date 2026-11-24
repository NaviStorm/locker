import Foundation
import Security

enum VaultKind: String {
    case personal, unsharedFamily, family

    init(_ state: FamilyLocal?, keys: VaultKeys) {
        guard let state else { self = .personal; return }
        self = Self.protectionReason(state, keys: keys) == nil ? .unsharedFamily : .family
    }

    static func protectionReason(_ state: FamilyLocal, keys: VaultKeys) -> String? {
        guard let policy = try? state.tip.decoded(),
              let origin = try? (state.history?.first ?? state.tip).decoded() else {
            return "Locker ne peut pas vérifier les autorisations de ce coffre."
        }
        if state.joinedByInvitation == true { return "Cet appareil a rejoint le coffre d’un autre propriétaire par invitation." }
        guard origin.parent == nil, origin.author == state.principal else {
            return "Cet appareil ne dispose pas de l’historique du propriétaire d’origine du coffre."
        }
        guard let rescue = try? DeviceIdentity(rescue: keys).card.fingerprint else {
            return "L’identité de secours du propriétaire n’a pas pu être vérifiée."
        }
        let members = Set(policy.members.map(\.card.fingerprint))
        let expected = Set([state.principal, rescue])
        let others = members.subtracting(expected)
        if !others.isEmpty {
            let names = others.sorted().map { state.displayName(for: $0) ?? String($0.prefix(12)) }
            return "Accès encore autorisé pour " + names.joined(separator: ", ") + "."
        }
        guard members == expected else { return "Les autorisations du propriétaire et du secours sont incomplètes." }
        if state.removals?.isEmpty == false { return "Le retrait d’un ancien accès attend la confirmation du fournisseur." }
        if policy.parent != nil && !state.waiting.isEmpty { return "La dernière modification des droits attend la synchronisation." }
        return nil
    }

    var title: String { self == .personal ? "Coffre personnel" : "Coffre familial" }

    // A display hint for the locked picker. Deletion always checks the encrypted catalogue.
    static func cached(in root: URL) -> Self? {
        guard let value = try? String(contentsOf: root.appendingPathComponent("kind.v1"), encoding: .utf8) else { return nil }
        return Self(rawValue: value)
    }

    func cache(in root: URL) {
        guard Self.cached(in: root) != self else { return }
        try? VaultFiles.save(Data(rawValue.utf8), to: root.appendingPathComponent("kind.v1"))
    }
}

struct LocalVaultRemoval {
    let directory: URL
    let slot: String
    let keyID: String

    init?(directory: URL) {
        let parts = directory.lastPathComponent.components(separatedBy: ".")
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "removing",
              UUID(uuidString: parts[2]) != nil, parts[3].count == 32,
              parts[3].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.directory = directory
        slot = parts[2]
        keyID = parts[3]
    }

    func finish(removeItem: ([String: Any]) throws -> Void = Self.removeKeychainItem,
                preferences: UserDefaults = .standard) throws {
        let original = directory.deletingLastPathComponent().appendingPathComponent(slot)
        guard !FileManager.default.fileExists(atPath: original.path) else { throw VaultError.changed }
        for item in [DeviceKeychain(account: slot).query,
                     ProviderCredential(account: slot, serviceSuffix: ".vault-name").query,
                     ProviderCredential(account: "identity-" + slot + "-" + keyID).query,
                     ProviderCredential(account: "oauth-stage-" + slot).query] {
            try removeItem(item)
        }
        preferences.removeObject(forKey: "authenticationMethod." + slot)
        try FileManager.default.removeItem(at: directory)
    }

    private static func removeKeychainItem(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }
}

extension VaultStore {
    func retireUnsharedVault(in base: URL, slot: String) throws -> LocalVaultRemoval {
        guard UUID(uuidString: slot) != nil,
              root.standardizedFileURL.path == base.appendingPathComponent(slot).standardizedFileURL.path,
              try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw VaultError.unavailable }
        return try gate.close {
            let catalog = try Self.readCatalog(root.appendingPathComponent("catalog.v1"), keys: keys)
            if let reason = [family, catalog.family].compactMap({ $0 }).compactMap({ VaultKind.protectionReason($0, keys: keys) }).first {
                throw TransportError(message: reason)
            }
            let destination = base.appendingPathComponent(".removing." + slot + "." + keys.identifier)
            guard let removal = LocalVaultRemoval(directory: destination) else { throw VaultError.unavailable }
            try FileManager.default.moveItem(at: root, to: destination)
            return removal
        }
    }
}
