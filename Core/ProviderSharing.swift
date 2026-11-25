import CloudKit
import Foundation

protocol MemberPermissionBucket: ObjectBucket {
    func updatePermission(for contact: TransportContact, writers: [TransportContact]) async throws
}

extension CloudBucket: MemberPermissionBucket {
    func updatePermission(for contact: TransportContact, writers: [TransportContact]) async throws {
        guard isOwner else { throw FamilyError.denied }
        let target = try await recordID(for: contact)
        var write = writers.contains(contact)
        if !write {
            for other in writers {
                if try await recordID(for: other) == target { write = true; break }
            }
        }
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone)
        guard let share = try await database.record(for: id) as? CKShare,
              let participant = share.participants.first(where: { $0.userIdentity.userRecordID == target }) else {
            throw TransportError(message: "iCloud ne retrouve pas le participant de ce partage.")
        }
        let permission: CKShare.ParticipantPermission = write ? .readWrite : .readOnly
        guard participant.role != .owner, participant.permission != permission else { return }
        participant.permission = permission
        share.addParticipant(participant)
        _ = try await database.save(share)
    }

    private func recordID(for contact: TransportContact) async throws -> CKRecord.ID {
        if let name = contact.cloudRecordName { return CKRecord.ID(recordName: name) }
        let target = try await container.shareParticipant(forEmailAddress: contact.email)
        guard let id = target.userIdentity.userRecordID else { throw FamilyError.policy }
        return id
    }

    func revoke(contact: TransportContact, keeping active: [TransportContact]) async throws {
        guard isOwner else { throw FamilyError.denied }
        let recordID = try await recordID(for: contact)
        for other in active where other.destination == contact.destination {
            if try await self.recordID(for: other) == recordID { return }
        }
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone)
        guard let share = try await database.record(for: id) as? CKShare else { throw FamilyError.policy }
        if let participant = share.participants.first(where: { $0.userIdentity.userRecordID == recordID }) {
            guard participant.role != .owner else { throw FamilyError.denied }
            share.removeParticipant(participant)
            _ = try await database.save(share)
        }
    }
}

extension DropboxBucket: MemberPermissionBucket {
    func updatePermission(for contact: TransportContact, writers: [TransportContact]) async throws {
        let level = writers.contains { $0.email.caseInsensitiveCompare(contact.email) == .orderedSame } ? "editor" : "viewer"
        let folderID = try await folderIdentifier(create: false)
        var route = "list_folder_members"
        var args = ["shared_folder_id": folderID]
        while true {
            try Task.checkCancellation()
            let page = try await send(route, args, sharing: true)
            try Network.check(page.1)
            let listing = try JSONSerialization.jsonObject(with: page.0) as? [String: Any]
            for item in listing?["users"] as? [[String: Any]] ?? [] {
                guard let user = item["user"] as? [String: Any], let email = user["email"] as? String,
                      email.caseInsensitiveCompare(contact.email) == .orderedSame,
                      let id = user["account_id"] as? String else { continue }
                let current = (item["access_type"] as? [String: Any])?[".tag"] as? String
                guard current != "owner", current != level else { return }
                let result = try await send("update_folder_member", ["shared_folder_id": folderID,
                    "member": [".tag": "dropbox_id", "dropbox_id": id], "access_level": level], sharing: true)
                try Network.check(result.1)
                return
            }
            guard let cursor = listing?["cursor"] as? String, !cursor.isEmpty else {
                throw TransportError(message: "Compte introuvable dans le partage Dropbox. Vérifiez que le proche a accepté l’invitation Dropbox.")
            }
            route = "list_folder_members/continue"
            args = ["cursor": cursor]
        }
    }

    private func folderIdentifier(create: Bool = true) async throws -> String {
        if create { _ = try await inventory() }
        let metadata = try await send("get_metadata", ["path": folder])
        try Network.check(metadata.1)
        let info = try JSONSerialization.jsonObject(with: metadata.0) as? [String: Any]
        if let id = info?["shared_folder_id"] as? String { return id }
        if let sharing = info?["sharing_info"] as? [String: Any], let id = sharing["shared_folder_id"] as? String { return id }
        guard create else { throw TransportError(message: "Ce dossier Dropbox n’est plus partagé.") }
        var result = try await send("share_folder", ["path": folder, "force_async": false], sharing: true)
        var job: String?
        for _ in 0..<30 {
            try Network.check(result.1)
            let object = try JSONSerialization.jsonObject(with: result.0) as? [String: Any]
            if let id = object?["shared_folder_id"] as? String { return id }
            if let completed = object?["complete"] as? [String: Any], let id = completed["shared_folder_id"] as? String { return id }
            if let next = object?["async_job_id"] as? String { job = next }
            guard let job, object?[".tag"] as? String != "failed" else { throw FamilyError.policy }
            try await Task.sleep(for: .seconds(1))
            result = try await send("check_share_job_status", ["async_job_id": job], sharing: true)
        }
        throw VaultError.changed
    }

    func authorize(email: String, write: Bool) async throws {
        let folderID = try await folderIdentifier()
        let args: [String: Any] = ["shared_folder_id": folderID, "quiet": false,
            "members": [["member": [".tag": "email", "email": email], "access_level": write ? "editor" : "viewer"]]]
        let result = try await send("add_folder_member", args, sharing: true)
        try Network.check(result.1)
    }

