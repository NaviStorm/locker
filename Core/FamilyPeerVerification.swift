import Foundation

struct FamilyPeerVerification: Codable, Equatable {
    var card = "" {
        didSet {
            if card != oldValue { confirmedFingerprint = nil }
        }
    }
    private var confirmedFingerprint: String?
    var peer: PublicIdentity? { try? PublicIdentity(card: card) }

    var isConfirmed: Bool {
        get { confirmedFingerprint != nil && confirmedFingerprint == peer?.fingerprint }
        set { confirmedFingerprint = newValue ? peer?.fingerprint : nil }
    }
}

extension VaultStore {
    // This small local record is committed before the edit returns, including just before locking.
    nonisolated func familyPeerVerification() throws -> FamilyPeerVerification {
        try gate.authorized {
            let url = root.appendingPathComponent("family-peer.v1")
            do {
                let bytes = try Data(contentsOf: url)
                return try Self.unpack(FamilyPeerVerification.self, data: bytes, keys: keys, purpose: "family-peer")
            } catch CocoaError.fileReadNoSuchFile {
                return FamilyPeerVerification()
            }
        }
    }

    nonisolated func saveFamilyPeerVerification(_ verification: FamilyPeerVerification) throws {
        try gate.authorized {
            let bytes = try Self.pack(verification, keys: keys, purpose: "family-peer")
            try VaultFiles.save(bytes, to: root.appendingPathComponent("family-peer.v1"))
        }
    }
}
