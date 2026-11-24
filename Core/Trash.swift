import Foundation

struct TrashItem: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let isFolder: Bool
    let date: Date

    init(name: String, isFolder: Bool) {
        id = UUID()
        self.name = name
        self.isFolder = isFolder
        date = Date()
    }
}

extension VaultStore {
    func trashItems() throws -> [TrashItem] {
        try gate.check()
        var items = [UUID: TrashItem]()
        for entry in entries.values {
            if let item = entry.trash, entry.document != nil { items[item.id] = item }
        }
        return items.values.sorted { $0.date > $1.date }
    }

    func trashDocument(_ id: UUID) throws {
        guard let head = entries[id], let doc = head.document, head.trash == nil,
              try library().versions(of: head.scope).first?.id == id else { throw VaultError.changed }
        let name = doc.labels.folder.isEmpty ? doc.labels.name : doc.labels.folder + "/" + doc.labels.name
        let selected = entries.values.filter { $0.scope == head.scope && $0.document != nil && $0.trash == nil }
        try markTrash(selected, item: TrashItem(name: name, isFolder: false))
    }

    func markTrash(_ selected: [Entry], item: TrashItem?) throws {
        guard !selected.isEmpty else { throw VaultError.changed }
        var updated = entries
        var queue = pending
        for var entry in selected {
            try authorizeLocal(item == nil ? .edit : .delete, scope: entry.scope)
            guard entry.generation < UInt64.max else { throw VaultError.damaged }
            entry.generation += 1
            entry.revision = UUID()
            entry.trash = item
            updated[entry.id] = entry
            queue[entry.id] = entry.revision
        }
        try commit(updated, queue)
    }

    func restoreTrash(_ item: TrashItem) throws {
        if item.isFolder, try library().folders.contains(where: { $0.caseInsensitiveCompare(item.name) == .orderedSame }) {
            throw TransportError(message: "Un dossier occupe déjà cet emplacement. Renommez-le avant la restauration.")
        }
        try markTrash(entries.values.filter { $0.trash?.id == item.id && $0.document != nil }, item: nil)
    }

    func purgeTrash(_ item: TrashItem) throws {
        try gate.check()
        var updated = entries
        var queue = pending
        let selected = entries.values.filter { $0.trash?.id == item.id && $0.document != nil }
        guard !selected.isEmpty else { throw VaultError.changed }
        for entry in selected {
            let deleted = try changedEntry(entry, labels: nil)
            updated[entry.id] = deleted
            queue[entry.id] = deleted.revision
        }
        try commit(updated, queue)
        for entry in selected { try? FileManager.default.removeItem(at: blob(entry.id)) }
    }
}
