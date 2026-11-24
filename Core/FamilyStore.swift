import Foundation

extension VaultStore {
    func authorizeLocal(_ action: FamilyAction, scope: UUID) throws {
        try gate.check()
        guard let family else { return }
        guard let member = try family.tip.decoded().member(family.principal) else { throw FamilyError.denied }
        try FamilyEvent.authorize(member, action: action, scope: scope)
    }

    func canStartFamily() throws -> Bool {
        try gate.check()
        return try family == nil && entries.isEmpty && settings().provider == .local
    }

    func createFamily(using device: DeviceIdentity) throws {
        guard try canStartFamily() else { throw FamilyError.nonempty }
        let owner = Member(card: device.card, role: .admin, documents: nil)
        let rescue = try Member(card: DeviceIdentity(rescue: keys).card, role: .admin, documents: nil)
        let tip = try Policy.issue([owner, rescue], prior: nil, by: device)
        let state = FamilyLocal(tip: tip, waiting: [tip], seen: [], principal: device.card.fingerprint, history: [tip])
        try commit(entries, pending, family: state)
    }

    func createFamily() throws { try createFamily(using: identity()) }

    func joinFamily(_ ticket: String, from admin: PublicIdentity, using device: DeviceIdentity) throws {
        guard try canStartFamily() else { throw FamilyError.nonempty }
        let state = try FamilyInvitation.open(ticket, by: device, trustedAdmin: admin)
        try commit(entries, pending, family: state)
    }

    func joinFamily(_ ticket: String, from admin: PublicIdentity) throws {
        try joinFamily(ticket, from: admin, using: identity())
    }

    func members() throws -> [Member] {
        try gate.check()
        return try family?.tip.decoded().members ?? []
    }

    func updateMemberRole(_ member: Member, to role: FamilyRole, using device: DeviceIdentity? = nil) throws {
        try gate.check()
        guard let policy = try family?.tip.decoded(),
              let current = policy.member(member.card.fingerprint),
              current.role == member.role, current.documents == member.documents else { throw VaultError.changed }
        let signer = try device ?? identity()
        guard policy.member(signer.card.fingerprint)?.role == .admin, signer.card != member.card,
              family?.recoveryFingerprint != member.card.fingerprint else {
            throw FamilyError.denied
        }
        guard current.role != role else { return }
        try changeMembership(card: current.card, role: role, scope: role == .admin ? nil : current.documents, using: signer)
    }

    func changeMembership(card: PublicIdentity, role: FamilyRole?, scope: Set<UUID>?, using device: DeviceIdentity, reencrypt: Bool = false,
                          contact: TransportContact? = nil, cloudURL: URL? = nil) throws {
        try gate.check()
        guard var state = family else { throw FamilyError.policy }
        let old = try state.tip.decoded()
        guard device.card.fingerprint != card.fingerprint, old.member(device.card.fingerprint)?.role == .admin else {
            throw FamilyError.denied
        }
        if let contact {
            var contacts = state.contacts ?? [:]
            contacts[card.fingerprint] = contact
            state.contacts = contacts
        }
        if let cloudURL { state.cloudURL = cloudURL }
        var members = old.members.filter { $0.card.fingerprint != card.fingerprint }
        if let role { members.append(Member(card: card, role: role, documents: scope)) }
        let next = try Policy.issue(members, prior: state.tip, by: device)
        try state.trackPermissionChanges(from: old, to: next.decoded())
        if role == nil, let email = state.contacts?.removeValue(forKey: card.fingerprint),
           state.contacts?.values.contains(email) != true {
            state.removals = (state.removals ?? []) + [email]
        }
        state.history = (state.history ?? [state.tip]) + [next]
        state.tip = next
        state.waiting.append(next)
        state.seen = []
        if reencrypt { try rotateFamilyContents(state) }
        else { try commit(entries, entries.mapValues(\.revision), family: state) }
    }

    func changeMembership(card: PublicIdentity, role: FamilyRole?, scope: Set<UUID>?) throws {
        try changeMembership(card: card, role: role, scope: scope, using: identity())
    }

    func familyTicket(for recipient: PublicIdentity) throws -> String {
        try gate.check()
        guard let family else { throw FamilyError.policy }
        return try FamilyInvitation.make(state: family, for: recipient, by: identity())
    }

