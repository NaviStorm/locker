import CryptoKit
import Foundation

enum FamilyRole: String, Codable, CaseIterable {
    case reader = "Lecture", contributor = "Ajout", editor = "Modification", admin = "Administration"
}

struct Member: Codable {
    let card: PublicIdentity
    let role: FamilyRole
    let documents: Set<UUID>?
    func covers(_ id: UUID) -> Bool { documents?.contains(id) ?? true }
}

struct Policy: Codable {
    let vault: UUID
    let epoch: UInt64
    let parent: String?
    let author: String
    let members: [Member]
    let grants: [String: SealedGrant]

    func member(_ fingerprint: String) -> Member? { members.first { $0.card.fingerprint == fingerprint } }

    static func issue(_ members: [Member], prior: PolicyCertificate?, by identity: DeviceIdentity) throws -> PolicyCertificate {
        let old = try prior?.decoded()
        guard old?.epoch != UInt64.max else { throw FamilyError.policy }
        if let old { guard old.member(identity.card.fingerprint)?.role == .admin else { throw FamilyError.denied } }
        guard members.contains(where: { $0.role == .admin && $0.documents == nil }),
              Set(members.map(\.card.fingerprint)).count == members.count else { throw FamilyError.policy }
        let epochKey = VaultKeys().secret
        var grants = [String: SealedGrant]()
        for member in members {
            try member.card.validate()
            guard member.role != .admin || member.documents == nil else { throw FamilyError.policy }
            if member.documents == nil { grants[member.card.fingerprint] = try SealedGrant(epochKey, for: member.card) }
        }
        let policy = Policy(vault: old?.vault ?? UUID(), epoch: (old?.epoch ?? 0) + 1, parent: prior?.digest,
                            author: identity.card.fingerprint, members: members, grants: grants)
        return try PolicyCertificate(signed: SignedObject(policy, by: identity, domain: "Locker-family-policy-1"))
    }
}

enum FamilyError: LocalizedError {
    case denied, policy, stale, scope, nonempty, fork
    var errorDescription: String? {
        switch self {
        case .denied: return "Cette identité ne dispose pas de cette autorisation."
        case .policy: return "La politique du coffre familial est invalide."
        case .stale: return "La politique distante est antérieure au dernier état approuvé."
        case .scope: return "Ce document est hors du périmètre autorisé."
        case .nonempty: return "Utilisez un coffre local vide pour créer ou rejoindre une famille."
        case .fork: return "Deux politiques concurrentes ont été détectées. Les échanges sont suspendus."
        }
    }
}

struct PolicyCertificate: Codable {
    let signed: SignedObject
    var digest: String { SHA256.hash(data: signed.bytes).map { String(format: "%02x", $0) }.joined() }
    func decoded() throws -> Policy { try JSONDecoder().decode(Policy.self, from: signed.bytes) }
    func verify(after prior: PolicyCertificate) throws {
        let old = try prior.decoded()
        let next = try decoded()
        guard old.vault == next.vault, old.epoch < UInt64.max, next.epoch == old.epoch + 1,
              next.parent == prior.digest, let admin = old.member(next.author), admin.role == .admin else {
            throw FamilyError.policy
        }
        _ = try signed.verified(Policy.self, by: admin.card, domain: "Locker-family-policy-1")
        guard Set(next.members.map(\.card.fingerprint)).count == next.members.count,
              next.members.contains(where: { $0.role == .admin && $0.documents == nil }),
              next.members.allSatisfy({ $0.role != .admin || $0.documents == nil }) else { throw FamilyError.policy }
    }
}

struct TransportContact: Codable, Equatable {
    let email: String
    var cloudRecordName: String? = nil
    let destination: String
}

struct FamilyLocal: Codable {
    var tip: PolicyCertificate
    var waiting: [PolicyCertificate]
    var seen: Set<String>
    var principal: String
    var cloudURL: URL?
    var contacts: [String: TransportContact]?
    var removals: [TransportContact]?
    var permissionUpdates: [String: UUID]?
    var deviceNames: [String: String]?
    var history: [PolicyCertificate]?
    var destination: String?
    var bootstrap: Bool?
    var joinedByInvitation: Bool?

    func displayName(for fingerprint: String) -> String? {
        if let name = deviceNames?[fingerprint] { return name }
        if let email = contacts?[fingerprint]?.email, !email.isEmpty { return email }
        return nil
    }

    var recoveryFingerprint: String? {
        guard let initial = try? (history?.first ?? tip).decoded(), initial.parent == nil else { return nil }
        return initial.members.first { $0.card.fingerprint != initial.author }?.card.fingerprint
    }

