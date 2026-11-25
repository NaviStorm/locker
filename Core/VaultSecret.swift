import CommonCrypto
import CryptoKit
import Foundation

enum VaultSecretError: LocalizedError {
    case invalidPIN, weakPassword, mismatch, incorrect
    var errorDescription: String? {
        switch self {
        case .invalidPIN: return "Le code personnel doit contenir au moins 10 chiffres de 0 à 9."
        case .weakPassword: return "Choisissez au moins 12 caractères avec une majuscule, une minuscule, un chiffre et un symbole. Évitez les mots de passe courants et les répétitions."
        case .mismatch: return "Les deux saisies ne correspondent pas."
        case .incorrect: return "Le code personnel ou le mot de passe du coffre est incorrect."
        }
    }
}

extension VaultAuthenticationMethod {
    var isCustom: Bool { self == .numericCode || self == .vaultPassword }
    var secretTitle: String { self == .numericCode ? "Code numérique du coffre" : "Mot de passe du coffre" }

    func validateNewSecret(_ value: String) throws {
        switch self {
        case .numericCode:
            guard value.utf8.count >= 10, value.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw VaultSecretError.invalidPIN
            }
        case .vaultPassword:
            let chars = value.unicodeScalars
            let stem = value.lowercased().filter(\.isLetter)
            guard value.count >= 12, Set(value).count >= 6,
                  !(value + value).dropFirst().dropLast().contains(value),
                  chars.contains(where: CharacterSet.uppercaseLetters.contains),
                  chars.contains(where: CharacterSet.lowercaseLetters.contains),
                  chars.contains(where: CharacterSet.decimalDigits.contains),
                  chars.contains(where: CharacterSet.symbols.union(.punctuationCharacters).contains),
                  !["password", "passwrd", "motdepasse", "azerty", "azertyuiop", "qwerty", "qwertyuiop", "abcdef", "letmein", "administrator"].contains(stem)
            else { throw VaultSecretError.weakPassword }
        default: throw VaultError.unavailable
        }
    }
}

// Version 1 fixes the KDF parameters. Only the salted, authenticated envelope is stored in the Keychain.
struct WrappedVaultKey: Codable {
    let version: Int
    let method: VaultAuthenticationMethod
    let salt: Data
    let sealed: Data

    private static func derive(_ secret: String, salt: Data) throws -> SymmetricKey {
        let password = Array(secret.precomposedStringWithCanonicalMapping.utf8)
        guard !password.isEmpty, salt.count == 16 else { throw VaultSecretError.incorrect }
        var output = [UInt8](repeating: 0, count: 32)
        let result = password.withUnsafeBytes { input in
            salt.withUnsafeBytes { bytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.bindMemory(to: Int8.self).baseAddress,
                    input.count, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &output, 32)
            }
        }
        guard result == kCCSuccess else { throw VaultError.unavailable }
        return SymmetricKey(data: output)
    }

    private static func context(_ account: String, _ method: VaultAuthenticationMethod) -> Data {
        Data(("Locker-local-key-v1/" + account + "/" + method.rawValue).utf8)
    }

    static func make(keys: VaultKeys, secret: String, method: VaultAuthenticationMethod, account: String) throws -> Data {
        try method.validateNewSecret(secret)
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let key = try derive(secret, salt: salt)
        let box = try AES.GCM.seal(keys.secret, using: key, authenticating: context(account, method))
        guard let sealed = box.combined else { throw VaultError.damaged }
        return try JSONEncoder().encode(Self(version: 1, method: method, salt: salt, sealed: sealed))
    }

    func open(secret: String, account: String) throws -> VaultKeys {
        guard version == 1, method.isCustom, salt.count == 16, sealed.count == 60 else { throw VaultError.damaged }
        let key = try Self.derive(secret, salt: salt)
        do {
            let clear = try AES.GCM.open(.init(combined: sealed), using: key, authenticating: Self.context(account, method))
            return try VaultKeys(secret: clear)
        } catch { throw VaultSecretError.incorrect }
    }
}
