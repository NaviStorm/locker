import CryptoKit
import Foundation

enum NearbyRole: String, Identifiable {
    case owner, guest
    var id: Self { self }
}

/// The owner commits before seeing the guest's random challenge. The displayed code binds
/// both ephemeral challenges, the Locker keys and the guest's CloudKit account.
struct NearbyHandshake {
    struct Hello: Codable {
        let card: PublicIdentity
        let nonce: Data
        let accountDigest: Data

        var digest: Data {
            Data(SHA256.hash(data: Data(card.fingerprint.utf8) + nonce + accountDigest))
        }
    }

    enum Packet: Codable {
        case commitment(Data), hello(Hello), confirm(String), ticket(String), joined
    }

    let role: NearbyRole
    let local: Hello
    let account: String
    private(set) var peer: Hello?
    private var commitment: Data?
    private(set) var confirmedHere = false
    private(set) var confirmedThere = false
    private(set) var guestAccount: String?

    init(role: NearbyRole, card: PublicIdentity, account: String) {
        self.role = role
        self.account = account
        let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        local = Hello(card: card, nonce: nonce, accountDigest: Self.accountDigest(account, nonce))
    }

    private static func accountDigest(_ name: String, _ nonce: Data) -> Data {
        Data(SHA256.hash(data: nonce + Data(name.utf8)))
    }

    var code: String? {
        guard let peer else { return nil }
        let owner = role == .owner ? local : peer
        let guest = role == .guest ? local : peer
        let ordered = owner.nonce + owner.digest + guest.nonce + guest.digest
        let digest = SHA256.hash(data: Data("Locker-nearby-1".utf8) + ordered)
        let number = digest.prefix(4).reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", number % 1_000_000)
    }

    var ready: Bool { confirmedHere && confirmedThere }

    mutating func confirm() throws -> Packet {
        guard code != nil, !confirmedHere else { throw FamilyError.policy }
        confirmedHere = true
        return .confirm(role == .guest ? account : "")
    }

    mutating func receive(_ packet: Packet) throws -> Packet? {
        switch packet {
        case let .commitment(hash):
            guard role == .guest, commitment == nil, hash.count == 32 else { throw FamilyError.policy }
            commitment = hash
            return .hello(local)
        case let .hello(value):
            guard peer == nil, value.nonce.count == 32, value.accountDigest.count == 32,
                  value.card != local.card else { throw FamilyError.policy }
            try value.card.validate()
            if role == .guest && commitment != value.digest { throw FamilyError.policy }
            peer = value
            return role == .owner ? .hello(local) : nil
        case let .confirm(name):
            guard let peer, !confirmedThere else { throw FamilyError.policy }
            if role == .owner {
                guard !name.isEmpty, name.utf8.count <= 512,
                      Self.accountDigest(name, peer.nonce) == peer.accountDigest else { throw FamilyError.policy }
                guestAccount = name
            } else if !name.isEmpty { throw FamilyError.policy }
            confirmedThere = true
            return nil
        case .ticket, .joined: throw FamilyError.policy
        }
    }
}
