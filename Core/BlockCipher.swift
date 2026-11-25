import CryptoKit
import Foundation

enum BlockCipher {
    static let chunk = 1024 * 1024
    static let overhead = 28 // GCM nonce and tag in CryptoKit combined representation

    static func aad(_ id: UUID, _ position: UInt64) -> Data {
        Data("Locker-content-1/\(id.uuidString)/\(position)".utf8)
    }

    static func encrypt(id: UUID, key: SymmetricKey, to url: URL, gate: SessionGate,
                        read: () throws -> Data) throws -> Int64 {
        let output = try VaultFiles.newFile(url)
        do {
            var count: Int64 = 0
            var position: UInt64 = 0
            while true {
                try gate.check()
                let bytes = try read()
                guard bytes.count <= chunk else { throw VaultError.damaged }
                try frame(bytes, id: id, position: position, key: key, output: output)
                if bytes.isEmpty { break } // authenticated end marker, including for an empty document
                count += Int64(bytes.count)
                position += 1
            }
            try output.synchronize()
            try output.close()
            return count
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func frame(_ bytes: Data, id: UUID, position: UInt64, key: SymmetricKey, output: FileHandle) throws {
        let box = try AES.GCM.seal(bytes, using: key, authenticating: aad(id, position))
        guard let combined = box.combined else { throw VaultError.damaged }
        var length = UInt32(combined.count).bigEndian
        try output.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try output.write(contentsOf: combined)
    }

    static func reencrypt(id: UUID, info: Document, source: URL, as targetID: UUID,
                          using key: SymmetricKey, to url: URL, gate: SessionGate) throws {
        let output = try VaultFiles.newFile(url)
        do {
            var position: UInt64 = 0
            try decrypt(id: id, info: info, from: source, gate: gate) { bytes in
                try frame(bytes, id: targetID, position: position, key: key, output: output)
                position += 1
            }
            try frame(Data(), id: targetID, position: position, key: key, output: output)
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func decrypt(id: UUID, info: Document, from url: URL, gate: SessionGate,
                        write: (Data) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try readDocument(id: id, info: info, input: input, gate: gate, write: write)
    }

    /// A backup contains consecutive encrypted blobs. Authenticate exactly the declared length
    /// and optionally preserve the original ciphertext when importing into a new vault.
    static func readDocument(id: UUID, info: Document, input: FileHandle, gate: SessionGate,
                             encryptedLength: UInt64? = nil, copyTo output: FileHandle? = nil,
                             write: (Data) throws -> Void) throws {
        guard info.key.count == 32, info.size >= 0 else { throw VaultError.damaged }
        var remaining = encryptedLength
        let key = SymmetricKey(data: info.key)
        var position: UInt64 = 0
        var total: Int64 = 0
        while true {
            try gate.check()
            try Task.checkCancellation()
            if let remaining, remaining < 4 { throw VaultError.damaged }
            let prefix = try readExactly(4, from: input)
            let length = prefix.reduce(0) { $0 * 256 + Int($1) }
            guard (overhead...(overhead + chunk)).contains(length) else { throw VaultError.damaged }
            if let left = remaining {
                let frameSize = UInt64(length + 4)
                guard left >= frameSize else { throw VaultError.damaged }
                remaining = left - frameSize
            }
            let sealed = try readExactly(length, from: input)
            let box = try AES.GCM.SealedBox(combined: sealed)
            let bytes = try AES.GCM.open(box, using: key, authenticating: aad(id, position))
            if let output {
                try output.write(contentsOf: prefix)
                try output.write(contentsOf: sealed)
            }
            if bytes.isEmpty {
                let atEnd = try remaining.map { $0 == 0 } ?? (input.read(upToCount: 1) ?? Data()).isEmpty
                guard total == info.size, atEnd else {
                    throw VaultError.damaged
                }
                return
            }
            total += Int64(bytes.count)
            guard total <= info.size else { throw VaultError.damaged }
            try gate.authorized { try write(bytes) }
            position += 1
        }
    }

    static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            guard let part = try handle.read(upToCount: count - buffer.count), !part.isEmpty else {
                throw VaultError.damaged
            }
            buffer.append(part)
        }
        return buffer
    }
}
