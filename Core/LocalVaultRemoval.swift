import Foundation
import Security

enum VaultKind: String {
    case personal, unsharedFamily, family

    init(_ state: FamilyLocal?, keys: VaultKeys) {
        guard let state else { self = .personal; return }
        self = .family
        guard let policy = try? state.tip.decoded(),
              let origin = try? (state.history?.first ?? state.tip).decoded(),
              origin.parent == nil, origin.author == state.principal,
              let rescue = try? DeviceIdentity(rescue: keys).card.fingerprint,
              Set(policy.members.map(\.card.fingerprint)) == Set([state.principal, rescue]),
              state.removals?.isEmpty != false,
              policy.parent == nil || state.waiting.isEmpty else { return }
        self = .unsharedFamily
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
            guard VaultKind(family, keys: keys) != .family, VaultKind(catalog.family, keys: keys) != .family else {
                throw TransportError(message: "Ce coffre familial est protégé contre la suppression.")
            }
            let destination = base.appendingPathComponent(".removing." + slot + "." + keys.identifier)
            guard let removal = LocalVaultRemoval(directory: destination) else { throw VaultError.unavailable }
            try FileManager.default.moveItem(at: root, to: destination)
            return removal
        }
    }
}
