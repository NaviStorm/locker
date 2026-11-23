import Foundation

struct RemoteDocument {
    let version: String
    let envelope: Data
    let file: URL?
}

enum ReplicaError: Error { case conflict }

protocol VaultReplica {
    func identifiers() async throws -> Set<UUID>
    func fetch(_ id: UUID, withFile: Bool) async throws -> RemoteDocument?
    func put(_ id: UUID, envelope: Data, file: URL?, replacing version: String?) async throws
}

extension VaultStore {
    func synchronize(with replica: VaultReplica) async throws {
        try gate.check()
        let remoteIDs = try await replica.identifiers()
        for id in remoteIDs.union(entries.keys) {
            var success = false
            for _ in 0..<4 {
                try gate.check()
                try Task.checkCancellation()
                do {
                    try await reconcile(id, with: replica)
                    success = true
                    break
                } catch ReplicaError.conflict { continue }
            }
            guard success else { throw VaultError.changed }
        }
    }

    private func reconcile(_ id: UUID, with replica: VaultReplica) async throws {
        let remote = try await replica.fetch(id, withFile: false)
        try gate.check()
        var local = entries[id]
        let purpose = "sync/" + id.uuidString
        if let remote {
            let incoming = try Self.unpack(Entry.self, data: remote.envelope, keys: keys, purpose: purpose)
            guard incoming.id == id else { throw VaultError.damaged }
            if incoming == local { try acknowledge(id, revision: local?.revision); return }
            if local == nil || local.map({ incoming.wins(over: $0) }) == true {
                if let info = incoming.document {
                    if let previous = local?.document {
                        guard previous.key == info.key, previous.size == info.size else { throw VaultError.damaged }
                    } else {
                        let full = try await replica.fetch(id, withFile: true)
                        try gate.check()
                        guard full?.version == remote.version, entries[id] == local else { throw ReplicaError.conflict }
                        guard let file = full?.file else { throw VaultError.damaged }
                        try receive(file, id: id, info: info)
                    }
                }
                let merged = local.map { incoming.mergingLabels(from: $0) } ?? incoming
                try replace(merged, enqueue: merged != incoming)
                if merged == incoming { return }
                local = merged
            } else if let winner = local {
                let merged = winner.mergingLabels(from: incoming)
                if merged != winner {
                    try replace(merged)
                    local = merged
                }
            }
        }
        guard let local else { return }
        let envelope = try Self.pack(local, keys: keys, purpose: purpose)
        try gate.check()
        try await replica.put(id, envelope: envelope, file: local.document.map { _ in blob(id) },
                              replacing: remote?.version)
        try gate.check()
        if entries[id] != local { throw ReplicaError.conflict }
        try acknowledge(id, revision: local.revision)
    }

    private func receive(_ source: URL, id: UUID, info: Document) throws {
        let staging = root.appendingPathComponent(UUID().uuidString + ".incoming")
        try FileManager.default.copyItem(at: source, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try BlockCipher.decrypt(id: id, info: info, from: staging, gate: gate) { _ in }
        try gate.authorized {
            let destination = blob(id)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        }
    }
}
