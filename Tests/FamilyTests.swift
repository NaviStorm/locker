import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

final class FamilyTests: VaultTestCase {
    func testExistingReaderCanBecomeAdministratorWithoutRejoining() async throws {
        let owner = try DeviceIdentity(hardware: false)
        let guest = try DeviceIdentity(hardware: false)
        let root = location("propriétaire")
        let keys = VaultKeys()
        let host = try VaultStore(root: root, keys: keys, create: true)
        let peer = try VaultStore(root: location("proche"), keys: VaultKeys(), create: true)
        let bucket = FakeBucket()
        try await host.createFamily(using: owner)
        let allowed = try await host.importData(Data([1]), name: "Partagé")
        let extra = try await host.importData(Data([2]), name: "Autre document")
        let contact = TransportContact(email: "proche@example.invalid", destination: ProviderSettings().destination)
        try await host.changeMembership(card: guest.card, role: .reader, scope: [allowed], using: owner, contact: contact)
        let family = await host.family
        let state = try XCTUnwrap(family)
        let reader = try XCTUnwrap(state.tip.decoded().member(guest.card.fingerprint))
        try await peer.joinFamily(FamilyInvitation.make(state: state, for: guest.card, by: owner), from: owner.card, using: guest)
        try await host.synchronizeFamily(bucket: bucket, identity: owner)
        try await peer.synchronizeFamily(bucket: bucket, identity: guest)
        do { try await peer.updateMemberRole(reader, to: .admin, using: guest); XCTFail("Autopromotion") }
        catch FamilyError.denied {}
        try await host.updateMemberRole(reader, to: .editor, using: owner)
        do { try await host.updateMemberRole(reader, to: .admin, using: owner); XCTFail("Ancien droit accepté") }
        catch VaultError.changed {}
        try await host.synchronizeFamily(bucket: bucket, identity: owner)
        try await peer.synchronizeFamily(bucket: bucket, identity: guest)
        try await peer.authorizeLocal(.edit, scope: allowed)
        do { try await peer.authorizeLocal(.edit, scope: extra); XCTFail("Périmètre agrandi") } catch FamilyError.scope {}
        let reopened = try VaultStore(root: root, keys: keys)
        let stored = await reopened.family
        XCTAssertNotNil(stored?.permissionUpdates?[guest.card.fingerprint])
        let editor = try XCTUnwrap(stored?.tip.decoded().member(guest.card.fingerprint))
        try await reopened.updateMemberRole(editor, to: .admin, using: owner)
        try await reopened.synchronizeFamily(bucket: bucket, identity: owner)
        try await peer.synchronizeFamily(bucket: bucket, identity: guest)
        let data = try await peer.preview(extra)
        XCTAssertEqual(data, Data([2]))
        let third = try DeviceIdentity(hardware: false)
        try await peer.changeMembership(card: third.card, role: .contributor, scope: nil, using: guest)
        try await peer.synchronizeFamily(bucket: bucket, identity: guest)
        try await reopened.synchronizeFamily(bucket: bucket, identity: owner)
        let latest = await reopened.family
        let admin = try XCTUnwrap(latest?.tip.decoded().member(guest.card.fingerprint))
        XCTAssertEqual(admin.role, .admin)
        try await reopened.updateMemberRole(admin, to: .reader, using: owner)
        try await reopened.synchronizeFamily(bucket: bucket, identity: owner)
        try await peer.synchronizeFamily(bucket: bucket, identity: guest)
        do { try await peer.authorizeLocal(.edit, scope: allowed); XCTFail("Écriture après rétrogradation") }
        catch FamilyError.denied {}
    }

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

    func testSecondChannelVerificationSurvivesReopeningAndBelongsToOneCard() throws {
        let root = location("famille")
        let keys = VaultKeys()
        let first = try DeviceIdentity(hardware: false).card
        let second = try DeviceIdentity(hardware: false).card
        let store = try VaultStore(root: root, keys: keys, create: true)
        var verification = try store.familyPeerVerification()
        XCTAssertEqual(verification.card, "")
        verification.card = first.card
        try store.saveFamilyPeerVerification(verification)
        XCTAssertFalse(try store.familyPeerVerification().isConfirmed)
        verification.isConfirmed = true
        try store.saveFamilyPeerVerification(verification)
        store.gate.revoke()
        XCTAssertThrowsError(try store.familyPeerVerification())
        XCTAssertThrowsError(try store.saveFamilyPeerVerification(FamilyPeerVerification()))

        let reopened = try VaultStore(root: root, keys: keys)
        verification = try reopened.familyPeerVerification()
        XCTAssertEqual(verification.peer, first)
        XCTAssertTrue(verification.isConfirmed)
        let bytes = try Data(contentsOf: root.appendingPathComponent("family-peer.v1"))
        XCTAssertNil(bytes.range(of: Data(verification.card.utf8)))
        XCTAssertNil(bytes.range(of: Data(first.fingerprint.utf8)))
        let other = try VaultStore(root: location("autre"), keys: keys, create: true)
        XCTAssertEqual(try other.familyPeerVerification(), FamilyPeerVerification())

        verification.card = second.card
        try reopened.saveFamilyPeerVerification(verification)
        XCTAssertFalse(try reopened.familyPeerVerification().isConfirmed)
        verification.isConfirmed = true
        try reopened.saveFamilyPeerVerification(verification)
        verification.isConfirmed = false
        try reopened.saveFamilyPeerVerification(verification)
        XCTAssertFalse(try reopened.familyPeerVerification().isConfirmed)
        verification.card = ""
        verification.isConfirmed = true
        try reopened.saveFamilyPeerVerification(verification)
        let cleared = try VaultStore(root: root, keys: keys).familyPeerVerification()
        XCTAssertEqual(cleared, FamilyPeerVerification())
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
        draft.pasteInvitation(ticket)
        XCTAssertEqual(draft.owner, owner.card)
        XCTAssertFalse(draft.fingerprintConfirmed)
        XCTAssertNotNil(draft.nextStep)
        var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: ticket))) as? [String: Any])
        forged["sender"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reader.card))
        var tampered = FamilyJoinDraft()
        tampered.pasteInvitation(try JSONSerialization.data(withJSONObject: forged).base64EncodedString())
        XCTAssertNil(tampered.owner)
        XCTAssertNotNil(tampered.nextStep)
        // An older invitation still works when the owner sends their public card separately.
        let encoded = try XCTUnwrap(Data(base64Encoded: ticket))
        let signed = try JSONDecoder().decode(SignedObject.self, from: encoded)
        let legacy = try JSONEncoder().encode(signed).base64EncodedString()
        draft = FamilyJoinDraft()
        draft.pasteInvitation(legacy)
        XCTAssertNil(draft.owner)
        let legacyFamily = try FamilyInvitation.open(legacy, by: reader, trustedAdmin: owner.card)
        XCTAssertEqual(legacyFamily.principal, reader.card.fingerprint)
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
