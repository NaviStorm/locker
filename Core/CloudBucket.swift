import CloudKit
import Foundation

struct CloudBucket: ObjectBucket {
    let container: CKContainer
    let database: CKDatabase
    let zone: CKRecordZone.ID
    let isOwner: Bool
    let directory: URL

    static func connect(vault: String, invitation: URL?, cache: URL) async throws -> CloudBucket {
        let container = CKContainer.default()
        let zoneName = "LockerObjects-" + vault
        if let invitation {
            let meta = try await container.shareMetadata(for: invitation)
            guard meta.share.recordID.zoneID.zoneName == zoneName else { throw FamilyError.policy }
            if meta.participantRole != .owner {
                if meta.participantStatus != .accepted { _ = try await container.accept(meta) }
                return CloudBucket(container: container, database: container.sharedCloudDatabase,
                                   zone: meta.share.recordID.zoneID, isOwner: false, directory: cache)
            }
        }
        let zone = CKRecordZone(zoneName: zoneName)
        _ = try await container.privateCloudDatabase.save(zone)
        return CloudBucket(container: container, database: container.privateCloudDatabase, zone: zone.zoneID,
                           isOwner: true, directory: cache)
    }

    func authorize(email: String, write: Bool) async throws -> URL {
        guard isOwner else { throw FamilyError.denied }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone)
        let share: CKShare
        do {
            guard let existing = try await database.record(for: shareID) as? CKShare else { throw FamilyError.policy }
            share = existing
        } catch let error as CKError where error.code == .unknownItem { share = CKShare(recordZoneID: zone) }
        share.publicPermission = .none
        let participant = try await container.shareParticipant(forEmailAddress: email)
        participant.permission = write ? .readWrite : .readOnly
        share.addParticipant(participant)
        guard let saved = try await database.save(share) as? CKShare, let url = saved.url else { throw FamilyError.policy }
        return url
    }

    func inventory() async throws -> [String: String] {
        var token: CKServerChangeToken?
        var result = [String: String]()
        while true {
            try Task.checkCancellation()
            let page = try await database.recordZoneChanges(inZoneWith: zone, since: token, desiredKeys: [], resultsLimit: 300)
            for (id, value) in page.modificationResultsByID {
                let record = try value.get().record
                if record.recordType == "LockerObject" { result[id.recordName] = record.recordChangeTag }
            }
            for removal in page.deletions { result.removeValue(forKey: removal.recordID.recordName) }
            if !page.moreComing { return result }
            token = page.changeToken
        }
    }

    private func record(_ name: String, fields: [String]) async throws -> CKRecord? {
        let id = CKRecord.ID(recordName: name, zoneID: zone)
        let values = try await database.records(for: [id], desiredKeys: fields)
        guard let value = values[id] else { throw VaultError.unavailable }
        do { return try value.get() }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    func get(_ name: String) async throws -> BucketValue? {
        guard let record = try await record(name, fields: ["bytes"]) else { return nil }
        guard let file = (record["bytes"] as? CKAsset)?.fileURL, let tag = record.recordChangeTag,
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024 else {
            throw VaultError.damaged
        }
        return try BucketValue(data: Data(contentsOf: file), tag: tag)
    }

    func put(_ bytes: Data, name: String, replacing tag: String?) async throws {
        let existing = try await record(name, fields: [])
        guard existing?.recordChangeTag == tag else { throw ReplicaError.conflict }
        let file = directory.appendingPathComponent(UUID().uuidString + ".upload")
        try VaultFiles.directory(directory)
        try VaultFiles.save(bytes, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let object = existing ?? CKRecord(recordType: "LockerObject", recordID: CKRecord.ID(recordName: name, zoneID: zone))
        object["bytes"] = CKAsset(fileURL: file)
        do {
            let result = try await database.modifyRecords(saving: [object], deleting: [], savePolicy: .ifServerRecordUnchanged)
            guard let saved = result.saveResults[object.recordID] else { throw VaultError.unavailable }
            _ = try saved.get()
        } catch let error as CKError {
            if error.code == .serverRecordChanged || error.partialErrorsByItemID?.values.contains(where: {
                ($0 as? CKError)?.code == .serverRecordChanged
            }) == true { throw ReplicaError.conflict }
            throw error
        }
    }
}