    mutating func trackPermissionChanges(from old: Policy, to new: Policy) {
        guard let contacts else { return }
        for fingerprint in contacts.keys {
            guard let member = new.member(fingerprint) else {
                permissionUpdates?.removeValue(forKey: fingerprint)
                continue
            }
            if let previous = old.member(fingerprint), (previous.role == .reader) != (member.role == .reader) {
                if permissionUpdates == nil { permissionUpdates = [:] }
                permissionUpdates?[fingerprint] = UUID()
            }
        }
    }
}

struct FamilyJoinDraft: Codable, Equatable {
    var ticket = ""
    var card = "" {
        didSet { if card != oldValue { verifiedFingerprint = nil } }
    }
    private(set) var verifiedFingerprint: String?
    var owner: PublicIdentity? { try? PublicIdentity(card: card) }

    var fingerprintConfirmed: Bool {
        get { verifiedFingerprint != nil && verifiedFingerprint == owner?.fingerprint }
        set { verifiedFingerprint = newValue ? owner?.fingerprint : nil }
    }

    mutating func pasteInvitation(_ text: String) {
        ticket = text
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let message = try? JSONDecoder().decode(FamilyInvitationMessage.self, from: data),
              (try? message.sender.validate()) != nil,
              (try? message.signed.verified(SealedGrant.self, by: message.sender, domain: "Locker-family-invite-1")) != nil
        else { return }
        if owner != message.sender { card = message.sender.card }
    }

    var nextStep: String? {
        let text = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Collez le message reçu après avoir envoyé votre carte au propriétaire." }
        guard let bytes = Data(base64Encoded: text), (try? JSONDecoder().decode(SignedObject.self, from: bytes)) != nil
        else { return "L’invitation est illisible. Recopiez le texte complet de l’invitation chiffrée." }
        if card.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Collez aussi la carte publique du propriétaire." }
        guard owner != nil else { return "La carte publique est illisible. Demandez au propriétaire de vous renvoyer sa carte." }
        return fingerprintConfirmed ? nil : "Comparez l’empreinte avec le propriétaire, de vive voix, puis cochez la confirmation."
    }
}

// Keep the signed envelope readable by older versions of Locker.
private struct FamilyInvitationMessage: Codable {
    enum CodingKeys: String, CodingKey { case sender }
    let sender: PublicIdentity
    let signed: SignedObject

    init(sender: PublicIdentity, signed: SignedObject) {
        self.sender = sender
        self.signed = signed
    }

    init(from decoder: Decoder) throws {
        sender = try decoder.container(keyedBy: CodingKeys.self).decode(PublicIdentity.self, forKey: .sender)
        signed = try SignedObject(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try signed.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sender, forKey: .sender)
    }
}

struct FamilyInvitation: Codable {
    let tip: PolicyCertificate
    let cloudURL: URL?
    let target: String

    static func make(state: FamilyLocal, for recipient: PublicIdentity, by admin: DeviceIdentity) throws -> String {
        let policy = try state.tip.decoded()
        guard policy.member(admin.card.fingerprint)?.role == .admin,
              policy.member(recipient.fingerprint) != nil else { throw FamilyError.denied }
        let invitation = FamilyInvitation(tip: state.tip, cloudURL: state.cloudURL, target: recipient.fingerprint)
        let grant = try SealedGrant(JSONEncoder().encode(invitation), for: recipient)
        let signed = try SignedObject(grant, by: admin, domain: "Locker-family-invite-1")
        return try JSONEncoder().encode(FamilyInvitationMessage(sender: admin.card, signed: signed)).base64EncodedString()
    }

    static func open(_ ticket: String, by identity: DeviceIdentity, trustedAdmin: PublicIdentity) throws -> FamilyLocal {
        guard let data = Data(base64Encoded: ticket.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw VaultError.invalidCode }
        let signed = try JSONDecoder().decode(SignedObject.self, from: data)
        let grant = try signed.verified(SealedGrant.self, by: trustedAdmin, domain: "Locker-family-invite-1")
        let invitation = try JSONDecoder().decode(Self.self, from: identity.decrypt(grant))
        let policy = try invitation.tip.decoded()
        guard invitation.target == identity.card.fingerprint, policy.member(invitation.target) != nil,
              policy.member(trustedAdmin.fingerprint)?.role == .admin else { throw FamilyError.denied }
        return FamilyLocal(tip: invitation.tip, waiting: [], seen: [], principal: invitation.target, cloudURL: invitation.cloudURL, joinedByInvitation: true)
    }
}

