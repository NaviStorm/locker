import CryptoKit
import Foundation

extension VaultStore {
    func makeRescueKit() throws -> String {
        try gate.check()
        guard let state = family else { throw FamilyError.policy }
        let rescue = try DeviceIdentity(rescue: keys)
        guard try state.tip.decoded().member(rescue.card.fingerprint)?.role == .admin else { throw FamilyError.denied }
        let backup = FamilyLocal(tip: state.tip, waiting: [], seen: [], principal: rescue.card.fingerprint,
                                 cloudURL: state.cloudURL)
        return try Self.pack(backup, keys: keys, purpose: "family-rescue-kit").base64EncodedString()
    }

    func restoreRescueKit(_ kit: String) throws {
        try gate.check()
        guard entries.isEmpty, family == nil, try settings().provider == .local else { throw FamilyError.nonempty }
        guard let bytes = Data(base64Encoded: kit.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw VaultError.invalidCode }
        let state = try Self.unpack(FamilyLocal.self, data: bytes, keys: keys, purpose: "family-rescue-kit")
        guard try DeviceIdentity(rescue: keys).card.fingerprint == state.principal,
              try state.tip.decoded().member(state.principal)?.role == .admin else { throw FamilyError.denied }
        try commit(entries, pending, family: state)
    }

    func revokeMember(_ card: PublicIdentity, reencrypt: Bool) throws {
        try changeMembership(card: card, role: nil, scope: nil, using: identity(), reencrypt: reencrypt)
    }

    /// Publish the new epoch, tombstones and replacement ciphertext references in a single catalogue commit.
    func rotateFamilyContents(_ state: FamilyLocal) throws {
        var updated = entries
        var staged = [URL]()
        var retired = [URL]()
        do {
            for (id, old) in entries {
                guard let info = old.document else { continue }
                let nonce = UUID()
                let target = FamilyEvent.scopedID(author: state.principal, nonce: nonce, lineage: old.scope)
                let ciphertext = blob(target)
                let newKey = SymmetricKey(size: .bits256)
                try BlockCipher.reencrypt(id: id, info: info, source: blob(id), as: target,
                                          using: newKey, to: ciphertext, gate: gate)
                staged.append(ciphertext)
                let replacement = Document(labels: info.labels, key: newKey.withUnsafeBytes { Data($0) }, size: info.size,
                    originAuthor: state.principal, originNonce: nonce, lineage: old.scope, parent: id, created: info.created, previousLabels: info.previousLabels, isFolder: info.isFolder)
                updated[target] = Entry(id: target, generation: 1, revision: UUID(), document: replacement)
                guard old.generation < UInt64.max else { throw VaultError.damaged }
                updated[id] = Entry(id: id, generation: old.generation + 1, revision: UUID(), document: nil, tombstoneScope: old.scope,
                                    tombstoneAuthor: info.originAuthor, tombstoneNonce: info.originNonce)
                retired.append(blob(id))
            }
            try commit(updated, updated.mapValues(\.revision), family: state)
        } catch {
            for file in staged { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        for file in retired { try FileManager.default.removeItem(at: file) }
    }

    /// A new personal namespace and new content keys isolate all future changes from a lost device.
    func copyPersonalContents(to new: VaultStore) async throws {
        try gate.check()
        guard family == nil else { throw FamilyError.denied }
        let source = entries
        for entry in source.values {
            guard let info = entry.document else { continue }
            try gate.check()
            try await new.copyVersion(entry, info: info, from: blob(entry.id), sourceGate: gate)
        }
        guard source == entries else { throw VaultError.changed }
    }

    private func copyVersion(_ entry: Entry, info: Document, from url: URL, sourceGate: SessionGate) throws {
        try gate.check()
        guard entries[entry.id] == nil, family == nil else { throw VaultError.exists }
        let key = SymmetricKey(size: .bits256)
        let dest = blob(entry.id)
        try BlockCipher.reencrypt(id: entry.id, info: info, source: url, as: entry.id, using: key, to: dest, gate: sourceGate)
        var updated = entry
        updated.document = Document(labels: info.labels, key: key.withUnsafeBytes { Data($0) }, size: info.size,
            originAuthor: info.originAuthor, originNonce: info.originNonce, lineage: info.lineage, parent: info.parent, created: info.created,
            previousLabels: info.previousLabels, isFolder: info.isFolder)
        do { try replace(updated) }
        catch { try? FileManager.default.removeItem(at: dest); throw error }
    }
}
