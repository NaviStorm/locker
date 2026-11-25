import Foundation

private struct BackupRecord: Codable {
    let entry: Entry
    let length: UInt64
}

extension VaultStore {
    private static let backupHeader = Data("LOCKER-BACKUP-1\n".utf8)
    private static let manifestLimit = 128 * 1024 * 1024

    // The authenticated manifest binds the order, identities, keys and lengths of the encrypted blobs.
    private func copyBackupBytes(_ length: UInt64, from input: FileHandle, to output: FileHandle) throws {
        var remaining = length
        while remaining > 0 {
            try gate.check()
            try Task.checkCancellation()
            let data = try BlockCipher.readExactly(Int(min(remaining, UInt64(BlockCipher.chunk))), from: input)
            try output.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
    }

    func writeBackup(in directory: URL) throws -> URL {
        try gate.check()
        let member = try family.flatMap { state -> Member in
            guard let member = try state.tip.decoded().member(state.principal) else { throw FamilyError.denied }
            return member
        }
        let records = try entries.values.compactMap { entry -> BackupRecord? in
            guard entry.document != nil, member?.covers(entry.scope) != false else { return nil }
            let length = try blob(entry.id).resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let length, length > 0 else { throw VaultError.damaged }
            return BackupRecord(entry: entry, length: UInt64(length))
        }
        let manifest = try Self.pack(records, keys: keys, purpose: "backup-manifest-v1")
        guard manifest.count <= Self.manifestLimit else { throw VaultError.tooLarge }
        let id = UUID().uuidString
        let temporary = directory.appendingPathComponent(".locker-" + id + ".partial")
        let destination = directory.appendingPathComponent("Locker-" + id + ".lockerbackup")
        let output = try VaultFiles.newFile(temporary)
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        try output.write(contentsOf: Self.backupHeader)
        var length = UInt64(manifest.count).bigEndian
        try output.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try output.write(contentsOf: manifest)
        for record in records {
            let source = try FileHandle(forReadingFrom: blob(record.entry.id))
            defer { try? source.close() }
            try copyBackupBytes(record.length, from: source, to: output)
        }
        try output.synchronize()
        try output.close()
        try gate.authorized { try FileManager.default.moveItem(at: temporary, to: destination) }
        return destination
    }

    /// Verification reads every authenticated content block, including its end marker.
    /// Restoration imports a snapshot into an empty personal vault with its own recovery key.
    func readBackup(_ url: URL, code: String, restore: Bool) throws -> Int {
        try gate.check()
        let backupKeys = try VaultKeys(code: code)
        if restore {
            guard entries.isEmpty, family == nil, try settings().provider == .local else {
                throw TransportError(message: "Pour restaurer, créez un coffre personnel vide en mode local.")
            }
        }
        return try coordinatedRead(url) { available in
            let input = try FileHandle(forReadingFrom: available)
            defer { try? input.close() }
            guard try BlockCipher.readExactly(Self.backupHeader.count, from: input) == Self.backupHeader else {
                throw TransportError(message: "Ce fichier n’est pas une sauvegarde Locker.")
            }
            let length = try BlockCipher.readExactly(8, from: input).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard length <= Self.manifestLimit else { throw VaultError.damaged }
            let manifest = try BlockCipher.readExactly(Int(length), from: input)
            let records: [BackupRecord]
            do { records = try Self.unpack([BackupRecord].self, data: manifest, keys: backupKeys, purpose: "backup-manifest-v1") }
            catch { throw TransportError(message: "Code de récupération incorrect ou sauvegarde endommagée.") }
            var rows = [UUID: Entry]()
            var staged = [URL]()
            var committed = false
            defer { if !committed { for file in staged { try? FileManager.default.removeItem(at: file) } } }
            for record in records {
                let entry = record.entry
                guard let info = entry.document, rows[entry.id] == nil, record.length > 0 else { throw VaultError.damaged }
                let file = blob(entry.id)
                let output = restore ? try VaultFiles.newFile(file) : nil
                if restore { staged.append(file) }
                defer { try? output?.close() }
                try BlockCipher.readDocument(id: entry.id, info: info, input: input, gate: gate,
                                             encryptedLength: record.length, copyTo: output) { _ in }
                try output?.synchronize()
                try output?.close()
                rows[entry.id] = entry
            }
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw VaultError.damaged }
            try gate.check()
            if restore { try commit(rows, rows.mapValues(\.revision)); committed = true }
            return records.count
        }
    }
}
