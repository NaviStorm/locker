import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

final class FamilyTests: VaultTestCase {
    func testScopedSharingOfflineRevocationAndRescue() async throws {
        let keys = VaultKeys()
        let owner = try DeviceIdentity(hardware: false)
        let reader = try DeviceIdentity(hardware: false)
        let writer = try DeviceIdentity(hardware: false)
        let a = try VaultStore(root: location("a"), keys: keys, create: true)
        let b = try VaultStore(root: location("b"), keys: VaultKeys(), create: true)
        let c = try VaultStore(root: location("c"), keys: VaultKeys(), create: true)
        let bucket = FakeBucket()
        try await a.createFamily(using: owner)
        let allowed = try await a.importData(Data("autorisé".utf8), name: "A")
        let privateID = try await a.importData(Data([42]), name: "B")
        try await a.changeMembership(card: reader.card, role: .reader, scope: [allowed], using: owner)
        try await a.changeMembership(card: writer.card, role: .contributor, scope: nil, using: owner)
        let initial = await a.family
        let state = try XCTUnwrap(initial)
        let ticket = try FamilyInvitation.make(state: state, for: reader.card, by: owner)
        let other = try FamilyInvitation.make(state: state, for: writer.card, by: owner)
        try await b.joinFamily(ticket, from: owner.card, using: reader)
        try await c.joinFamily(other, from: owner.card, using: writer)
        try await a.synchronizeFamily(bucket: bucket, identity: owner)
        try await b.synchronizeFamily(bucket: bucket, identity: reader)
        let downloaded = try await b.list()
        XCTAssertEqual(downloaded.map(\.id), [allowed])
        do { _ = try await b.preview(privateID); XCTFail("Accès hors périmètre") } catch {}
        do { try await b.change(allowed, labels: nil); XCTFail("Suppression avec droit de lecture") } catch {}
        try await c.synchronizeFamily(bucket: bucket, identity: writer)
        let note = try await c.importData(Data([7]), name: "Ajout hors ligne")
        do { try await c.change(note, labels: Labels(name: "refus")); XCTFail() } catch {}
        try await c.synchronizeFamily(bucket: bucket, identity: writer)
        try await a.synchronizeFamily(bucket: bucket, identity: owner)
        let received = try await a.preview(note)
        XCTAssertEqual(received, Data([7]))

        let oldHead = await bucket.get("policy-head")
        let oldInfo = await a.entries[allowed]?.document
        let kit = try await a.makeRescueKit()
        try await a.changeMembership(card: reader.card, role: nil, scope: nil, using: owner, reencrypt: true)
        try await a.synchronizeFamily(bucket: bucket, identity: owner)
        do { try await b.synchronizeFamily(bucket: bucket, identity: reader); XCTFail("Révocation ignorée") } catch FamilyError.denied {}
        let remaining = try await b.list()
        XCTAssertTrue(remaining.isEmpty)
        let rotatedList = try await a.list()
        let rotated = try XCTUnwrap(rotatedList.first { $0.lineage == allowed })
        let newInfo = await a.entries[rotated.id]?.document
        XCTAssertNotEqual(oldInfo?.key, newInfo?.key)
        let recovered = try VaultStore(root: location("secours"), keys: VaultKeys(code: keys.recoveryCode), create: true)
        try await recovered.restoreRescueKit(kit)
        try await recovered.synchronizeFamily(bucket: bucket, identity: DeviceIdentity(rescue: keys))
        let restored = try await recovered.preview(rotated.id)
        XCTAssertEqual(restored, Data("autorisé".utf8))

        let current = await bucket.get("policy-head")
        try await bucket.put(XCTUnwrap(oldHead).data, name: "policy-head", replacing: current?.tag)
        do { try await a.synchronizeFamily(bucket: bucket, identity: owner); XCTFail("Ancienne politique acceptée") }
        catch FamilyError.stale {}
    }

