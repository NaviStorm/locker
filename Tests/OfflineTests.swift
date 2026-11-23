import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

private actor UnreachableReplica: VaultReplica {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func identifiers() async throws -> Set<UUID> {
        await withCheckedContinuation { value in
            continuation = value
            waiting = true
        }
        throw URLError(.notConnectedToInternet)
    }
    func disconnect() { continuation?.resume(); continuation = nil }
    func fetch(_ id: UUID, withFile: Bool) throws -> RemoteDocument? { throw URLError(.notConnectedToInternet) }
    func put(_ id: UUID, envelope: Data, file: URL?, replacing version: String?) throws { throw URLError(.notConnectedToInternet) }
}

final class OfflineTests: VaultTestCase {
    func testWaitingNASDoesNotBlockEitherVault() async throws {
        let a = try VaultStore(root: location("nas"), keys: VaultKeys(), create: true)
        let b = try VaultStore(root: location("cloud"), keys: VaultKeys(), create: true)
        let slow = UnreachableReplica()
        let job = Task { try await a.synchronize(with: slow) }
        while !(await slow.waiting) { await Task.yield() }
        let id = try await a.importData(Data([3, 5]), name: "Hors ligne")
        try await a.change(id, labels: Labels(name: "Fiche locale"))
        let bytes = try await a.preview(id)
        XCTAssertEqual(bytes, Data([3, 5]))
        _ = try await b.importData(Data([6]), name: "Autre coffre")
        let other = try ObjectReplica(bucket: FakeBucket(), cache: location("indépendant"), gate: b.gate)
        try await b.synchronize(with: other)
        let otherQueue = await b.pending
        XCTAssertTrue(otherQueue.isEmpty)
        await slow.disconnect()
        do { try await job.value; XCTFail() } catch {}
        let waiting = await a.pending
        XCTAssertNotNil(waiting[id])
    }
}
