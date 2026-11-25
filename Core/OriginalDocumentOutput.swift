import Darwin
import Foundation

extension VaultStore {
    /// Explicit share/print. For large items the system can page the output without
    /// retaining a heap-sized copy. Unlink the protected backing file before writing any plaintext.
    func originalForOutput(_ id: UUID) throws -> Data {
        try gate.check()
        guard let entry = entries[id], entry.trash == nil, let info = entry.document,
              info.isFolder != true else { throw VaultError.unavailable }
        if info.size <= 32 * 1024 * 1024 { return try preview(id) }
        guard let count = Int(exactly: info.size) else { throw VaultError.tooLarge }
        let url = root.appendingPathComponent(UUID().uuidString + ".outgoing")
        let writer = try VaultFiles.newFile(url)
        defer { try? writer.close() }
        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: url)
            try FileManager.default.removeItem(at: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        defer { try? reader.close() }
        try BlockCipher.decrypt(id: id, info: info, from: blob(id), gate: gate) { try writer.write(contentsOf: $0) }
        try gate.check()
        let address = mmap(nil, count, PROT_READ, MAP_PRIVATE, reader.fileDescriptor, 0)
        guard let address, address != MAP_FAILED else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOMEM) }
        return Data(bytesNoCopy: address, count: count, deallocator: .unmap)
    }
}
