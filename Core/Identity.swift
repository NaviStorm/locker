import CryptoKit
import Foundation
import Security

struct PublicIdentity: Codable, Equatable {
    let agreement: Data
    let signing: Data

    var fingerprint: String {
        SHA256.hash(data: Data("Locker identity 1".utf8) + agreement + signing)
            .map { String(format: "%02X", $0) }.joined()
    }

    func validate() throws {
        _ = try P256.KeyAgreement.PublicKey(x963Representation: agreement)
        _ = try P256.Signing.PublicKey(x963Representation: signing)
    }

    var card: String { (try? JSONEncoder().encode(self).base64EncodedString()) ?? "" }

    init(card: String) throws {
        guard let data = Data(base64Encoded: card.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw VaultError.invalidCode }
        self = try JSONDecoder().decode(Self.self, from: data)
        try validate()
    }

    init(agreement: Data, signing: Data) { self.agreement = agreement; self.signing = signing }

    func verify(_ signature: Data, bytes: Data) throws {
        let key = try P256.Signing.PublicKey(x963Representation: signing)
        guard try key.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: signature), for: bytes)
        else { throw VaultError.damaged }
    }
}

struct DeviceIdentity: Codable {
    let hardware: Bool
    private let agreement: Data
    private let signing: Data
    let card: PublicIdentity

    init(hardware: Bool = SecureEnclave.isAvailable) throws {
        self.hardware = hardware
        if hardware {
            let a = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            let s = try SecureEnclave.P256.Signing.PrivateKey()
            agreement = a.dataRepresentation
            signing = s.dataRepresentation
            card = PublicIdentity(agreement: a.publicKey.x963Representation, signing: s.publicKey.x963Representation)
        } else {
            let a = P256.KeyAgreement.PrivateKey()
            let s = P256.Signing.PrivateKey()
            agreement = a.rawRepresentation
            signing = s.rawRepresentation
            card = PublicIdentity(agreement: a.publicKey.x963Representation, signing: s.publicKey.x963Representation)
        }
    }

    /// The rescue identity can be reconstructed only with the owner's high-entropy offline secret.
    init(rescue keys: VaultKeys) throws {
        hardware = false
        func scalar(_ label: String) -> Data {
            var counter = 0
            while true {
                let candidate = keys.key("rescue/" + label + "/" + String(counter)).withUnsafeBytes { Data($0) }
                if (try? P256.Signing.PrivateKey(rawRepresentation: candidate)) != nil { return candidate }
                counter += 1
            }
        }
        agreement = scalar("agreement")
        signing = scalar("signing")
        card = try PublicIdentity(agreement: P256.KeyAgreement.PrivateKey(rawRepresentation: agreement).publicKey.x963Representation,
                                  signing: P256.Signing.PrivateKey(rawRepresentation: signing).publicKey.x963Representation)
    }

    func sign(_ data: Data) throws -> Data {
        if hardware { return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: signing).signature(for: data).rawRepresentation }
        return try P256.Signing.PrivateKey(rawRepresentation: signing).signature(for: data).rawRepresentation
    }

    func decrypt(_ envelope: SealedGrant) throws -> Data {
        let info = Data("Locker-grant-v1".utf8) + Data(card.fingerprint.utf8)
        var recipient: HPKE.Recipient
        if hardware {
            recipient = try HPKE.Recipient(privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: agreement),
                ciphersuite: .P256_SHA256_AES_GCM_256, info: info, encapsulatedKey: envelope.encapsulation)
        } else {
            recipient = try HPKE.Recipient(privateKey: P256.KeyAgreement.PrivateKey(rawRepresentation: agreement),
                ciphersuite: .P256_SHA256_AES_GCM_256, info: info, encapsulatedKey: envelope.encapsulation)
        }
        return try recipient.open(envelope.ciphertext)
    }
}

