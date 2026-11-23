import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

actor FakeBucket: ObjectBucket {
    var objects = [String: BucketValue]()
    var writes = 0
    var failAfter: Int?
    func interrupt(after count: Int?) { failAfter = count }
    func inventory() -> [String: String] { objects.mapValues(\.tag) }
    func get(_ name: String) -> BucketValue? { objects[name] }
    func put(_ bytes: Data, name: String, replacing tag: String?) throws {
        if writes == failAfter { throw URLError(.networkConnectionLost) }
        guard objects[name]?.tag == tag else { throw ReplicaError.conflict }
        objects[name] = BucketValue(data: bytes, tag: UUID().uuidString)
        writes += 1
    }
}

final class QueueTests: VaultTestCase {
    func testInterruptedChunksAndDurabilityAcrossRestart() async throws {
        let key = VaultKeys()
        let a = try VaultStore(root: location("a"), keys: key, create: true)
        let bucket = FakeBucket()
        let remote = try ObjectReplica(bucket: bucket, cache: location("chunks"), gate: a.gate)
        let large = Data(repeating: 37, count: 5_000_000)
        let id = try await a.importData(large, name: "Scanner-test")
        await bucket.interrupt(after: 1)
        do { try await a.synchronize(with: remote); XCTFail("Panne ignorée") } catch {}
        a.gate.revoke()
        let reopened = try VaultStore(root: location("a"), keys: key)
        let pending = await reopened.pending
        XCTAssertNotNil(pending[id])
        let local = try await reopened.preview(id)
        XCTAssertEqual(local, large)
        await bucket.interrupt(after: nil)
        let transport = try ObjectReplica(bucket: bucket, cache: location("cache2"), gate: reopened.gate)
        try await reopened.synchronize(with: transport)
        let writes = await bucket.writes
        XCTAssertEqual(writes, 3) // two distinct chunks and one index
        let drained = await reopened.pending
        XCTAssertTrue(drained.isEmpty)
        let b = try VaultStore(root: location("b"), keys: key, create: true)
        try await b.synchronize(with: transport)
        let downloaded = try await b.preview(id)
        XCTAssertEqual(downloaded, large)
    }

    func testImmutableContentVersions() async throws {
        let a = try VaultStore(root: location("a"), keys: VaultKeys(), create: true)
        let first = try await a.importData(Data([1]), name: "fiche")
        let file = location("fiche-2")
        try Data([2]).write(to: file)
        let next = try await a.importFile(file, versionOf: first)
        let list = try await a.list()
        XCTAssertEqual(Set(list.map(\.lineage)), [first])
        let old = try await a.preview(first)
        let new = try await a.preview(next)
        XCTAssertEqual(old, Data([1]))
        XCTAssertEqual(new, Data([2]))
    }

    func testTransportSecurityBeforeNetwork() async throws {
        XCTAssertThrowsError(try WebDAVBucket(server: "http://nas.local", user: "test", password: "fictif", vault: "1"))
        let oauth = DropboxAuthorization(client: "fictif")
        XCTAssertTrue(oauth.startURL.absoluteString.contains("code_challenge_method=S256"))
        do { _ = try await oauth.finish(callback: URL(string: "db-fictif://2/token?code=x&state=wrong")!); XCTFail() }
        catch {}
    }
}