    func installPolicy(_ next: PolicyCertificate) throws {
        guard var state = family else { throw FamilyError.policy }
        try next.verify(after: state.tip)
        let policy = try next.decoded()
        try state.trackPermissionChanges(from: state.tip.decoded(), to: policy)
        let grant = policy.member(state.principal)
        let retained = entries.filter { grant?.covers($0.value.scope) == true }
        let removed = Set(entries.keys).subtracting(retained.keys)
        var queue = pending.filter { retained[$0.key] != nil }
        if grant?.role == .admin || grant?.role == .editor { queue = retained.mapValues(\.revision) }
        if grant?.role == .contributor {
            queue = queue.filter { id, _ in
                retained[id]?.generation == 1 && retained[id]?.document?.originAuthor == state.principal
            }
        }
        if grant == nil || grant?.role == .reader { queue = [:] }
        state.history = (state.history ?? [state.tip]) + [next]
        state.tip = next
        state.seen = []
        try commit(retained, queue, family: state)
        for id in removed where FileManager.default.fileExists(atPath: blob(id).path) {
            try FileManager.default.removeItem(at: blob(id))
        }
    }

    func synchronizeFamily(bucket: ObjectBucket, identity: DeviceIdentity) async throws {
        try gate.check()
        try await synchronizePolicy(bucket)
        guard let state = family, try state.tip.decoded().member(identity.card.fingerprint) != nil else { throw FamilyError.denied }
        try await finishProviderRemovals(bucket)
        let digest = state.tip.digest
        let prefix = "e-" + digest + "-"
        let parts = try ObjectReplica(bucket: bucket, cache: root.appendingPathComponent("family-transfers"), gate: gate)
        let inventory = try await bucket.inventory()
        await parts.seedInventory(inventory)
        let events = inventory.keys.filter { $0.hasPrefix(prefix) && !state.seen.contains($0) }.sorted()
        for name in events {
            try checkEpoch(digest)
            guard let value = try await bucket.get(name) else { throw VaultError.changed }
            let signed = try JSONDecoder().decode(SignedObject.self, from: value.data)
            let (event, body) = try FamilyEvent.read(signed, state: state, by: identity)
            try checkEpoch(digest)
            if let body {
                if let existing = entries[body.entry.id], existing.scope != event.scope { throw FamilyError.scope }
                try await ingestFamily(body, chunks: parts, epoch: digest)
            }
            try markSeen(name, epoch: digest)
        }

        for (id, revision) in pending {
            try checkEpoch(digest)
            guard let entry = entries[id], entry.revision == revision else { continue }
            let action: FamilyAction = entry.document == nil ? .delete : (entry.generation == 1 ? .add : .edit)
            try authorizeLocal(action, scope: entry.scope)
            let chunks = try await parts.uploadChunks(entry.document.map { _ in blob(id) })
            try checkEpoch(digest)
            guard entries[id]?.revision == revision else { continue }
            let body = FamilyBody(entry: entry, chunks: chunks)
            let signed = try FamilyEvent.make(body: body, scope: entry.scope, action: action, state: state, by: identity)
            // Immutable unique event names preserve both sides of concurrent edits.
            let name = prefix + UUID().uuidString.lowercased()
            let encoded = try JSONEncoder().encode(signed)
            try await bucket.put(encoded, name: name, replacing: nil)
            if action == .delete {
                try await redactHistory(of: id, scope: entry.scope, tombstone: encoded, bucket: bucket, epoch: digest)
            }
            try checkEpoch(digest)
            try markSeen(name, epoch: digest)
            try acknowledge(id, revision: revision)
        }
        try await finishProviderPermissionChanges(bucket)
    }

    /// Remove historical key envelopes from the live namespace after a durable signed deletion.
    /// Provider backups and ciphertext or keys already copied by a member remain outside this operation.
    private func redactHistory(of id: UUID, scope: UUID, tombstone: Data, bucket: ObjectBucket, epoch: String) async throws {
        for name in try await bucket.inventory().keys where name.hasPrefix("e-") {
            try checkEpoch(epoch)
            guard let value = try await bucket.get(name) else { continue }
            let signed = try JSONDecoder().decode(SignedObject.self, from: value.data)
            let event = try JSONDecoder().decode(FamilyEvent.self, from: signed.bytes)
            if event.document == id, event.scope == scope, event.action != .delete {
                try await bucket.put(tombstone, name: name, replacing: value.tag)
            }
        }
    }