    func revoke(email: String) async throws {
        let folderID = try await folderIdentifier()
        let args: [String: Any] = ["shared_folder_id": folderID, "member": [".tag": "email", "email": email],
                                   "leave_a_copy": false]
        let result = try await send("remove_folder_member", args, sharing: true)
        if result.1.statusCode == 409, String(decoding: result.0, as: UTF8.self).contains("no_explicit_access") { return }
        try Network.check(result.1)
        let reply = try JSONSerialization.jsonObject(with: result.0) as? [String: Any]
        if let job = reply?["async_job_id"] as? String {
            for _ in 0..<30 {
                try await Task.sleep(for: .seconds(1))
                let status = try await send("check_job_status", ["async_job_id": job], sharing: true)
                try Network.check(status.1)
                let tag = (try JSONSerialization.jsonObject(with: status.0) as? [String: Any])?[".tag"] as? String
                if tag == "complete" { return }
                guard tag == "in_progress" else { throw VaultError.changed }
            }
            throw VaultError.changed
        }
    }
}

extension VaultStore {
    func issueNearbyTicket(to card: PublicIdentity, account: String) async throws -> String {
        let config = try settings()
        guard config.provider == .cloud, let initial = family else { throw FamilyError.policy }
        let policy = try initial.tip.decoded()
        guard policy.member(initial.principal)?.role == .admin, initial.principal != card.fingerprint else { throw FamilyError.denied }
        if let member = policy.member(card.fingerprint) {
            let previous = initial.contacts?[card.fingerprint]
            guard member.role == .reader, member.documents == nil,
                  previous == nil || previous?.cloudRecordName == account else {
                throw TransportError(message: "Cet appareil a déjà des droits personnalisés. Utilisez la gestion des appareils.")
            }
        }
        guard let cloud = try await objectBucket(config) as? CloudBucket, cloud.isOwner else { throw FamilyError.denied }
        let recordID = CKRecord.ID(recordName: account)
        var route = initial.cloudURL
        var contact: TransportContact?
        if try await cloud.container.userRecordID() != recordID {
            let participant = try await cloud.container.shareParticipant(forUserRecordID: recordID)
            guard participant.userIdentity.userRecordID == recordID else { throw FamilyError.policy }
            try Task.checkCancellation()
            route = try await cloud.authorize(participant: participant, write: false, preserveWrite: true)
            contact = TransportContact(email: "", cloudRecordName: account, destination: config.destination)
        }
        try Task.checkCancellation()
        guard family?.tip.digest == initial.tip.digest, try settings() == config else { throw VaultError.changed }
        try changeMembership(card: card, role: .reader, scope: nil, using: identity(), contact: contact, cloudURL: route)
        return try familyTicket(for: card)
    }

    func issueTicket(to card: PublicIdentity, email: String) async throws -> String {
        guard let original = family, let member = try original.tip.decoded().member(card.fingerprint),
              try original.tip.decoded().member(original.principal)?.role == .admin else { throw FamilyError.denied }
        let config = try settings()
        var route = original.cloudURL
        if config.provider == .cloud || config.provider == .dropbox {
            guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TransportError(message: "Indiquez le compte du destinataire chez le fournisseur.")
            }
            let bucket = try await objectBucket(config)
            if let cloud = bucket as? CloudBucket { route = try await cloud.authorize(email: email, write: member.role != .reader) }
            if let dropbox = bucket as? DropboxBucket { try await dropbox.authorize(email: email, write: member.role != .reader) }
        }
        try gate.check()
        guard var state = family, state.tip.digest == original.tip.digest else { throw VaultError.changed }
        state.cloudURL = route
        if !email.isEmpty {
            var contacts = state.contacts ?? [:]
            contacts[card.fingerprint] = TransportContact(email: email, destination: config.destination)
            state.contacts = contacts
        }
        try commit(entries, pending, family: state)
        return try familyTicket(for: card)
    }

    func finishProviderPermissionChanges(_ bucket: ObjectBucket) async throws {
        guard let provider = bucket as? MemberPermissionBucket else { return }
        let destination = try settings().destination
        for (fingerprint, token) in family?.permissionUpdates ?? [:] {
            try gate.check()
            guard let state = family, state.permissionUpdates?[fingerprint] == token,
                  let contact = state.contacts?[fingerprint], contact.destination == destination else { continue }
            let policy = try state.tip.decoded()
            let writers = policy.members.compactMap { member -> TransportContact? in
                guard member.role != .reader, let writer = state.contacts?[member.card.fingerprint],
                      writer.destination == destination else { return nil }
                return writer
            }
            try await provider.updatePermission(for: contact, writers: writers)
            try gate.check()
            guard var latest = family, latest.permissionUpdates?[fingerprint] == token else { continue }
            latest.permissionUpdates?.removeValue(forKey: fingerprint)
            try commit(entries, pending, family: latest)
        }
    }

    func finishProviderRemovals(_ bucket: ObjectBucket) async throws {
        let destination = try settings().destination
        for contact in family?.removals ?? [] where contact.destination == destination {
            let email = contact.email
            try gate.check()
            if let cloud = bucket as? CloudBucket {
                let active = family?.contacts?.values.map { $0 } ?? []
                try await cloud.revoke(contact: contact, keeping: active)
            }
            if let dropbox = bucket as? DropboxBucket { try await dropbox.revoke(email: email) }
            guard var state = family else { throw FamilyError.policy }
            state.removals?.removeAll { $0 == contact }
            try commit(entries, pending, family: state)
        }
    }
}
