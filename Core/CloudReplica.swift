import CloudKit
import Foundation

struct CloudReplica: VaultReplica {
    let database: CKDatabase
    let zone: CKRecordZone

    init(vaultID: String) {
        database = CKContainer.default().privateCloudDatabase
        zone = CKRecordZone(zoneName: "Locker1-" + vaultID)
    }

    func identifiers() async throws -> Set<UUID> {
        _ = try await database.save(zone)
        var token: CKServerChangeToken?
        var result = Set<UUID>()
        while true {
            try Task.checkCancellation()
            let page = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: token,
                                                            desiredKeys: [], resultsLimit: 200)
            for (key, value) in page.modificationResultsByID {
                _ = try value.get()
                if let id = UUID(uuidString: key.recordName) { result.insert(id) }
            }
            for removed in page.deletions {
                if let id = UUID(uuidString: removed.recordID.recordName) { result.remove(id) }
            }
            guard page.moreComing else { return result }
            token = page.changeToken
        }
    }

    private func record(_ id: UUID, fields: [String]) async throws -> CKRecord? {
        let key = CKRecord.ID(recordName: id.uuidString, zoneID: zone.zoneID)
        let values = try await database.records(for: [key], desiredKeys: fields)
        guard let value = values[key] else { throw VaultError.unavailable }
        do { return try value.get() }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    func fetch(_ id: UUID, withFile: Bool) async throws -> RemoteDocument? {
        guard let record = try await record(id, fields: withFile ? ["envelope", "body"] : ["envelope"]) else { return nil }
        guard let version = record.recordChangeTag, let envelope = record["envelope"] as? Data else {
            throw VaultError.damaged
        }
        return RemoteDocument(version: version, envelope: envelope, file: (record["body"] as? CKAsset)?.fileURL)
    }

    func put(_ id: UUID, envelope: Data, file: URL?, replacing version: String?) async throws {
        let prior = try await record(id, fields: ["envelope"])
        guard prior?.recordChangeTag == version else { throw ReplicaError.conflict }
        let key = CKRecord.ID(recordName: id.uuidString, zoneID: zone.zoneID)
        let item = prior ?? CKRecord(recordType: "LockerDocument", recordID: key)
        item["envelope"] = envelope
        // CloudKit saves the record and its asset together, including removal of the asset on deletion.
        item["body"] = file.map(CKAsset.init(fileURL:))
        do {
            let response = try await database.modifyRecords(saving: [item], deleting: [],
                savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let saved = response.saveResults[key] else { throw VaultError.unavailable }
            _ = try saved.get()
        } catch let error as CKError {
            if error.code == .serverRecordChanged || error.partialErrorsByItemID?.values.contains(where: {
                ($0 as? CKError)?.code == .serverRecordChanged
            }) == true { throw ReplicaError.conflict }
            throw error
        }
    }
}
