import CoreImage
import UniformTypeIdentifiers
import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

final class PhotoEditTests: VaultTestCase {
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private func sample() throws -> CGImage {
        let data = Data([20, 50, 80, 110, 140, 170].flatMap { (v: UInt8) in [v, v, v, 255] })
        return try XCTUnwrap(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: data as CFData)), decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> [Int] {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.width * image.height).map { Int(bytes[$0 * 4]) }
    }

    func testRotationsMirrorsAndCropUseDisplayedCoordinates() throws {
        let base = CIImage(cgImage: try sample())
        let cases: [([PhotoEdit], [Int])] = [
            ([.right], [110, 20, 140, 50, 170, 80]),
            ([.left], [80, 170, 50, 140, 20, 110]),
            ([.horizontalMirror], [80, 50, 20, 170, 140, 110]),
            ([.verticalMirror], [110, 140, 170, 20, 50, 80]),
            ([.right, .crop(CGRect(x: 0, y: 0, width: 0.5, height: 1)), .verticalMirror], [170, 140, 110])
        ]
        for (edits, expected) in cases {
            XCTAssertEqual(try pixels(PhotoEdit.render(base, applying: edits)), expected)
        }
    }

    func testJPEGAndHEICVersionsUseOriginalResolution() async throws {
        let store = try VaultStore(root: location("formats"), keys: VaultKeys(), create: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8,
            bytesPerRow: 6400, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let full = try XCTUnwrap(context.makeImage())
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        for type in [UTType.jpeg, .heic] where writable.contains(type.identifier) {
            let bytes = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, full, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let name = "Photo." + (try XCTUnwrap(type.preferredFilenameExtension))
            let id = try await store.importData(bytes as Data, name: name)
            let preview = try await store.photoEditingPreview(id)
            XCTAssertEqual(preview.width, 1280)
            let edited = try await store.savePhotoEdits([.right], to: id)
            let data = try await store.preview(edited)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, type.identifier)
            let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(result.width, 900)
            XCTAssertEqual(result.height, 1600)
        }
    }

    func testOrientedOriginalPreservedAndEditedVersionReopens() async throws {
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try sample(), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let root = location("retouche")
        let keys = VaultKeys()
        let store = try VaultStore(root: root, keys: keys, create: true)
        let id = try await store.importData(encoded as Data, name: "Photo.tiff")
        try await store.change(id, labels: Labels(name: "Photo.tiff", folder: "Archives", category: "Famille", notes: "Essai"))
        let preview = try await store.photoEditingPreview(id)
        XCTAssertEqual(try pixels(preview), [110, 20, 140, 50, 170, 80])
        let version = try await store.savePhotoEdits([.horizontalMirror], to: id)
        let reopened = try VaultStore(root: root, keys: keys)
        let originalBytes = try await reopened.preview(id)
        XCTAssertEqual(originalBytes, encoded as Data)
        let rows = try await reopened.list()
        let edited = try XCTUnwrap(rows.first { $0.id == version })
        XCTAssertEqual(edited.lineage, id)
        XCTAssertEqual(edited.labels, Labels(name: "Photo.png", folder: "Archives", category: "Famille", notes: "Essai"))
        let saved = try await reopened.photoEditingPreview(version)
        XCTAssertEqual(try pixels(saved), [20, 110, 50, 140, 80, 170])
        reopened.gate.revoke()
        do { _ = try await reopened.savePhotoEdits([.right], to: version); XCTFail("Enregistrement après verrouillage") }
        catch VaultError.locked {}
    }
}
