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
    var originAuthor: String?
    var originNonce: UUID?
    var lineage: UUID?
    var parent: UUID?
    var created: Date?
    var previousLabels: [UUID: Labels]?
    var isFolder: Bool?
}

struct Entry: Codable, Equatable {
    let id: UUID
    var generation: UInt64
    var revision: UUID
    var document: Document?
    var tombstoneScope: UUID?
    var tombstoneAuthor: String?
    var tombstoneNonce: UUID?
    var scope: UUID { document?.lineage ?? tombstoneScope ?? id }

    func mergingLabels(from other: Entry) -> Entry {
        guard document != nil, let old = other.document else { return self }
        var merged = self
        var history = document?.previousLabels ?? [:]
        history.merge(old.previousLabels ?? [:]) { current, _ in current }
        if revision != other.revision { history[other.revision] = old.labels }
        history.removeValue(forKey: revision)
        merged.document?.previousLabels = history.isEmpty ? nil : history
        return merged
    }

    func wins(over other: Entry) -> Bool {
        if (document == nil) != (other.document == nil) { return document == nil }
        if generation != other.generation { return generation > other.generation }
        return revision.uuidString > other.revision.uuidString
    }
}

struct ListedDocument: Identifiable, Equatable {
    let lineage: UUID
    let created: Date?
    let id: UUID
    let labels: Labels
    let size: Int64
}

struct VaultLibrary {
    var documents: [ListedDocument] = []
    var folders: [String] = []

    func documents(in folder: String) -> [ListedDocument] {
        documents.filter { $0.labels.folder == folder }
    }
}

struct Catalog: Codable {
    var entries: [UUID: Entry]
    var pending: [UUID: UUID]
    var family: FamilyLocal?
}

