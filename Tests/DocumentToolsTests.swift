import CoreText
import ImageIO
import PDFKit
import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

final class DocumentToolsTests: VaultTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 900, height: 320)
    private let sentence = "Bulletin de paie octobre 2025"

    private func drawText(in context: CGContext) {
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        ]
        context.textPosition = CGPoint(x: 35, y: 160)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: sentence, attributes: attributes)), context)
    }

    private func scan() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 900, height: 320, bitsPerComponent: 8, bytesPerRow: 3600,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        drawText(in: context)
        return try XCTUnwrap(context.makeImage())
    }

    private func pdf(scan: CGImage? = nil) throws -> Data {
        let data = NSMutableData()
        var box = bounds
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            if let scan { context.draw(scan, in: box) } else { drawText(in: context) }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func png(_ image: CGImage) throws -> Data {
        let bytes = NSMutableData()
        let target = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(target, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(target))
        return bytes as Data
    }

    func testExistingPDFAndEncryptedIndexAfterReopening() async throws {
        let root = location("coffre"), keys = VaultKeys()
        let store = try VaultStore(root: root, keys: keys, create: true)
        let folder = try await store.createFolder("Personnel")
        let id = try await store.importData(pdf(), name: "scan_0042.pdf", folder: folder)
        let reopened = try VaultStore(root: root, keys: keys)
        let list = try await reopened.list()
        let item = try XCTUnwrap(list.first)
        let first = try await reopened.searchableText(item)
        XCTAssertTrue(first.contains(sentence))
        let index = root.appendingPathComponent(id.uuidString + ".search")
        XCTAssertNil(try Data(contentsOf: index).range(of: Data(sentence.utf8)))
        let cachedStore = try VaultStore(root: root, keys: keys)
        let cached = try await cachedStore.searchableText(item)
        XCTAssertEqual(first, cached)
        let pending = await cachedStore.pending
        XCTAssertEqual(pending.count, 2)
        cachedStore.gate.revoke()
        do { _ = try await cachedStore.searchableText(item); XCTFail() } catch VaultError.locked {}
    }

    func testLargeTextFindsPhraseAcrossEncryptedBlocks() async throws {
        let store = try VaultStore(root: location("coffre"), keys: VaultKeys(), create: true)
        var bytes = Data(repeating: 32, count: 33 * BlockCipher.chunk)
        let phrase = Data("Octobre 2025".utf8)
        let offset = BlockCipher.chunk - 4
        bytes.replaceSubrange(offset..<offset + phrase.count, with: phrase)
        _ = try await store.importData(bytes, name: "Archives.txt")
        let list = try await store.list()
        let found = try await store.matchesContent(XCTUnwrap(list.first), query: "octobre 2025")
        XCTAssertTrue(found)
    }

    func testOCRFindsTextInPhotoAndScannedPDF() async throws {
        let store = try VaultStore(root: location("coffre"), keys: VaultKeys(), create: true)
        let image = try scan()
        _ = try await store.importData(png(image), name: "Image.png")
        _ = try await store.importData(pdf(scan: image), name: "Scan.pdf")
        for item in try await store.list() {
            let text = try await store.searchableText(item)
            XCTAssertTrue(text.localizedStandardContains("octobre 2025"), item.labels.name)
        }
    }

    func testWatermarkIsPrintedOnEveryPageAndTheOriginalSurvives() async throws {
        let store = try VaultStore(root: location("coffre"), keys: VaultKeys(), create: true)
        let original = try pdf()
        let id = try await store.importData(original, name: "Carte.pdf")
        let photo = try await store.importData(png(scan()), name: "Carte.png")
        let documents = try await store.list()
        for item in documents {
            let bytes = try await store.watermarkedCopy(of: item, message: "LOCATION")
            let copy = try XCTUnwrap(PDFDocument(data: bytes))
            XCTAssertEqual(copy.pageCount, item.id == photo ? 1 : 2)
            let alternate = try await store.watermarkedCopy(of: item, message: "DOSSIER")
            let other = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: alternate as CFData))))
            let output = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: bytes as CFData))))
            for number in 1...copy.pageCount {
                let page = try XCTUnwrap(copy.page(at: number - 1))
                XCTAssertTrue(page.annotations.isEmpty)
                XCTAssertTrue((page.string ?? "").isEmpty)
                func pixels(_ doc: CGPDFDocument) throws -> Data {
                    let page = try XCTUnwrap(doc.page(at: number))
                    let context = try XCTUnwrap(CGContext(data: nil, width: 900, height: 320, bitsPerComponent: 8,
                        bytesPerRow: 3600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                    context.drawPDFPage(page)
                    return Data(bytes: try XCTUnwrap(context.data), count: 320 * 3600)
                }
                XCTAssertNotEqual(try pixels(output), try pixels(other))
            }
        }
        let untouched = try await store.preview(id)
        XCTAssertEqual(untouched, original)
        let list = try await store.list()
        XCTAssertEqual(list.count, 2)
    }

    func testWatermarkKeepsA4ContentAtItsOriginalScale() async throws {
        let bytes = NSMutableData()
        var paper = CGRect(x: 0, y: 0, width: 595, height: 842)
        let writer = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &paper, nil))
        writer.beginPDFPage(nil)
        writer.setFillColor(gray: 0, alpha: 1)
        // Four registration marks near the page edges, away from the central watermark.
        for x in [35, 535] {
            for y in [55, 755] { writer.fill(CGRect(x: x, y: y, width: 20, height: 20)) }
        }
        writer.endPDFPage()
        writer.closePDF()
        let store = try VaultStore(root: location("coffre"), keys: VaultKeys(), create: true)
        _ = try await store.importData(bytes as Data, name: "Echelle.pdf")
        let list = try await store.list()
        let marked = try await store.watermarkedCopy(of: XCTUnwrap(list.first), message: "TEST")
        let result = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: marked as CFData))))
        let page = try XCTUnwrap(result.page(at: 1))
        XCTAssertEqual(page.getBoxRect(.mediaBox), paper)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 595, height: 842, bitsPerComponent: 8, bytesPerRow: 595,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.drawPDFPage(page)
        let pixels = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        for x in [45, 545] {
            for y in [65, 765] { XCTAssertLessThan(pixels[(841 - y) * 595 + x], 30) }
        }
    }

    func testLargeOriginalIsPrintableAndContainsExactlyTheStoredBytes() async throws {
        let root = location("coffre")
        let store = try VaultStore(root: root, keys: VaultKeys(), create: true)
        var original = try pdf()
        let xref = try XCTUnwrap(original.range(of: Data("startxref".utf8), options: .backwards))
        original.insert(contentsOf: Data(repeating: 32, count: 33 * 1024 * 1024), at: xref.lowerBound)
        let id = try await store.importData(original, name: "Original.pdf")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let result = try await store.originalForOutput(id)
        XCTAssertEqual(result, original)
        XCTAssertEqual(PDFDocument(data: result)?.pageCount, 2)
        #if !SWIFT_PACKAGE
        if #available(iOS 18.2, macOS 15.2, *) {
            let items = try await store.list()
            let share = OriginalDocumentShare(store: store, item: try XCTUnwrap(items.first))
            XCTAssertEqual(share.exportedContentTypes().first, .pdf)
            let shared = try await share.exported(as: .pdf)
            XCTAssertEqual(shared, original)
        }
        #endif
        #if os(iOS)
        XCTAssertTrue(UIPrintInteractionController.canPrint(result))
        #endif
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), files)
        store.gate.revoke()
        do { _ = try await store.originalForOutput(id); XCTFail() } catch VaultError.locked {}
    }

    func testWatermarkedPDFPreservesOpaqueAnnotations() async throws {
        let store = try VaultStore(root: location("coffre"), keys: VaultKeys(), create: true)
        let doc = try XCTUnwrap(PDFDocument(data: pdf()))
        let page = try XCTUnwrap(doc.page(at: 0))
        let cover = PDFAnnotation(bounds: CGRect(x: 30, y: 220, width: 120, height: 60), forType: .square, withProperties: nil)
        cover.interiorColor = .black
        page.addAnnotation(cover)
        _ = try await store.importData(XCTUnwrap(doc.dataRepresentation()), name: "Contrat.pdf")
        let docs = try await store.list()
        let result = try await store.watermarkedCopy(of: XCTUnwrap(docs.first), message: "Location")
        let output = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: result as CFData))))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 900, height: 320, bitsPerComponent: 8, bytesPerRow: 900,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.drawPDFPage(try XCTUnwrap(output.page(at: 1)))
        let pixels = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertLessThan(pixels[(319 - 250) * 900 + 80], 20)
        XCTAssertGreaterThan(pixels[(319 - 250) * 900 + 180], 230)
    }

    #if !SWIFT_PACKAGE
    @MainActor func testImportPromptOpensTheExistingDocumentOrCancels() async throws {
        let model = LockerModel(base: location("app"))
        let store = try VaultStore(root: location("coffre"), keys: VaultKeys(), create: true)
        let bytes = Data("Fichier fictif".utf8)
        let id = try await store.importData(bytes, name: "Ancien.txt")
        model.store = store
        model.library = try await store.library()
        for choice: DuplicateChoice? in [nil, .openExisting, .keepBoth] {
            model.importCaptured(bytes, name: "Nouveau.txt", folder: "")
            for _ in 0..<100 where model.duplicateImport == nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(model.duplicateImport?.existing.name, "Ancien.txt")
            model.resolveDuplicate(choice)
            for _ in 0..<100 where model.reviewingImport { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(model.openAfterImport, choice == .openExisting ? id : nil)
            XCTAssertEqual(model.documents.count, choice == .keepBoth ? 2 : 1)
        }
    }
    #endif

    func testRenamedDuplicateChoicesAndDifferentFileOfSameSize() async throws {
        let store = try VaultStore(root: location("coffre"), keys: VaultKeys(), create: true)
        let folder = try await store.createFolder("Famille")
        let bytes = Data("même contenu".utf8)
        let id = try await store.importData(bytes, name: "Ancien.pdf", folder: folder)
        let key: DuplicateImport.Key
        do {
            _ = try await store.importReviewedData(bytes, name: "Depuis Mail.pdf", folder: "", choices: [:])
            return XCTFail("Doublon attendu")
        } catch let duplicate as DuplicateImport {
            XCTAssertEqual(duplicate.existing.folder, folder)
            XCTAssertEqual(duplicate.existing.name, "Ancien.pdf")
            key = duplicate.id
        }
        let open = try await store.importReviewedData(bytes, name: "Depuis Mail.pdf", folder: "", choices: [key: .openExisting])
        XCTAssertEqual(open, id)
        let before = try await store.list()
        XCTAssertEqual(before.count, 1)
        _ = try await store.importReviewedData(bytes, name: "Depuis Mail.pdf", folder: "", choices: [key: .keepBoth])
        _ = try await store.importReviewedData(Data(repeating: 42, count: bytes.count), name: "Ancien.pdf", folder: "", choices: [:])
        let after = try await store.list()
        XCTAssertEqual(after.count, 3)
    }

    func testDuplicatesWithinFileBatchAreResolvedAtomically() async throws {
        let root = location("coffre")
        let store = try VaultStore(root: root, keys: VaultKeys(), create: true)
        let a = location("a.txt"), b = location("b.txt")
        for file in [a, b] { try Data("Exemple".utf8).write(to: file) }
        do {
            try await store.extractSelection([a, b], folder: "", expandArchives: false)
            XCTFail()
        } catch let duplicate as DuplicateImport {
            let empty = try await store.list()
            XCTAssertTrue(empty.isEmpty)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".blob") })
            let open = try await store.extractSelection([a, b], folder: "", expandArchives: false, choices: [duplicate.id: .openExisting])
            let docs = try await store.list()
            XCTAssertEqual(docs.map(\.id), [try XCTUnwrap(open)])
        }
    }
}
