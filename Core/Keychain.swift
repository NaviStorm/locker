import Foundation
import LocalAuthentication
import Security

protocol DeviceKeyAccess {
    func read(context: LAContext) throws -> VaultKeys
    func install(_ keys: VaultKeys, context: LAContext) throws
}

struct KeychainFailure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Erreur du Trousseau (\(status))."
    }
}

struct DeviceKeychain: DeviceKeyAccess {
    var account = "root-v1"
    var protectNewKey = true
    var secret: String?
    var newMethod: VaultAuthenticationMethod?
    private static let unlockedMarker = Data("device-unlocked-v1".utf8)
    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Locker") + ".vault",
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    func read(context: LAContext) throws -> VaultKeys {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainFailure(status: status) }
        if data.count == 32 {
            guard secret == nil else { throw VaultError.changed }
            return try VaultKeys(secret: data)
        }
        guard let secret else { throw VaultSecretError.incorrect }
        return try JSONDecoder().decode(WrappedVaultKey.self, from: data).open(secret: secret, account: account)
    }

    // Older items have no marker and require user presence. The ACL enforces access.
    private func marker() -> Data? {
        var lookup = query
        let silent = LAContext()
        silent.interactionNotAllowed = true
        lookup[kSecUseAuthenticationContext as String] = silent
        lookup[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrGeneric as String] as? Data
    }

    func requiresAuthentication() -> Bool { marker() != Self.unlockedMarker }

    func customMethod() -> VaultAuthenticationMethod? {
        guard let marker = marker(), let tag = String(data: marker, encoding: .utf8),
              let method = VaultAuthenticationMethod(rawValue: tag), method.isCustom else { return nil }
        return method
    }

    private func protectionAttributes(required: Bool, custom: VaultAuthenticationMethod? = nil) throws -> [String: Any] {
        var accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #if os(iOS)
        if required { accessibility = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
        #endif
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, accessibility, required && custom == nil ? .userPresence : [], &error) else {
            throw error?.takeRetainedValue() as Error? ?? VaultError.unavailable
        }
        return [kSecAttrAccessControl as String: control,
                kSecAttrGeneric as String: custom.map { Data($0.rawValue.utf8) } ?? (required ? Data("user-presence-v1".utf8) : Self.unlockedMarker)]
    }

    // Replace the value and its access control together. A failed update leaves the original item usable.
    func replaceKey(_ keys: VaultKeys, method: VaultAuthenticationMethod, newSecret: String?,
                    required: Bool, context: LAContext, gate: SessionGate) throws {
        let attributes = try storageAttributes(keys, method: method, password: newSecret, required: required)
        var lookup = query
        lookup[kSecUseAuthenticationContext as String] = context
        try gate.authorized {
            let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        }
    }

    private func storageAttributes(_ keys: VaultKeys, method: VaultAuthenticationMethod,
                                   password: String?, required: Bool) throws -> [String: Any] {
        if method.isCustom {
            guard required, let password else { throw VaultError.locked }
            var attrs = try protectionAttributes(required: true, custom: method)
            attrs[kSecValueData as String] = try WrappedVaultKey.make(keys: keys, secret: password, method: method, account: account)
            return attrs
        }
        var attrs = try protectionAttributes(required: required)
        attrs[kSecValueData as String] = keys.secret
        return attrs
    }

    func changeProtection(required: Bool, method: VaultAuthenticationMethod, context: LAContext, gate: SessionGate) async throws {
        let reason = required ? "Activer la protection de ce coffre" : "Autoriser l’ouverture de ce coffre sans authentification"
        try await method.confirm(using: context, reason: reason)
        try gate.check()
        try replaceKey(read(context: context), method: method, newSecret: nil, required: required, context: context, gate: gate)
    }

    func install(_ keys: VaultKeys, context: LAContext) throws {
        var item = query.merging(try storageAttributes(keys, method: newMethod ?? .passcode, password: secret, required: protectNewKey)) { _, new in new }
        item[kSecUseAuthenticationContext as String] = context
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard try read(context: context).secret == keys.secret else { throw VaultError.exists }
        } else if status != errSecSuccess {
            throw KeychainFailure(status: status)
        }
    }
}

enum AccessMode { case unlock, unlockWithSecret(String), create, recover(String) }

enum VaultAccess {
    /// Reading the item enforces the access control chosen for this vault on this device.
    static func open(_ mode: AccessMode, at root: URL, device: DeviceKeyAccess,
                     context: LAContext, gate: SessionGate) throws -> VaultStore {
        let catalog = root.appendingPathComponent("catalog.v1")
        let existing = FileManager.default.fileExists(atPath: catalog.path)
        switch mode {
        case .unlock, .unlockWithSecret: guard existing else { throw VaultError.unavailable }
        case .create, .recover:
            let keys: VaultKeys
            if case let .recover(code) = mode { keys = try VaultKeys(code: code) }
            else {
                guard !existing else { throw VaultError.exists }
                keys = VaultKeys()
            }
            if existing {
                // Prove possession before changing the local keychain.
                _ = try VaultStore.readCatalog(catalog, keys: keys)
            }
            try gate.check()
            try device.install(keys, context: context)
        }
        let authorized = try device.read(context: context)
        return try gate.authorized { try VaultStore(root: root, keys: authorized, create: !existing, gate: gate) }
    }
}
