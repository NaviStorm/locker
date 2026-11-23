import CryptoKit
import Foundation
import Security

enum Provider: String, CaseIterable, Codable {
    case local = "Local uniquement", cloud = "iCloud", dropbox = "Dropbox", webdav = "WebDAV / Synology"
}

struct ProviderSettings: Codable, Equatable {
    var provider = Provider.local
    var endpoint = ""
    var username = ""
    var appKey = ""
    var sharedFolder = ""
    var destination: String {
        let fields = [provider.rawValue, endpoint, sharedFolder]
        return (try? JSONEncoder().encode(fields).base64EncodedString()) ?? ""
    }
}

extension VaultStore {
    func settings() throws -> ProviderSettings {
        try gate.check()
        let url = root.appendingPathComponent("transport.v1")
        guard FileManager.default.fileExists(atPath: url.path) else { return ProviderSettings() }
        return try Self.unpack(ProviderSettings.self, data: Data(contentsOf: url), keys: keys, purpose: "transport")
    }

    func configure(_ config: ProviderSettings, credential: String?) throws {
        try gate.check()
        if config.provider == .webdav {
            _ = try WebDAVBucket(server: config.endpoint, user: config.username, password: "", vault: keys.identifier)
        }
        if let credential {
            let data = try Self.pack(credential, keys: keys, purpose: "provider/" + config.provider.rawValue)
            try ProviderCredential(account: credentialAccount(config)).save(data)
        }
        if credential == nil && [.dropbox, .webdav].contains(config.provider) {
            _ = try ProviderCredential(account: credentialAccount(config)).read()
        }
        if (try? settings()) != config {
            let oldCursor = root.appendingPathComponent("remote-tags.v1")
            if FileManager.default.fileExists(atPath: oldCursor.path) { try FileManager.default.removeItem(at: oldCursor) }
        }
        if var state = family, config.provider != .local {
            let destination = config.destination
            if state.destination != destination {
                state.bootstrap = state.destination != nil && (try? state.tip.decoded().member(state.principal)?.role) == .admin
                state.destination = destination
                state.seen = []
                let queue = state.bootstrap == true ? entries.mapValues(\.revision) : pending
                try commit(entries, queue, family: state)
            }
        }
        let data = try Self.pack(config, keys: keys, purpose: "transport")
        try gate.authorized { try VaultFiles.save(data, to: root.appendingPathComponent("transport.v1")) }
    }

    func hasSavedWebDAVPassword(for config: ProviderSettings) throws -> Bool {
        try gate.check()
        guard config.provider == .webdav else { return false }
        return try ProviderCredential(account: credentialAccount(config)).exists()
    }

    func credentialAccount(_ config: ProviderSettings) -> String {
        // Bind a saved password to its server and user; editing a URL must never forward an old password.
        let fields = [keys.identifier, config.provider.rawValue, config.endpoint, config.username, config.appKey]
        return SHA256.hash(data: (try? JSONEncoder().encode(fields)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    func syncConfigured() async throws {
        let config = try settings()
        guard config.provider != .local else { return }
        let bucket = try await objectBucket(config)
        if family != nil {
            try await synchronizeFamily(bucket: bucket, identity: identity())
        } else {
            let replica = try ObjectReplica(bucket: bucket, cache: root.appendingPathComponent("transfers"), gate: gate)
            try await synchronize(with: replica)
        }
        try gate.authorized {
            for directory in ["transfers", "family-transfers"] {
                let cache = root.appendingPathComponent(directory)
                if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
            }
        }
    }

    func objectBucket(_ config: ProviderSettings) async throws -> ObjectBucket {
        let namespace = try family?.tip.decoded().vault.uuidString.lowercased() ?? keys.identifier
        switch config.provider {
        case .local: throw VaultError.unavailable
        case .cloud:
            return try await CloudBucket.connect(vault: namespace, invitation: family?.cloudURL,
                                                 cache: root.appendingPathComponent("transfers"))
        case .dropbox, .webdav:
            let data = try ProviderCredential(account: credentialAccount(config)).read()
            let secret = try Self.unpack(String.self, data: data, keys: keys, purpose: "provider/" + config.provider.rawValue)
            let bucket: ObjectBucket
            if config.provider == .webdav {
                bucket = try WebDAVBucket(server: config.endpoint, user: config.username, password: secret, vault: namespace)
            } else {
                let folder = config.sharedFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                guard folder.isEmpty || (folder.hasPrefix("/") && folder.utf8.allSatisfy({ (32...126).contains($0) })) else {
                    throw TransportError(message: "Utilisez un chemin Dropbox ASCII commençant par /.")
                }
                bucket = DropboxBucket(client: config.appKey, refresh: secret, folder: folder + "/locker-" + namespace)
            }
            return bucket
        }
    }
}

struct ProviderCredential {
    let account: String
    var serviceSuffix = ".transport"
    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecUseDataProtectionKeychain as String: true,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Locker") + serviceSuffix,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    func save(_ bytes: Data) throws {
        let updates = [kSecValueData as String: bytes]
        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(updates) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }

    func exists() throws -> Bool {
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        return true
    }

    func read() throws -> Data {
        var query = query
        query[kSecReturnData as String] = true
        var data: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &data)
        guard status == errSecSuccess, let value = data as? Data else { throw KeychainFailure(status: status) }
        return value
    }
}
