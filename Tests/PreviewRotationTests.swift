import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

final class PreviewRotationTests: VaultTestCase {
    func testPDFLargerThanMemoryPreviewAndLock() async throws {
        let url = location("grand.pdf")
        let file = try VaultFiles.newFile(url)
        func write(_ string: String) throws { try file.write(contentsOf: Data(string.utf8)) }
        try write("%PDF-1.4\n")
        let comment = Data("%".utf8) + Data(repeating: 65, count: 1024 * 1024) + Data([10])
        for _ in 0..<33 { try file.write(contentsOf: comment) }
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << >> >>"]
        var offsets = [UInt64]()
        for (index, object) in objects.enumerated() {
            offsets.append(try file.offset())
            try write("\(index + 1) 0 obj\n\(object)\nendobj\n")
        }
        let xref = try file.offset()
        try write("xref\n0 4\n0000000000 65535 f \n")
        for offset in offsets { try write(String(format: "%010llu 00000 n \n", offset)) }
        try write("trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
        try file.close()

        let vault = try VaultStore(root: location("vault"), keys: VaultKeys(), create: true)
        let id = try await vault.importFile(url)
        do { _ = try await vault.preview(id); XCTFail() } catch VaultError.tooLarge {}
        let pdf = try await vault.pagedPDF(id)
        XCTAssertEqual(pdf.pages, 1)
        let page = try await pdf.render(1)
        XCTAssertEqual(page.height, 1800)
        vault.gate.revoke()
        do { _ = try await pdf.render(1); XCTFail() } catch VaultError.locked {}
    }

    func testPersonalRotationReencryptsVersions() async throws {
        let old = try VaultStore(root: location("old"), keys: VaultKeys(), create: true)
        let new = try VaultStore(root: location("new"), keys: VaultKeys(), create: true)
        let id = try await old.importData(Data(repeating: 25, count: 1_200_000), name: "fiche")
        try await old.copyPersonalContents(to: new)
        let first = await old.entries[id]?.document
        let second = await new.entries[id]?.document
        XCTAssertNotEqual(first?.key, second?.key)
        let a = try await old.preview(id)
        let b = try await new.preview(id)
        XCTAssertEqual(a, b)
        let firstCode = try await old.recoveryCode()
        let secondCode = try await new.recoveryCode()
        XCTAssertNotEqual(firstCode, secondCode)
    }
}