actor VaultStore {
    nonisolated let gate: SessionGate
    let root: URL
    let keys: VaultKeys
    private(set) var entries: [UUID: Entry]
    private(set) var pending: [UUID: UUID]
    private(set) var family: FamilyLocal?

    init(root: URL, keys: VaultKeys, create: Bool = false, gate: SessionGate = SessionGate()) throws {
        self.root = root
        self.keys = keys
        self.gate = gate
        let catalog = root.appendingPathComponent("catalog.v1")
        if create {
            guard !FileManager.default.fileExists(atPath: catalog.path) else { throw VaultError.exists }
            try VaultFiles.directory(root)
            let bytes = try Self.pack(Catalog(entries: [:], pending: [:]), keys: keys, purpose: "catalog")
            try VaultFiles.save(bytes, to: catalog)
        }
        var vaultDirectory = root
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try vaultDirectory.setResourceValues(attributes)
        let state = try Self.readCatalog(catalog, keys: keys)
        entries = state.entries
        pending = state.pending
        family = state.family
        // A crash can leave encrypted content without a committed catalogue reference.
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.pathExtension == "blob" {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), entries[id]?.document == nil {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    static func readCatalog(_ url: URL, keys: VaultKeys) throws -> Catalog {
        let bytes = try Data(contentsOf: url)
        do { return try unpack(Catalog.self, data: bytes, keys: keys, purpose: "catalog") }
        catch is DecodingError {
            let old = try unpack([UUID: Entry].self, data: bytes, keys: keys, purpose: "catalog")
            return Catalog(entries: old, pending: old.mapValues(\.revision))
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

    func acknowledge(_ id: UUID, revision: UUID?) throws {
        guard let revision, pending[id] == revision else { return }
        var queue = pending
        queue.removeValue(forKey: id)
        try commit(entries, queue)
    }

    func commit(_ updated: [UUID: Entry], _ queue: [UUID: UUID], family newFamily: FamilyLocal? = nil) throws {
        let data = try Self.pack(Catalog(entries: updated, pending: queue, family: newFamily ?? family), keys: keys, purpose: "catalog")
        try gate.authorized {
            try VaultFiles.save(data, to: root.appendingPathComponent("catalog.v1"))
            family = newFamily ?? family
            entries = updated
            pending = queue
        }
    }

    func replace(_ entry: Entry, enqueue: Bool = true) throws {
        var updated = entries
        updated[entry.id] = entry
        var queue = pending
        queue[entry.id] = enqueue ? entry.revision : nil
        try commit(updated, queue)
        if entry.document == nil, FileManager.default.fileExists(atPath: blob(entry.id).path) {
            try FileManager.default.removeItem(at: blob(entry.id))
        }
    }

    func list() throws -> [ListedDocument] {
        try library().documents
    }

    func library() throws -> VaultLibrary {
        try gate.check()
        var folders = Set<String>()
        var documents = [ListedDocument]()
        for entry in entries.values {
            guard let document = entry.document else { continue }
            if document.isFolder == true {
                folders.insert(document.labels.name)
            } else {
                if !document.labels.folder.isEmpty { folders.insert(document.labels.folder) }
                documents.append(ListedDocument(lineage: entry.scope, created: document.created, id: entry.id,
                                                labels: document.labels, size: document.size))
            }
        }
        return VaultLibrary(documents: documents.sorted { $0.labels.name.localizedStandardCompare($1.labels.name) == .orderedAscending },
                            folders: folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    func createFolder(_ proposed: String) throws -> String {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TransportError(message: "Saisissez un nom de dossier.") }
        guard try !library().folders.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw TransportError(message: "Un dossier porte déjà ce nom.")
        }
        _ = try add(name: name, isFolder: true) { Data() }
        return name
    }

    @discardableResult
    func importFile(_ url: URL, versionOf parent: UUID? = nil, folder: String = "") throws -> UUID {
        try gate.check()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        return try add(name: url.lastPathComponent, parent: parent, folder: folder) { try input.read(upToCount: BlockCipher.chunk) ?? Data() }
    }

    @discardableResult
    func importData(_ data: Data, name: String, folder: String = "") throws -> UUID {
        var offset = 0
        return try add(name: name, folder: folder) {
            let end = min(data.count, offset + BlockCipher.chunk)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }

    private func add(name: String, parent: UUID? = nil, folder: String = "", isFolder: Bool? = nil, read: () throws -> Data) throws -> UUID {
        let entry = try stageDocument(name: name, parent: parent, folder: folder, isFolder: isFolder, read: read)
        do { try replace(entry) }
        catch { try? FileManager.default.removeItem(at: blob(entry.id)); throw error }
        return entry.id
    }

    // The caller publishes the encrypted blob with a catalogue commit, or discards it.
    func stageDocument(name: String, parent: UUID? = nil, folder: String, isFolder: Bool? = nil,
                       read: () throws -> Data) throws -> Entry {
        let original = parent.flatMap { entries[$0]?.document }
        if parent != nil && (original == nil || original?.isFolder == true) { throw VaultError.unavailable }
        let nonce = UUID()
        let parentScope = parent.flatMap { entries[$0]?.scope }
        let id = family.map { FamilyEvent.scopedID(author: $0.principal, nonce: nonce, lineage: parentScope) } ?? UUID()
        let scope = parentScope ?? id
        try authorizeLocal(.add, scope: scope)
        let key = SymmetricKey(size: .bits256)
        let url = blob(id)
        let size = try BlockCipher.encrypt(id: id, key: key, to: url, gate: gate, read: read)
        let document = Document(labels: Labels(name: name, folder: original?.labels.folder ?? folder),
                                key: key.withUnsafeBytes { Data($0) }, size: size, originAuthor: family?.principal,
                                originNonce: nonce, lineage: scope, parent: parent, created: Date(), isFolder: isFolder)
        return Entry(id: id, generation: 1, revision: UUID(), document: document)
    }

    private func labelsForDocument(_ id: UUID) throws -> Labels {
        try gate.check()
        guard let document = entries[id]?.document, document.isFolder != true else { throw VaultError.unavailable }
        return document.labels
    }

    func renameDocument(_ id: UUID, to proposed: String) throws {
        var labels = try labelsForDocument(id)
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw TransportError(message: "Saisissez un nom de fichier valide.")
        }
        guard name != labels.name else { return }
        labels.name = name
        try change(id, labels: labels)
    }

    func moveDocument(_ id: UUID, to folder: String) throws {
        var labels = try labelsForDocument(id)
        guard folder != labels.folder else { return }
        if !folder.isEmpty, try !library().folders.contains(folder) {
            throw TransportError(message: "Ce dossier n’existe plus dans le coffre.")
        }
        labels.folder = folder
        try change(id, labels: labels)
    }

    func change(_ id: UUID, labels: Labels?) throws {
        try gate.check()
        guard var entry = entries[id], entry.document != nil else { throw VaultError.unavailable }
        try authorizeLocal(labels == nil ? .delete : .edit, scope: entry.scope)
        if let labels, var document = entry.document {
            var previous = document.previousLabels ?? [:]
            previous[entry.revision] = document.labels
            document.previousLabels = previous
            document.labels = labels
            entry.document = document
        } else {
            entry.tombstoneScope = entry.scope
            entry.tombstoneAuthor = entry.document?.originAuthor
            entry.tombstoneNonce = entry.document?.originNonce
            entry.document = nil
        }
        guard entry.generation < UInt64.max else { throw VaultError.damaged }
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
        let source = blob(id)
        try BlockCipher.decrypt(id: id, info: info, from: source, gate: gate) { _ in }
        let output = try gate.authorized { try VaultFiles.newFile(destination) }
        do {
            try BlockCipher.decrypt(id: id, info: info, from: source, gate: gate) { try output.write(contentsOf: $0) }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func recoveryCode() throws -> String { try gate.authorized { keys.recoveryCode } }
}
