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
    var parent: UUID? = nil
    let lineage: UUID
    let created: Date?
    let id: UUID
    let labels: Labels
    let size: Int64
}

enum DocumentSortField: String {
    case name, date, size

    func sorted(_ documents: [ListedDocument], ascending: Bool) -> [ListedDocument] {
        documents.sorted { lhs, rhs in
            switch self {
            case .date where lhs.created != rhs.created:
                guard let left = lhs.created else { return false }
                guard let right = rhs.created else { return true }
                return ascending ? left < right : left > right
            case .size where lhs.size != rhs.size:
                return ascending ? lhs.size < rhs.size : lhs.size > rhs.size
            default:
                let order = lhs.labels.name.localizedStandardCompare(rhs.labels.name)
                if order == .orderedSame {
                    return ascending ? lhs.id.uuidString < rhs.id.uuidString : lhs.id.uuidString > rhs.id.uuidString
                }
                return order == (ascending ? .orderedAscending : .orderedDescending)
            }
        }
    }
}

struct VaultLibrary {
    let documents: [ListedDocument]
    let folders: [String]
    private let history: [UUID: [ListedDocument]]

    init(documents: [ListedDocument] = [], folders: [String] = []) {
        history = Dictionary(grouping: documents, by: \.lineage).mapValues { versions in
            var ordered = versions.sorted { lhs, rhs in
                let left = lhs.created ?? .distantPast, right = rhs.created ?? .distantPast
                if left != right { return left > right }
                if lhs.id == lhs.lineage { return false }
                if rhs.id == rhs.lineage { return true }
                return lhs.id.uuidString > rhs.id.uuidString
            }
            // A device with an older clock can still create a successor of a newer-dated version.
            let parents = Set(versions.compactMap(\.parent))
            if let head = ordered.firstIndex(where: { !parents.contains($0.id) }), head != 0 {
                let latest = ordered.remove(at: head)
                ordered.insert(latest, at: 0)
            }
            return ordered
        }
        let heads = Set(history.values.compactMap { $0.first?.id })
        self.documents = documents.filter { heads.contains($0.id) }
        var paths = Set(folders)
        for document in self.documents where !document.labels.folder.isEmpty {
            paths.insert(document.labels.folder)
        }
        for path in paths {
            var parent = Self.parent(of: path)
            while !parent.isEmpty && paths.insert(parent).inserted { parent = Self.parent(of: parent) }
        }
        self.folders = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func versions(of lineage: UUID) -> [ListedDocument] { history[lineage] ?? [] }

    static func parent(of path: String) -> String {
        path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
    }

    func subfolders(in parent: String) -> [String] {
        folders.filter { Self.parent(of: $0) == parent }
    }

    func documents(in folder: String) -> [ListedDocument] {
        documents.filter { $0.labels.folder == folder }
    }
}

struct Catalog: Codable {
    var entries: [UUID: Entry]
    var pending: [UUID: UUID]
    var family: FamilyLocal?
    var joinDraft: FamilyJoinDraft?
    var importedShares: Set<UUID>?
}

actor VaultStore {
    nonisolated let gate: SessionGate
    let root: URL
    let keys: VaultKeys
    private(set) var entries: [UUID: Entry]
    private(set) var pending: [UUID: UUID]
    private(set) var family: FamilyLocal?
    private(set) var importedShares: Set<UUID>?
    private var joinDraft: FamilyJoinDraft?

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
        joinDraft = state.joinDraft
        importedShares = state.importedShares
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

    func commit(_ updated: [UUID: Entry], _ queue: [UUID: UUID], family newFamily: FamilyLocal? = nil,
                importedShare: UUID? = nil) throws {
        let nextFamily = newFamily ?? family
        try writeCatalog(Catalog(entries: updated, pending: queue, family: nextFamily,
                                 joinDraft: nextFamily == nil ? joinDraft : nil,
                                 importedShares: importedShare.map { (importedShares ?? []).union([$0]) } ?? importedShares))
    }

    func familyJoinDraft() throws -> FamilyJoinDraft {
        try gate.check()
        return joinDraft ?? FamilyJoinDraft()
    }

    func saveFamilyJoinDraft(_ draft: FamilyJoinDraft) throws {
        try gate.check()
        guard family == nil else { throw FamilyError.nonempty }
        try writeCatalog(Catalog(entries: entries, pending: pending, family: nil,
                                 joinDraft: draft == FamilyJoinDraft() ? nil : draft, importedShares: importedShares))
    }

    private func writeCatalog(_ catalog: Catalog) throws {
        let data = try Self.pack(catalog, keys: keys, purpose: "catalog")
        try gate.authorized {
            try VaultFiles.save(data, to: root.appendingPathComponent("catalog.v1"))
            family = catalog.family
            entries = catalog.entries
            pending = catalog.pending
            joinDraft = catalog.joinDraft
            importedShares = catalog.importedShares
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
                documents.append(ListedDocument(parent: document.parent, lineage: entry.scope, created: document.created, id: entry.id,
                                                labels: document.labels, size: document.size))
            }
        }
        return VaultLibrary(documents: DocumentSortField.name.sorted(documents, ascending: true), folders: Array(folders))
    }

