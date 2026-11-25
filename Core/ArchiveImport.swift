import CLockerArchive
import Foundation

enum ArchiveKind: CaseIterable {
    case zip, tar, sevenZip, rar, gzip, bzip2, xz

    init?(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard let kind = Self.allCases.first(where: { $0.extensions.contains(ext) }) else { return nil }
        self = kind
    }

    var extensions: [String] {
        switch self {
        case .zip: return ["zip"]
        case .tar: return ["tar", "tgz", "tbz", "tbz2", "txz"]
        case .sevenZip: return ["7z"]
        case .rar: return ["rar"]
        case .gzip: return ["gz", "gzip"]
        case .bzip2: return ["bz2"]
        case .xz: return ["xz"]
        }
    }

    func configure(_ reader: OpaquePointer) throws {
        let result: Int32
        switch self {
        case .zip: result = archive_read_support_format_zip_seekable(reader)
        case .sevenZip: result = archive_read_support_format_7zip(reader)
        case .rar:
            guard archive_read_support_format_rar(reader) == 0 else { throw ArchiveIssue.unsupported }
            result = archive_read_support_format_rar5(reader)
        case .tar, .gzip, .bzip2, .xz:
            // A negative status can request an external helper. Only use built-in codecs.
            guard archive_read_support_filter_gzip(reader) == 0,
                  archive_read_support_filter_bzip2(reader) == 0,
                  archive_read_support_filter_xz(reader) == 0 else { throw ArchiveIssue.unsupported }
            guard archive_read_support_format_tar(reader) == 0 else { throw ArchiveIssue.unsupported }
            result = self == .tar ? 0 : archive_read_support_format_raw(reader)
        }
        guard result == 0 else { throw ArchiveIssue.unsupported }
    }
}

enum ArchiveIssue: LocalizedError {
    case unreadable, unsupported, invalidEntry, limit, empty
    var errorDescription: String? {
        switch self {
        case .unreadable: return "L’archive est endommagée ou illisible."
        case .unsupported: return "Ce format ou cette méthode de compression nécessite un autre décompresseur."
        case .invalidEntry: return "L’archive contient un chemin, un lien ou un élément protégé que Locker ne peut pas importer."
        case .limit: return "L’extraction dépasse la limite de 1 Gio ou de 10 000 éléments par import."
        case .empty: return "L’archive est vide."
        }
    }
}

extension VaultStore {
    /// Publish the selection in a single encrypted catalogue transaction. All file paths on disk are Locker UUIDs.
    @discardableResult
    func extractSelection(_ urls: [URL], folder: String, expandArchives: Bool = true,
                          choices: ImportChoices = [:]) throws -> UUID? {
        try gate.check()
        var staged = [Entry]()
        var folders = Set(try library().folders)
        guard folder.isEmpty || folders.contains(folder) else { throw VaultError.changed }
        var remainingBytes = 1 << 30
        var remainingEntries = 10_000
        do {
            for url in urls {
                try coordinatedRead(url) { local in
                    if expandArchives, let kind = ArchiveKind(url) {
                        try readArchive(local, named: url.lastPathComponent, kind: kind, folder: folder,
                                        folders: &folders, staged: &staged,
                                        remainingBytes: &remainingBytes, remainingEntries: &remainingEntries)
                    } else {
                        let file = try FileHandle(forReadingFrom: local)
                        defer { try? file.close() }
                        staged.append(try stageDocument(name: url.lastPathComponent, folder: folder) {
                            try file.read(upToCount: BlockCipher.chunk) ?? Data()
                        })
                    }
                }
            }
            return try publishImports(staged, choices: choices)
        } catch {
            for entry in staged { try? FileManager.default.removeItem(at: blob(entry.id)) }
            throw error
        }
    }

    private func readArchive(_ url: URL, named name: String, kind: ArchiveKind, folder: String,
                             folders: inout Set<String>, staged: inout [Entry],
                             remainingBytes: inout Int, remainingEntries: inout Int) throws {
        guard let reader = archive_read_new() else { throw ArchiveIssue.unreadable }
        defer { archive_read_free(reader) }
        try kind.configure(reader)
        guard archive_read_open_filename(reader, url.path, 64 * 1024) == 0 else { throw ArchiveIssue.unreadable }
        var entry: OpaquePointer?
        var found = false
        while true {
            try gate.check()
            let status = archive_read_next_header(reader, &entry)
            if status == LOCKER_ARCHIVE_EOF { break }
            guard status == 0, let entry else { throw ArchiveIssue.unreadable }
            guard remainingEntries > 0 else { throw ArchiveIssue.limit }
            remainingEntries -= 1
            let directory = archive_entry_filetype(entry) == S_IFDIR
            guard archive_entry_is_encrypted(entry) == 0, archive_entry_hardlink(entry) == nil,
                  directory || archive_entry_filetype(entry) == S_IFREG else { throw ArchiveIssue.invalidEntry }
            let path: String
            if archive_format(reader) == LOCKER_ARCHIVE_RAW {
                guard archive_filter_code(reader, 0) != 0 else { throw ArchiveIssue.unreadable }
                path = (name as NSString).deletingPathExtension
            } else {
                guard let raw = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry),
                      let decoded = String(validatingUTF8: raw) else { throw ArchiveIssue.invalidEntry }
                path = decoded.replacingOccurrences(of: "\\", with: "/")
            }
            let components = path.split(separator: "/").filter { $0 != "." }
            guard !path.hasPrefix("/"), !components.contains(".."), components.first?.hasSuffix(":") != true,
                  path.utf8.count <= 4096 else { throw ArchiveIssue.invalidEntry }
            guard let leaf = components.last else {
                if directory { continue }
                throw ArchiveIssue.invalidEntry
            }
            let parent = ([folder] + components.dropLast().map(String.init)).filter { !$0.isEmpty }.joined(separator: "/")
            if directory {
                let directoryName = [parent, String(leaf)].filter { !$0.isEmpty }.joined(separator: "/")
                if folders.insert(directoryName).inserted {
                    staged.append(try stageDocument(name: directoryName, folder: "", isFolder: true) { Data() })
                }
            } else {
                let expected = archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil
                if let expected, expected < 0 || expected > remainingBytes { throw ArchiveIssue.limit }
                var count: Int64 = 0
                let document = try stageDocument(name: String(leaf), folder: parent) {
                    var chunk = Data(count: 256 * 1024)
                    let size = chunk.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                    guard size >= 0 else { throw ArchiveIssue.unreadable }
                    guard size <= remainingBytes else { throw ArchiveIssue.limit }
                    remainingBytes -= size
                    count += Int64(size)
                    if size == 0, let expected, count != expected { throw ArchiveIssue.unreadable }
                    chunk.count = size
                    return chunk
                }
                staged.append(document)
            }
            found = true
        }
        guard found else { throw ArchiveIssue.empty }
    }
}
