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
    private var query: [String: Any] {
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
        return try VaultKeys(secret: data)
    }

    func install(_ keys: VaultKeys, context: LAContext) throws {
        #if os(iOS)
        let protection = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        #else
        let protection = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, protection, .userPresence, &error) else {
            throw error?.takeRetainedValue() as Error? ?? VaultError.unavailable
        }
        var item = query
        item[kSecAttrAccessControl as String] = control
        item[kSecValueData as String] = keys.secret
        item[kSecUseAuthenticationContext as String] = context
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard try read(context: context).secret == keys.secret else { throw VaultError.exists }
        } else if status != errSecSuccess {
            throw KeychainFailure(status: status)
        }
    }
}

enum AccessMode { case unlock, create, recover(String) }

enum VaultAccess {
    /// Caller authenticates the context for enrolment. Reading the item always enforces its own ACL.
    static func open(_ mode: AccessMode, at root: URL, device: DeviceKeyAccess,
                     context: LAContext, gate: SessionGate) throws -> VaultStore {
        let catalog = root.appendingPathComponent("catalog.v1")
        let existing = FileManager.default.fileExists(atPath: catalog.path)
        switch mode {
        case .unlock: break
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