    func createFolder(_ proposed: String, in parent: String = "") throws -> String {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw TransportError(message: "Saisissez un nom de dossier valide.")
        }
        let folders = try library().folders
        guard parent.isEmpty || folders.contains(parent) else {
            throw TransportError(message: "Le dossier parent n’existe plus dans le coffre.")
        }
        let path = parent.isEmpty ? name : parent + "/" + name
        guard !folders.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) else {
            throw TransportError(message: "Un dossier porte déjà ce nom.")
        }
        _ = try add(name: path, isFolder: true) { Data() }
        return path
    }

    func renameFolder(_ folder: String, to proposed: String) throws -> String {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw TransportError(message: "Saisissez un nom de dossier valide.")
        }
        let parent = folder.lastIndex(of: "/").map { String(folder[...$0]) } ?? ""
        let destination = parent + name
        try updateFolder(folder, destination: destination)
        return destination
    }

    func deleteFolder(_ folder: String) throws {
        try updateFolder(folder, destination: nil)
    }

    private func updateFolder(_ folder: String, destination: String?) throws {
        let library = try library()
        let folders = library.folders
        guard !folder.isEmpty, folders.contains(folder) else {
            throw TransportError(message: "Ce dossier n’existe plus dans le coffre.")
        }
        func isAffected(_ path: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }
        if let destination {
            if destination == folder { return }
            if folders.contains(where: { path in
                !isAffected(path) && (path.caseInsensitiveCompare(destination) == .orderedSame
                    || path.range(of: destination + "/", options: [.anchored, .caseInsensitive]) != nil)
            }) {
                throw TransportError(message: "Un dossier porte déjà ce nom.")
            }
        }
        let deletedLineages = Set(library.documents.filter { isAffected($0.labels.folder) }.map(\.lineage))
        var updated = entries
        var queue = pending
        var removed = [UUID]()
        for entry in entries.values {
            guard let document = entry.document else { continue }
            let marker = document.isFolder == true
            let path = marker ? document.labels.name : document.labels.folder
            let affected = destination == nil && !marker ? deletedLineages.contains(entry.scope) : isAffected(path)
            guard affected else { continue }
            let labels = destination.map { target in
                var labels = document.labels
                let newPath = target + path.dropFirst(folder.count)
                if marker { labels.name = newPath } else { labels.folder = newPath }
                return labels
            }
            let next = try changedEntry(entry, labels: labels)
            updated[next.id] = next
            queue[next.id] = next.revision
            if labels == nil { removed.append(next.id) }
        }
        try commit(updated, queue)
        // A locked or interrupted cleanup can also finish when the catalogue is reopened.
        for id in removed { try? FileManager.default.removeItem(at: blob(id)) }
    }

    @discardableResult
    func importFile(_ url: URL, versionOf parent: UUID? = nil, folder: String = "") throws -> UUID {
        try gate.check()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        return try add(name: url.lastPathComponent, parent: parent, folder: folder) { try input.read(upToCount: BlockCipher.chunk) ?? Data() }
    }

    @discardableResult
    func importData(_ data: Data, name: String, folder: String = "", versionOf parent: UUID? = nil) throws -> UUID {
        var offset = 0
        var labels = parent.flatMap { entries[$0]?.document?.labels }
        labels?.name = name
        return try add(name: name, parent: parent, folder: folder, labels: labels) {
            let end = min(data.count, offset + BlockCipher.chunk)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }

    private func add(name: String, parent: UUID? = nil, folder: String = "", isFolder: Bool? = nil, labels: Labels? = nil,
                     read: () throws -> Data) throws -> UUID {
        var entry = try stageDocument(name: name, parent: parent, folder: folder, isFolder: isFolder, read: read)
        if let labels { entry.document?.labels = labels }
        return try publishVersion(entry)
    }

    private func publishVersion(_ entry: Entry) throws -> UUID {
        do { try replace(entry) }
        catch { try? FileManager.default.removeItem(at: blob(entry.id)); throw error }
        return entry.id
    }

    // The caller publishes the encrypted blob with a catalogue commit, or discards it.
    func stageDocument(name: String, parent: UUID? = nil, folder: String, isFolder: Bool? = nil,
                       read: () throws -> Data) throws -> Entry {
        try makeDocument(name: name, parent: parent, folder: folder, isFolder: isFolder) { id, key, url in
            try BlockCipher.encrypt(id: id, key: key, to: url, gate: gate, read: read)
        }
    }

    private func makeDocument(name: String, parent: UUID?, folder: String, isFolder: Bool? = nil,
                              write: (UUID, SymmetricKey, URL) throws -> Int64) throws -> Entry {
        let original = parent.flatMap { entries[$0]?.document }
        if parent != nil && (original == nil || original?.isFolder == true) { throw VaultError.unavailable }
        let nonce = UUID()
        let parentScope = parent.flatMap { entries[$0]?.scope }
        let id = family.map { FamilyEvent.scopedID(author: $0.principal, nonce: nonce, lineage: parentScope) } ?? UUID()
        let scope = parentScope ?? id
        try authorizeLocal(.add, scope: scope)
        let key = SymmetricKey(size: .bits256)
        var created = Date()
        if let parentScope, let last = entries.values.lazy.filter({ $0.scope == parentScope })
            .compactMap({ $0.document?.created }).max(), last >= created {
            created = last.addingTimeInterval(0.001)
        }
        let size = try write(id, key, blob(id))
        let document = Document(labels: Labels(name: name, folder: original?.labels.folder ?? folder),
                                key: key.withUnsafeBytes { Data($0) }, size: size, originAuthor: family?.principal,
                                originNonce: nonce, lineage: scope, parent: parent, created: created, isFolder: isFolder)
        return Entry(id: id, generation: 1, revision: UUID(), document: document)
    }

    private func validateHistory(_ ids: Set<UUID>, current: UUID) throws {
        guard let head = entries[current], head.document?.isFolder != true,
              try library().versions(of: head.scope).first?.id == current,
              !ids.contains(current), ids.allSatisfy({ id in
                  guard let entry = entries[id] else { return false }
                  return entry.document != nil && entry.document?.isFolder != true && entry.scope == head.scope
              }) else { throw TransportError(message: "L’historique a changé. Rouvrez les versions du document.") }
    }

    func restoreVersion(_ id: UUID, current: UUID) throws -> UUID {
        try validateHistory([id], current: current)
        guard let source = entries[id]?.document, let active = entries[current]?.document else { throw VaultError.unavailable }
        var restored = try makeDocument(name: source.labels.name, parent: current, folder: active.labels.folder) { target, key, url in
            try BlockCipher.reencrypt(id: id, info: source, source: blob(id), as: target, using: key, to: url, gate: gate)
            return source.size
        }
        restored.document?.labels = source.labels
        restored.document?.labels.folder = active.labels.folder
        return try publishVersion(restored)
    }

    func deleteVersions(_ ids: Set<UUID>, current: UUID) throws {
        try validateHistory(ids, current: current)
        var updated = entries
        var queue = pending
        for id in ids {
            guard let entry = entries[id] else { throw VaultError.unavailable }
            let deleted = try changedEntry(entry, labels: nil)
            updated[id] = deleted
            queue[id] = deleted.revision
        }
        try commit(updated, queue)
        for id in ids { try? FileManager.default.removeItem(at: blob(id)) }
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
        try moveDocuments([id], to: folder)
    }

    func moveDocuments(_ ids: Set<UUID>, to folder: String) throws {
        try gate.check()
        if !folder.isEmpty, try !library().folders.contains(folder) {
            throw TransportError(message: "Ce dossier n’existe plus dans le coffre.")
        }
        var updated = entries
        var queue = pending
        var changed = false
        for id in ids {
            guard let entry = entries[id], let document = entry.document, document.isFolder != true else {
                throw VaultError.unavailable
            }
            guard document.labels.folder != folder else { continue }
            var labels = document.labels
            labels.folder = folder
            let next = try changedEntry(entry, labels: labels)
            updated[id] = next
            queue[id] = next.revision
            changed = true
        }
        if changed { try commit(updated, queue) }
    }

    func change(_ id: UUID, labels: Labels?) throws {
        try gate.check()
        guard let entry = entries[id], entry.document != nil else { throw VaultError.unavailable }
        try replace(changedEntry(entry, labels: labels))
    }

    private func changedEntry(_ original: Entry, labels: Labels?) throws -> Entry {
        var entry = original
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
        return entry
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