    func testJoinDraftGuidancePersistenceAndAcceptance() async throws {
        let owner = try DeviceIdentity(hardware: false)
        let reader = try DeviceIdentity(hardware: false)
        let host = try VaultStore(root: location("host"), keys: VaultKeys(), create: true)
        try await host.createFamily(using: owner)
        try await host.changeMembership(card: reader.card, role: .reader, scope: nil, using: owner)
        let family = await host.family
        let ticket = try FamilyInvitation.make(state: XCTUnwrap(family), for: reader.card, by: owner)
        let root = location("recipient")
        let keys = VaultKeys()
        let store = try VaultStore(root: root, keys: keys, create: true)

        var draft = FamilyJoinDraft()
        XCTAssertNotNil(draft.nextStep)
        draft.ticket = "  \n"
        XCTAssertNotNil(draft.nextStep)
        draft.ticket = ticket
        XCTAssertNotNil(draft.nextStep)
        draft.card = "carte incomplète"
        draft.fingerprintConfirmed = true
        XCTAssertFalse(draft.fingerprintConfirmed)
        draft.card = owner.card.card
        XCTAssertNotNil(draft.nextStep)
        draft.fingerprintConfirmed = true
        XCTAssertNil(draft.nextStep)
        draft.ticket = "Invitation chiffrée"
        XCTAssertNotNil(draft.nextStep)
        draft.ticket = ticket
        try await store.saveFamilyJoinDraft(draft)
        let pending = await store.pending
        XCTAssertTrue(pending.isEmpty)
        let bytes = try Data(contentsOf: root.appendingPathComponent("catalog.v1"))
        XCTAssertNil(bytes.range(of: Data(ticket.utf8)))
        XCTAssertNil(bytes.range(of: Data(draft.card.utf8)))
        store.gate.revoke()
        do { _ = try await store.familyJoinDraft(); XCTFail("Lecture après verrouillage") } catch VaultError.locked {}

        let reopened = try VaultStore(root: root, keys: keys)
        let restored = try await reopened.familyJoinDraft()
        XCTAssertEqual(restored, draft)
        var changed = restored
        changed.card = reader.card.card
        XCTAssertFalse(changed.fingerprintConfirmed)
        XCTAssertNotNil(changed.nextStep)
        do {
            try await reopened.joinFamily(ticket, from: reader.card, using: reader)
            XCTFail("Invitation acceptée avec une autre carte")
        } catch {}
        let afterFailure = try await reopened.familyJoinDraft()
        XCTAssertEqual(afterFailure, draft)
        try await reopened.joinFamily(restored.ticket, from: XCTUnwrap(restored.owner), using: reader)
        let joined = try VaultStore(root: root, keys: keys)
        let remaining = try await joined.familyJoinDraft()
        let principal = await joined.family?.principal
        XCTAssertEqual(remaining, FamilyJoinDraft())
        XCTAssertEqual(principal, reader.card.fingerprint)
    }

    func testWrongRecipientAndForgedAdminCannotIssuePolicy() throws {
        let admin = try DeviceIdentity(hardware: false)
        let visitor = try DeviceIdentity(hardware: false)
        let stranger = try DeviceIdentity(hardware: false)
        let members = [Member(card: admin.card, role: .admin, documents: nil),
                       Member(card: visitor.card, role: .reader, documents: nil)]
        let tip = try Policy.issue(members, prior: nil, by: admin)
        XCTAssertThrowsError(try Policy.issue(members, prior: tip, by: visitor))
        let state = FamilyLocal(tip: tip, waiting: [], seen: [], principal: admin.card.fingerprint)
        let ticket = try FamilyInvitation.make(state: state, for: visitor.card, by: admin)
        XCTAssertThrowsError(try FamilyInvitation.open(ticket, by: stranger, trustedAdmin: admin.card))
        XCTAssertThrowsError(try FamilyInvitation.open(ticket, by: visitor, trustedAdmin: stranger.card))
    }
}
