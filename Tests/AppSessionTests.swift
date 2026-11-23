#if !SWIFT_PACKAGE
import XCTest
@testable import Locker

final class AppSessionTests: VaultTestCase {
    @MainActor func testAutomaticLockRemovesPreviewAccessAndDisplayedSecrets() async throws {
        let store = try VaultStore(root: location("app"), keys: VaultKeys(), create: true)
        let id = try await store.importData(Data([9]), name: "document-fictif")
        let model = LockerModel()
        try await model.adoptRotated(store, slotID: "simulation", code: "fictif")
        XCTAssertEqual(model.documents.count, 1)
        model.tick(at: .now.advanced(by: .seconds(model.timeout + 1)))
        XCTAssertNil(model.store)
        XCTAssertNil(model.recovery)
        XCTAssertTrue(model.documents.isEmpty)
        do { _ = try await store.preview(id); XCTFail("Lecture après expiration") } catch VaultError.locked {}
    }
}
#endif
