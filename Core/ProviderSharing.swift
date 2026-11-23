import CloudKit
import Foundation

extension CloudBucket {
    func revoke(email: String) async throws {
        guard isOwner else { throw FamilyError.denied }
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone)
        guard let share = try await database.record(for: id) as? CKShare else { throw FamilyError.policy }
        let target = try await container.shareParticipant(forEmailAddress: email)
        guard let recordID = target.userIdentity.userRecordID else { throw FamilyError.policy }
        if let participant = share.participants.first(where: { $0.userIdentity.userRecordID == recordID }) {
            guard participant.role != .owner else { throw FamilyError.denied }
            share.removeParticipant(participant)
            _ = try await database.save(share)
        }
    }
}

extension DropboxBucket {
    private func folderIdentifier() async throws -> String {
        _ = try await inventory()
        let metadata = try await send("get_metadata", ["path": folder])
        try Network.check(metadata.1)
        let info = try JSONSerialization.jsonObject(with: metadata.0) as? [String: Any]
        if let sharing = info?["sharing_info"] as? [String: Any], let id = sharing["shared_folder_id"] as? String { return id }
        var result = try await send("share_folder", ["path": folder, "force_async": false], sharing: true)
        for _ in 0..<30 {
            try Network.check(result.1)
            let object = try JSONSerialization.jsonObject(with: result.0) as? [String: Any]
            if let id = object?["shared_folder_id"] as? String { return id }
            guard let job = object?["async_job_id"] as? String else { throw FamilyError.policy }
            repeat {
                try await Task.sleep(for: .seconds(1))
                result = try await send("check_share_job_status", ["async_job_id": job], sharing: true)
                try Network.check(result.1)
            } while (try JSONSerialization.jsonObject(with: result.0) as? [String: Any])?[".tag"] as? String == "in_progress"
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
            contacts[card.fingerprint] = email
            state.contacts = contacts
        }
        try commit(entries, pending, family: state)
        return try familyTicket(for: card)
    }

    func finishProviderRemovals(_ bucket: ObjectBucket) async throws {
        for email in family?.removals ?? [] {
            try gate.check()
            if let cloud = bucket as? CloudBucket { try await cloud.revoke(email: email) }
            if let dropbox = bucket as? DropboxBucket { try await dropbox.revoke(email: email) }
            guard var state = family else { throw FamilyError.policy }
            state.removals?.removeAll { $0 == email }
            try commit(entries, pending, family: state)
        }
    }
}