enum FamilyAction: String, Codable { case add, edit, delete }

struct FamilyBody: Codable {
    let entry: Entry
    let chunks: [String]
}

struct FamilyEvent: Codable {
    let policy: String
    let author: String
    let document: UUID
    let scope: UUID
    let action: FamilyAction
    let ciphertext: Data
    let fullGrant: Data
    let specificGrants: [String: SealedGrant]

    static func authorize(_ member: Member, action: FamilyAction, scope: UUID) throws {
        guard member.covers(scope) else { throw FamilyError.scope }
        switch member.role {
        case .admin, .editor: break
        case .contributor: guard action == .add else { throw FamilyError.denied }
        case .reader: throw FamilyError.denied
        }
    }

    static func make(body: FamilyBody, scope: UUID, action: FamilyAction, state: FamilyLocal, by identity: DeviceIdentity) throws -> SignedObject {
        let policy = try state.tip.decoded()
        guard let author = policy.member(identity.card.fingerprint) else { throw FamilyError.denied }
        try authorize(author, action: action, scope: scope)
        let eventKey = VaultKeys()
        let bytes = try VaultStore.pack(body, keys: eventKey, purpose: "family-body")
        // A scoped writer can encrypt to full members using their public cards without learning the epoch key.
        var grants = [String: SealedGrant]()
        let full: Data
        if let grant = policy.grants[identity.card.fingerprint] {
            let epoch = try VaultKeys(secret: identity.decrypt(grant))
            full = try VaultStore.pack(eventKey.secret, keys: epoch, purpose: "family-entry")
        } else { full = Data() }
        for member in policy.members where member.covers(scope) && (full.isEmpty || member.documents != nil) {
            grants[member.card.fingerprint] = try SealedGrant(eventKey.secret, for: member.card)
        }
        let event = FamilyEvent(policy: state.tip.digest, author: identity.card.fingerprint, document: body.entry.id,
                                scope: scope, action: action, ciphertext: bytes, fullGrant: full, specificGrants: grants)
        return try SignedObject(event, by: identity, domain: "Locker-family-event-1")
    }

    static func read(_ signed: SignedObject, state: FamilyLocal, by identity: DeviceIdentity) throws -> (Self, FamilyBody?) {
        let routing = try JSONDecoder().decode(Self.self, from: signed.bytes)
        let policy = try state.tip.decoded()
        guard routing.policy == state.tip.digest, let author = policy.member(routing.author),
              let reader = policy.member(identity.card.fingerprint) else { throw FamilyError.denied }
        let event = try signed.verified(Self.self, by: author.card, domain: "Locker-family-event-1")
        try authorize(author, action: event.action, scope: event.scope)
        guard reader.covers(event.scope) else { return (event, nil) }
        let raw: Data
        if let grant = event.specificGrants[identity.card.fingerprint] { raw = try identity.decrypt(grant) }
        else {
            guard let grant = policy.grants[identity.card.fingerprint] else { throw FamilyError.denied }
            raw = try VaultStore.unpack(Data.self, data: event.fullGrant, keys: VaultKeys(secret: identity.decrypt(grant)),
                                       purpose: "family-entry")
        }
        let body = try VaultStore.unpack(FamilyBody.self, data: event.ciphertext, keys: VaultKeys(secret: raw), purpose: "family-body")
        guard body.entry.id == event.document, (body.entry.document == nil) == (event.action == .delete),
              body.entry.document.map({ ($0.lineage ?? body.entry.id) == event.scope }) ?? true else { throw FamilyError.policy }
        let birthAuthor = body.entry.document?.originAuthor ?? body.entry.tombstoneAuthor
        let nonce = body.entry.document?.originNonce ?? body.entry.tombstoneNonce
        if event.scope != event.document {
            guard let birthAuthor, let nonce,
                  scopedID(author: birthAuthor, nonce: nonce, lineage: event.scope) == event.document else { throw FamilyError.scope }
        }
        if author.role == .contributor {
            guard let info = body.entry.document, let nonce = info.originNonce, body.entry.generation == 1,
                  birthAuthor == author.card.fingerprint,
                  body.entry.id == scopedID(author: author.card.fingerprint, nonce: nonce, lineage: event.scope == event.document ? nil : event.scope) else { throw FamilyError.denied }
        }
        return (event, body)
    }

    static func scopedID(author: String, nonce: UUID, lineage: UUID? = nil) -> UUID {
        let digest = SHA256.hash(data: Data((author + nonce.uuidString + (lineage?.uuidString ?? "")).utf8))
        return UUID(uuid: digest.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
    }
}
