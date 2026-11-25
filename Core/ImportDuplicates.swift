import CryptoKit
import Foundation

struct DuplicateImport: Error, Identifiable {
    struct Key: Hashable {
        let position: Int
        let digest: Data
        let source: String
        let destination: String
        let existingPath: String
    }
    let id: Key
    let existing: Labels
}

enum DuplicateChoice { case openExisting, keepBoth }
typealias ImportChoices = [DuplicateImport.Key: DuplicateChoice]

extension VaultStore {
    /// All blobs are staged before this transaction. A rejected batch is discarded by its caller.
    func publishImports(_ staged: [Entry], choices: ImportChoices, share: UUID? = nil) throws -> UUID? {
        try gate.check()
        let heads = try list()
        var unexamined = Dictionary(grouping: heads, by: \.size)
        let sizes = staged.compactMap { $0.document }.filter { $0.isFolder != true }.map(\.size)
        let repeatedSizes = Set(Dictionary(grouping: sizes, by: { $0 }).filter { $0.value.count > 1 }.keys)
        var matches = [Data: Entry]()
        func fingerprint(_ entry: Entry) throws -> Data {
            guard let doc = entry.document else { throw VaultError.unavailable }
            var hash = SHA256()
            try BlockCipher.decrypt(id: entry.id, info: doc, from: blob(entry.id), gate: gate) { hash.update(data: $0) }
            return Data(hash.finalize())
        }

        var updated = entries
        var queue = pending
        var skipped = [UUID]()
        var open: UUID?
        for (position, entry) in staged.enumerated() {
            guard let doc = entry.document else { throw VaultError.damaged }
            if doc.isFolder != true && (unexamined[doc.size] != nil || repeatedSizes.contains(doc.size)) {
                // Only decrypt existing files whose size occurs in the incoming batch.
                // Index each size group once, even for archives containing thousands of peers.
                if let group = unexamined.removeValue(forKey: doc.size) {
                    for candidate in group {
                        guard let existing = entries[candidate.id] else { continue }
                        let key = try fingerprint(existing)
                        if matches[key] == nil { matches[key] = existing }
                    }
                }
                let digest = try fingerprint(entry)
                if let existing = matches[digest], let labels = existing.document?.labels {
                    let key = DuplicateImport.Key(position: position, digest: digest, source: doc.labels.name,
                                                  destination: doc.labels.folder, existingPath: labels.folder + "/" + labels.name)
                    guard let choice = choices[key] else { throw DuplicateImport(id: key, existing: labels) }
                    if choice == .openExisting {
                        open = existing.id
                        skipped.append(entry.id)
                        continue
                    }
                } else { matches[digest] = entry }
            }
            updated[entry.id] = entry
            queue[entry.id] = entry.revision
        }
        if skipped.count != staged.count || share != nil { try commit(updated, queue, importedShare: share) }
        for id in skipped { try? FileManager.default.removeItem(at: blob(id)) }
        return open
    }

    func importReviewedData(_ data: Data, name: String, folder: String, choices: ImportChoices) throws -> UUID? {
        guard try folder.isEmpty || library().folders.contains(folder) else { throw VaultError.changed }
        var offset = 0
        let entry = try stageDocument(name: name, folder: folder) {
            let end = min(data.count, offset + BlockCipher.chunk)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
        do { return try publishImports([entry], choices: choices) }
        catch { try? FileManager.default.removeItem(at: blob(entry.id)); throw error }
    }
}
