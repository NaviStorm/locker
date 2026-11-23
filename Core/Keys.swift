import CryptoKit
import Foundation

enum VaultError: LocalizedError {
    case invalidCode, damaged, locked, unavailable, tooLarge, exists, changed

    var errorDescription: String? {
        switch self {
        case .invalidCode: return "Le code de récupération est invalide."
        case .damaged: return "Le document ou le catalogue n’a pas pu être authentifié."
        case .locked: return "Le coffre est verrouillé."
        case .unavailable: return "La clé ou le document est indisponible."
        case .tooLarge: return "Ce document dépasse la taille admise pour cet aperçu."
        case .exists: return "Un élément existe déjà à cet emplacement."
        case .changed: return "Le coffre a changé pendant l’opération. Réessayez."
        }
    }
}

struct VaultKeys {
    let secret: Data

    init() {
        secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    init(secret: Data) throws {
        guard secret.count == 32 else { throw VaultError.invalidCode }
        self.secret = secret
    }

    init(code: String) throws {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("L1."), let bytes = Data(base64Encoded: String(value.dropFirst(3))),
              bytes.count == 36 else { throw VaultError.invalidCode }
        try self.init(secret: Data(bytes.prefix(32)))
        guard recoveryCode == value else { throw VaultError.invalidCode }
    }

    var recoveryCode: String {
        "L1." + (secret + SHA256.hash(data: secret).prefix(4)).base64EncodedString()
    }

    var identifier: String {
        SHA256.hash(data: Data("Locker-ID-v1".utf8) + secret).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }

    func key(_ purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
            info: Data(("Locker-v1/" + purpose).utf8), outputByteCount: 32)
    }
}
