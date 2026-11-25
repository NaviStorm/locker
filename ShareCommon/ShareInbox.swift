import CryptoKit
import Foundation

struct ShareInbox {
    static let group = "group.fr.locker.documents.import"
    static let chunkSize = 1_048_576
    let root: URL

    static func local() throws -> Self {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw ShareIssue.group
        }
        var root = groupURL.appendingPathComponent("Incoming-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        return Self(root: root)
    }

    var recipient: URL { root.appendingPathComponent("recipient") }

    func pending() throws -> [UUID] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .compactMap(UUID.init(uuidString:)).sorted { $0.uuidString < $1.uuidString }
    }

    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }

    struct Item: Codable {
        let id: UUID
        let name: String
        let chunks: Int

        func url(in directory: URL, at position: Int) -> URL {
            directory.appendingPathComponent("\(id.uuidString)-\(position)")
        }

        func context(_ position: Int) -> Data { Data("\(id.uuidString)/\(position)".utf8) }
    }

    static func key(_ secret: Curve25519.KeyAgreement.PrivateKey, peer: Data, batch: UUID) throws -> SymmetricKey {
        let shared = try secret.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: peer))
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(batch.uuidString.utf8),
                                               sharedInfo: Data("Locker-share-v1".utf8), outputByteCount: 32)
    }

    struct Writer {
        let inbox: ShareInbox
        let id = UUID()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let key: SymmetricKey
        let staging: URL

        init(_ inbox: ShareInbox) throws {
            self.inbox = inbox
            guard FileManager.default.fileExists(atPath: inbox.recipient.path) else { throw ShareIssue.firstLaunch }
            key = try ShareInbox.key(ephemeral, peer: Data(contentsOf: inbox.recipient), batch: id)
            staging = inbox.root.appendingPathComponent(".pending-" + id.uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        }

        func store(name: String, read: () throws -> Data) throws -> Item {
            let file = Item(id: UUID(), name: name, chunks: 0)
            var position = 0
            while true {
                let data = try read()
                if data.isEmpty { break }
                guard data.count <= ShareInbox.chunkSize else { throw ShareIssue.invalid }
                let sealed = try AES.GCM.seal(data, using: key, authenticating: file.context(position))
                guard let bytes = sealed.combined else { throw ShareIssue.invalid }
                try bytes.write(to: file.url(in: staging, at: position))
                position += 1
            }
            return Item(id: file.id, name: file.name, chunks: position)
        }

        func finish(_ files: [Item]) throws {
            guard !files.isEmpty else { throw ShareIssue.invalid }
            let box = try AES.GCM.seal(JSONEncoder().encode(files), using: key)
            guard let data = box.combined else { throw ShareIssue.invalid }
            try (ephemeral.publicKey.rawRepresentation + data).write(to: staging.appendingPathComponent("manifest"))
            try FileManager.default.moveItem(at: staging, to: inbox.directory(id))
        }
    }

    func open(_ id: UUID, privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> ([Item], SymmetricKey) {
        let bytes = try Data(contentsOf: directory(id).appendingPathComponent("manifest"))
        let key = try Self.key(privateKey, peer: Data(bytes.prefix(32)), batch: id)
        let contents = try AES.GCM.open(.init(combined: bytes.dropFirst(32)), using: key)
        return (try JSONDecoder().decode([Item].self, from: contents), key)
    }
}

enum ShareIssue: LocalizedError {
    case firstLaunch, group, invalid
    var errorDescription: String? {
        switch self {
        case .firstLaunch: return "Ouvrez Locker une première fois sur cet appareil, puis recommencez le partage."
        case .group: return "L’espace de réception de Locker est inaccessible."
        case .invalid: return "Locker n’a pas pu lire ce partage."
        }
    }
}
