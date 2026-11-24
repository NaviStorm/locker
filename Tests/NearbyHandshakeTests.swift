import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

final class NearbyHandshakeTests: VaultTestCase {
    func testBothPhonesConfirmBeforeJoiningWithTheirOwnKeys() async throws {
        let owner = try DeviceIdentity(hardware: false)
        let guest = try DeviceIdentity(hardware: false)
        var host = NearbyHandshake(role: .owner, card: owner.card, account: "icloud-a")
        var client = NearbyHandshake(role: .guest, card: guest.card, account: "icloud-b")
        func wire(_ packet: NearbyHandshake.Packet) throws -> NearbyHandshake.Packet {
            try JSONDecoder().decode(NearbyHandshake.Packet.self, from: JSONEncoder().encode(packet))
        }
        let challenge = try XCTUnwrap(client.receive(try wire(.commitment(host.local.digest))))
        let reveal = try XCTUnwrap(host.receive(try wire(challenge)))
        XCTAssertNil(try client.receive(try wire(reveal)))
        XCTAssertEqual(host.code, client.code)
        XCTAssertEqual(host.code?.count, 6)
        let approval = try wire(client.confirm())
        XCTAssertNil(try host.receive(approval))
        XCTAssertFalse(host.ready)
        XCTAssertFalse(client.ready)
        XCTAssertNil(try client.receive(try wire(host.confirm())))
        XCTAssertTrue(host.ready && client.ready)
        XCTAssertEqual(host.guestAccount, "icloud-b")
        XCTAssertThrowsError(try host.receive(approval))

        let source = try VaultStore(root: location("proprietaire"), keys: VaultKeys(), create: true)
        let destination = try VaultStore(root: location("invite"), keys: VaultKeys(), create: true)
        try await source.createFamily(using: owner)
        let card = try XCTUnwrap(host.peer?.card)
        let contact = TransportContact(email: "", cloudRecordName: try XCTUnwrap(host.guestAccount), destination: "icloud-test")
        try await source.changeMembership(card: card, role: .reader, scope: nil, using: owner, contact: contact)
        let file = try await source.importData(Data("Document partagé".utf8), name: "Exemple.txt")
        let state = await source.family
        let ticket = try FamilyInvitation.make(state: XCTUnwrap(state), for: card, by: owner)
        try await destination.joinFamily(ticket, from: XCTUnwrap(client.peer?.card), using: guest)
        let members = try await destination.members()
        XCTAssertEqual(members.first { $0.card == guest.card }?.role, .reader)
        let bucket = FakeBucket()
        try await source.synchronizeFamily(bucket: bucket, identity: owner)
        try await destination.synchronizeFamily(bucket: bucket, identity: guest)
        let contents = try await destination.preview(file)
        XCTAssertEqual(contents, Data("Document partagé".utf8))
        try await source.changeMembership(card: card, role: nil, scope: nil, using: owner)
        let removed = await source.family?.removals
        XCTAssertEqual(removed, [contact])
    }

    func testSubstitutionReplayAndPrematureApprovalAreRejected() throws {
        let owner = try DeviceIdentity(hardware: false)
        let guest = try DeviceIdentity(hardware: false)
        var host = NearbyHandshake(role: .owner, card: owner.card, account: "a")
        var client = NearbyHandshake(role: .guest, card: guest.card, account: "b")
        XCTAssertThrowsError(try client.confirm())
        XCTAssertThrowsError(try client.receive(.hello(host.local)))
        let response = try XCTUnwrap(client.receive(.commitment(host.local.digest)))
        XCTAssertThrowsError(try client.receive(.commitment(host.local.digest)))
        let other = NearbyHandshake(role: .owner, card: owner.card, account: "a")
        XCTAssertThrowsError(try client.receive(.hello(other.local)))
        _ = try host.receive(response)
        XCTAssertThrowsError(try host.receive(.confirm("autre-compte")))
        XCTAssertThrowsError(try host.receive(response))
        XCTAssertFalse(host.ready)
        XCTAssertNil(host.guestAccount)
    }
}
