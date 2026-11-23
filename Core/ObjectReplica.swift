import CryptoKit
import Foundation

/// Remote names are generated locally. Only ciphertext and opaque routing information cross this boundary.
struct BucketValue {
    let data: Data
    let tag: String
}

protocol ObjectBucket {
    func inventory() async throws -> [String: String]
    func get(_ name: String) async throws -> BucketValue?
    func put(_ bytes: Data, name: String, replacing tag: String?) async throws
}

private struct RemoteIndex: Codable {
    let envelope: Data
    let chunks: [String]
}

actor ObjectReplica: VaultReplica {
    let bucket: ObjectBucket
    let cache: URL
    let gate: SessionGate
    private var known = [String: String]()
    private static let segmentSize = 4 * 1024 * 1024

    init(bucket: ObjectBucket, cache: URL, gate: SessionGate) throws {
        self.bucket = bucket
        self.cache = cache
        self.gate = gate
        try VaultFiles.directory(cache)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func seedInventory(_ values: [String: String]) { known = values }

    var documentTags: [UUID: String] {
        Dictionary(known.compactMap { name, tag -> (UUID, String)? in
            guard name.hasPrefix("d-"), let id = UUID(uuidString: String(name.dropFirst(2))) else { return nil }
            return (id, tag)
        }, uniquingKeysWith: { first, _ in first })
    }

    func identifiers() async throws -> Set<UUID> {
        known = try await bucket.inventory()
        return Set(known.keys.compactMap { name in
            guard name.hasPrefix("d-") else { return nil }
            return UUID(uuidString: String(name.dropFirst(2)))
        })
    }

    func fetch(_ id: UUID, withFile: Bool) async throws -> RemoteDocument? {
        try gate.check()
        let name = "d-" + id.uuidString.lowercased()
        guard let value = try await bucket.get(name) else { return nil }
        let index = try JSONDecoder().decode(RemoteIndex.self, from: value.data)
        guard withFile else { return RemoteDocument(version: value.tag, envelope: index.envelope, file: nil) }
        let outputURL = try await assemble(index.chunks, id: id)
        return RemoteDocument(version: value.tag, envelope: index.envelope, file: outputURL)
    }

    func assemble(_ chunks: [String], id: UUID) async throws -> URL {
        let outputURL = cache.appendingPathComponent(id.uuidString + ".download")
        // This is a disposable reconstruction from verified ciphertext chunks.
        if FileManager.default.fileExists(atPath: outputURL.path) { try FileManager.default.removeItem(at: outputURL) }
        let output = try VaultFiles.newFile(outputURL)
        defer { try? output.close() }
        for chunk in chunks {
            try gate.check()
            try Task.checkCancellation()
            guard chunk.count == 64, chunk.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw VaultError.damaged
            }
            let path = cache.appendingPathComponent(chunk)
            let bytes: Data
            if let saved = try? Data(contentsOf: path), digest(saved) == chunk {
                bytes = saved
            } else {
                guard let part = try await bucket.get("b-" + chunk), part.data.count <= Self.segmentSize,
                      digest(part.data) == chunk else { throw VaultError.damaged }
                bytes = part.data
                try VaultFiles.save(bytes, to: path)
            }
            try output.write(contentsOf: bytes)
        }
        try output.close()
        return outputURL
    }

    func put(_ id: UUID, envelope: Data, file: URL?, replacing version: String?) async throws {
        let chunks = try await uploadChunks(file)
        try gate.check()
        let value = try JSONEncoder().encode(RemoteIndex(envelope: envelope, chunks: chunks))
        try await bucket.put(value, name: "d-" + id.uuidString.lowercased(), replacing: version)
    }

    func uploadChunks(_ file: URL?) async throws -> [String] {
        var chunks = [String]()
        if let file {
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let part = try input.read(upToCount: Self.segmentSize), !part.isEmpty {
                try gate.check()
                try Task.checkCancellation()
                let hash = digest(part)
                let name = "b-" + hash
                if known[name] == nil {
                    do { try await bucket.put(part, name: name, replacing: nil) }
                    catch ReplicaError.conflict {
                        guard let existing = try await bucket.get(name), digest(existing.data) == hash else {
                            throw VaultError.damaged
                        }
                    }
                    known[name] = hash
                }
                chunks.append(hash)
            }
        }
        return chunks
    }
}
