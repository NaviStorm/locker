import CryptoKit
import Foundation

struct Labels: Codable, Equatable {
    var name: String
    var folder = ""
    var category = ""
    var notes = ""
}

struct Document: Codable, Equatable {
    var labels: Labels
    let key: Data
    let size: Int64
}

struct Entry: Codable, Equatable {
    let id: UUID
    var generation: UInt64
    var revision: UUID
    var document: Document?

    func wins(over other: Entry) -> Bool {
        if (document == nil) != (other.document == nil) { return document == nil }
        if generation != other.generation { return generation > other.generation }
        return revision.uuidString > other.revision.uuidString
    }
}

struct ListedDocument: Identifiable, Equatable {
    let id: UUID
    let labels: Labels
    let size: Int64
}

actor VaultStore {
    nonisolated let gate: SessionGate
    let root: URL
    let keys: VaultKeys
    private(set) var entries: [UUID: Entry]

    init(root: URL, keys: VaultKeys, create: Bool = false, gate: SessionGate = SessionGate()) throws {
        self.root = root
        self.keys = keys
        self.gate = gate
        let catalog = root.appendingPathComponent("catalog.v1")
        if create {
            guard !FileManager.default.fileExists(atPath: catalog.path) else { throw VaultError.exists }
            try VaultFiles.directory(root)
            let bytes = try Self.pack([UUID: Entry](), keys: keys, purpose: "catalog")
            try VaultFiles.save(bytes, to: catalog)
        }
        entries = try Self.unpack([UUID: Entry].self, data: Data(contentsOf: catalog), keys: keys, purpose: "catalog")
        // A crash can leave encrypted content without a committed catalogue reference.
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.pathExtension == "blob" {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), entries[id]?.document == nil {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    static func pack<T: Encodable>(_ item: T, keys: VaultKeys, purpose: String) throws -> Data {
        let data = try JSONEncoder().encode(item)
        guard let box = try AES.GCM.seal(data, using: keys.key(purpose)).combined else { throw VaultError.damaged }
        return box
    }

    static func unpack<T: Decodable>(_ type: T.Type, data: Data, keys: VaultKeys, purpose: String) throws -> T {
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: keys.key(purpose))
        return try JSONDecoder().decode(type, from: bytes)
    }

    func blob(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".blob") }

    func replace(_ entry: Entry) throws {
        var updated = entries
        updated[entry.id] = entry
        let data = try Self.pack(updated, keys: keys, purpose: "catalog")
        try gate.authorized {
            try VaultFiles.save(data, to: root.appendingPathComponent("catalog.v1"))
            entries = updated
        }
        if entry.document == nil, FileManager.default.fileExists(atPath: blob(entry.id).path) {
            try FileManager.default.removeItem(at: blob(entry.id))
        }
    }

    func list() throws -> [ListedDocument] {
        try gate.check()
        return entries.values.compactMap { entry in
            entry.document.map { ListedDocument(id: entry.id, labels: $0.labels, size: $0.size) }
        }.sorted { $0.labels.name.localizedStandardCompare($1.labels.name) == .orderedAscending }
    }

    @discardableResult
    func importFile(_ url: URL) throws -> UUID {
        try gate.check()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        return try add(name: url.lastPathComponent) { try input.read(upToCount: BlockCipher.chunk) ?? Data() }
    }

    @discardableResult
    func importData(_ data: Data, name: String) throws -> UUID {
        var offset = 0
        return try add(name: name) {
            let end = min(data.count, offset + BlockCipher.chunk)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }

    private func add(name: String, read: () throws -> Data) throws -> UUID {
        let id = UUID()
        let key = SymmetricKey(size: .bits256)
        let url = blob(id)
        let size = try BlockCipher.encrypt(id: id, key: key, to: url, gate: gate, read: read)
        do {
            let document = Document(labels: Labels(name: name), key: key.withUnsafeBytes { Data($0) }, size: size)
            try replace(Entry(id: id, generation: 1, revision: UUID(), document: document))
            return id
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func change(_ id: UUID, labels: Labels?) throws {
        try gate.check()
        guard var entry = entries[id], entry.document != nil else { throw VaultError.unavailable }
        if let labels { entry.document?.labels = labels } else { entry.document = nil }
        entry.generation += 1
        entry.revision = UUID()
        try replace(entry)
    }

    func preview(_ id: UUID, limit: Int = 32 * 1024 * 1024) throws -> Data {
        try gate.check()
        guard let info = entries[id]?.document else { throw VaultError.unavailable }
        guard info.size <= limit else { throw VaultError.tooLarge }
        var data = Data()
        try BlockCipher.decrypt(id: id, info: info, from: blob(id), gate: gate) { data.append($0) }
        return data
    }

    /// The caller supplies a new destination inside an explicitly selected export directory.
    func export(_ id: UUID, to destination: URL) throws {
        try gate.check()
        guard let info = entries[id]?.document else { throw VaultError.unavailable }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        let output = try VaultFiles.newFile(staging)
        defer { try? output.close(); try? FileManager.default.removeItem(at: staging) }
        try BlockCipher.decrypt(id: id, info: info, from: blob(id), gate: gate) { try output.write(contentsOf: $0) }
        try output.synchronize()
        try output.close()
        try gate.authorized {
            // Exclusive rename on Darwin prevents overwriting an existing export.
            guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func recoveryCode() throws -> String { try gate.authorized { keys.recoveryCode } }
}
