import LocalAuthentication
import Security

enum VaultAuthenticationMethod: String {
    case passcode
    case biometrics

    static func preferred(for slot: String, defaults: UserDefaults = .standard) -> Self {
        if let value = defaults.string(forKey: "authenticationMethod." + slot),
           let saved = Self(rawValue: value) { return saved }
        return .passcode
    }

    func remember(for slot: String, defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "authenticationMethod." + slot)
    }

    func confirm(using context: LAContext, reason: String) async throws {
        let confirmed: Bool
        switch self {
        case .biometrics:
            context.localizedFallbackTitle = ""
            confirmed = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        case .passcode:
            var error: Unmanaged<CFError>?
            guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                                .devicePasscode, &error) else {
                throw error?.takeRetainedValue() as Error? ?? VaultError.unavailable
            }
            confirmed = try await context.evaluateAccessControl(control, operation: .useItem, localizedReason: reason)
        }
        guard confirmed else { throw VaultError.locked }
        // Reuse this proof for the Keychain item. Never present a second, system-selected method.
        context.interactionNotAllowed = true
    }
}