    private func ingestFamily(_ body: FamilyBody, chunks: ObjectReplica, epoch: String) async throws {
        let incoming = body.entry
        if let info = incoming.document, entries[incoming.id] == nil {
            let file = try await chunks.assemble(body.chunks, id: incoming.id)
            try checkEpoch(epoch)
            if entries[incoming.id] == nil { try receive(file, id: incoming.id, info: info) }
        }
        let local = entries[incoming.id]
        if let left = local?.document, let right = incoming.document,
           (left.key != right.key || left.size != right.size) { throw FamilyError.fork }
        // Every signed revision is durable remotely. Preserve concurrent local metadata until its own upload.
        if let local {
            let winner = incoming.wins(over: local) ? incoming.mergingLabels(from: local) : local.mergingLabels(from: incoming)
            if winner != local { try replace(winner, enqueue: pending[incoming.id] != nil && winner.document != nil) }
        } else { try replace(incoming, enqueue: false) }
    }

    private func checkEpoch(_ digest: String) throws {
        try gate.check()
        try Task.checkCancellation()
        guard family?.tip.digest == digest else { throw VaultError.changed }
    }

    private func markSeen(_ name: String, epoch: String) throws {
        try checkEpoch(epoch)
        guard var state = family else { throw FamilyError.policy }
        state.seen.insert(name)
        try commit(entries, pending, family: state)
    }

    private func synchronizePolicy(_ bucket: ObjectBucket) async throws {
        // inventory also creates the selected remote directory on first use.
        _ = try await bucket.inventory()
        guard let initial = family else { throw FamilyError.policy }
        var remote = try await bucket.get("policy-head")
        func decode(_ value: BucketValue?) throws -> PolicyCertificate? {
            try value.map { try JSONDecoder().decode(PolicyCertificate.self, from: $0.data) }
        }
        var head = try decode(remote)
        var proposals = initial.waiting
        if initial.bootstrap == true {
            guard try initial.tip.decoded().member(initial.principal)?.role == .admin else { throw FamilyError.denied }
            let chain = initial.history ?? proposals
            guard try chain.first?.decoded().epoch == 1 else {
                throw TransportError(message: "La migration vers un fournisseur vide exige l’historique du propriétaire.")
            }
            if let head, let index = chain.firstIndex(where: { $0.digest == head.digest }) {
                proposals = Array(chain.dropFirst(index + 1))
            } else if head == nil { proposals = chain }
        }
        for next in proposals {
            try checkEpoch(initial.tip.digest)
            if head?.digest != next.digest {
                let child = try next.decoded()
                guard child.parent == head?.digest else { throw FamilyError.fork }
                let bytes = try JSONEncoder().encode(next)
                do { try await bucket.put(bytes, name: "p-" + next.digest, replacing: nil) }
                catch ReplicaError.conflict {
                    guard let object = try await bucket.get("p-" + next.digest),
                          try decode(object)?.digest == next.digest else { throw FamilyError.fork }
                }
                try await bucket.put(bytes, name: "policy-head", replacing: remote?.tag)
                remote = try await bucket.get("policy-head")
                head = try decode(remote)
                guard head?.digest == next.digest else { throw FamilyError.fork }
            }
            try checkEpoch(initial.tip.digest)
            guard var state = family else { throw FamilyError.policy }
            state.waiting.removeAll { $0.digest == next.digest }
            try commit(entries, pending, family: state)
        }
        guard let head else { throw FamilyError.stale }
        if var state = family, state.bootstrap == true, state.tip.digest == initial.tip.digest {
            state.bootstrap = false
            try commit(entries, pending, family: state)
        }
        guard head.digest != initial.tip.digest else { return }
        let pinned = try initial.tip.decoded()
        var cursor = head
        var chain = [PolicyCertificate]()
        while cursor.digest != initial.tip.digest {
            try checkEpoch(initial.tip.digest)
            let current = try cursor.decoded()
            guard current.vault == pinned.vault, current.epoch > pinned.epoch, let parent = current.parent,
                  parent.count == 64, parent.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), chain.count < 4096 else { throw FamilyError.stale }
            chain.append(cursor)
            if parent == initial.tip.digest { break }
            guard let object = try await bucket.get("p-" + parent), let previous = try decode(object),
                  previous.digest == parent, try previous.decoded().epoch == current.epoch - 1 else { throw FamilyError.policy }
            cursor = previous
        }
        try checkEpoch(initial.tip.digest)
        for certificate in chain.reversed() { try installPolicy(certificate) }
    }
}