struct SealedGrant: Codable {
    let encapsulation: Data
    let ciphertext: Data
    init(_ bytes: Data, for card: PublicIdentity) throws {
        try card.validate()
        var sender = try HPKE.Sender(recipientKey: P256.KeyAgreement.PublicKey(x963Representation: card.agreement),
            ciphersuite: .P256_SHA256_AES_GCM_256, info: Data("Locker-grant-v1".utf8) + Data(card.fingerprint.utf8))
        encapsulation = sender.encapsulatedKey
        ciphertext = try sender.seal(bytes)
    }
}

/// RFC 7515 flattened JWS serialization, with a protected application type and ES256.
struct SignedObject: Codable {
    private struct Header: Codable {
        let alg: String
        let typ: String
    }
    private enum CodingKeys: String, CodingKey { case protected, payload, signature }
    let bytes: Data
    private let protected: String
    private let signature: Data

    private static func encode64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decode64(_ string: String) throws -> Data {
        var base = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base), encode64(data) == string else { throw VaultError.damaged }
        return data
    }

    private static func input(_ header: String, bytes: Data) -> Data {
        Data((header + "." + encode64(bytes)).utf8)
    }

    init<T: Encodable>(_ payload: T, by identity: DeviceIdentity, domain: String) throws {
        bytes = try JSONEncoder().encode(payload)
        protected = try Self.encode64(JSONEncoder().encode(Header(alg: "ES256", typ: domain)))
        signature = try identity.sign(Self.input(protected, bytes: bytes))
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protected = try values.decode(String.self, forKey: .protected)
        bytes = try Self.decode64(values.decode(String.self, forKey: .payload))
        signature = try Self.decode64(values.decode(String.self, forKey: .signature))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protected, forKey: .protected)
        try values.encode(Self.encode64(bytes), forKey: .payload)
        try values.encode(Self.encode64(signature), forKey: .signature)
    }

    func verified<T: Decodable>(_ type: T.Type, by card: PublicIdentity, domain: String) throws -> T {
        let rawHeader = try Self.decode64(protected)
        guard let fields = try JSONSerialization.jsonObject(with: rawHeader) as? [String: String],
              Set(fields.keys) == ["alg", "typ"] else { throw VaultError.damaged }
        let header = try JSONDecoder().decode(Header.self, from: rawHeader)
        guard header.alg == "ES256", header.typ == domain, signature.count == 64 else { throw VaultError.damaged }
        try card.verify(signature, bytes: Self.input(protected, bytes: bytes))
        return try JSONDecoder().decode(type, from: bytes)
    }
}

extension VaultStore {
    func identity() throws -> DeviceIdentity {
        try gate.check()
        if let family {
            let rescue = try DeviceIdentity(rescue: keys)
            if family.principal == rescue.card.fingerprint { return rescue }
        }
        let cred = ProviderCredential(account: "identity-" + root.lastPathComponent + "-" + keys.identifier)
        do { return try Self.unpack(DeviceIdentity.self, data: cred.read(), keys: keys, purpose: "identity") }
        catch let error as KeychainFailure where error.status == errSecItemNotFound {
            let device = try DeviceIdentity()
            try cred.save(Self.pack(device, keys: keys, purpose: "identity"))
            return device
        }
    }

    func publicIdentity() throws -> PublicIdentity { try identity().card }

    func inviteOwnDevice(card: PublicIdentity) throws -> String {
        guard family == nil else { throw FamilyError.denied }
        let grant = try SealedGrant(keys.secret, for: card)
        let signed = try SignedObject(grant, by: identity(), domain: "Locker-owner-device-1")
        return try JSONEncoder().encode(signed).base64EncodedString()
    }

    func acceptOwnDevice(_ ticket: String, from card: PublicIdentity) throws -> String {
        guard let data = Data(base64Encoded: ticket.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw VaultError.invalidCode }
        let signed = try JSONDecoder().decode(SignedObject.self, from: data)
        let grant = try signed.verified(SealedGrant.self, by: card, domain: "Locker-owner-device-1")
        return try VaultKeys(secret: identity().decrypt(grant)).recoveryCode
    }
}
