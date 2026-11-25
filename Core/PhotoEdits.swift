import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum PhotoEdit: Equatable {
    case left, right, horizontalMirror, verticalMirror
    /// Fractions of the currently displayed image, measured from the upper left.
    case crop(CGRect)

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(_ original: CIImage, applying edits: [Self]) throws -> CGImage {
        var image = original
        for edit in edits {
            try Task.checkCancellation()
            switch edit {
            case .left: image = image.oriented(.left)
            case .right: image = image.oriented(.right)
            case .horizontalMirror: image = image.oriented(.upMirrored)
            case .verticalMirror: image = image.oriented(.downMirrored)
            case .crop(let fraction):
                guard fraction.width > 0, fraction.height > 0,
                      CGRect(x: 0, y: 0, width: 1, height: 1).contains(fraction) else {
                    throw TransportError(message: "Le cadre doit rester dans la photo.")
                }
                let extent = image.extent
                let left = min(extent.width - 1, (fraction.minX * extent.width).rounded())
                let top = min(extent.height - 1, (fraction.minY * extent.height).rounded())
                let right = max(left + 1, (fraction.maxX * extent.width).rounded())
                let bottom = max(top + 1, (fraction.maxY * extent.height).rounded())
                image = image.cropped(to: CGRect(x: extent.minX + left, y: extent.maxY - bottom,
                                                 width: right - left, height: bottom - top))
            }
        }
        guard let result = context.createCGImage(image, from: image.extent) else { throw VaultError.damaged }
        return result
    }
}

extension VaultStore {
    private func photoSource(_ id: UUID) throws -> (CGImageSource, EncryptedRanges, Int) {
        try gate.check()
        guard let info = entries[id]?.document else { throw VaultError.unavailable }
        let ranges = try EncryptedRanges(id: id, info: info, file: blob(id), gate: gate)
        guard let source = CGImageSourceCreateWithDataProvider(try ranges.provider(), nil) else {
            throw TransportError(message: "Le format de cette photo est illisible.")
        }
        let type = CGImageSourceGetType(source) as String?
        guard CGImageSourceGetCount(source) == 1 || type == UTType.heic.identifier else {
            throw TransportError(message: "La retouche est disponible pour les photos fixes.")
        }
        return (source, ranges, CGImageSourceGetPrimaryImageIndex(source))
    }

    func photoEditingPreview(_ id: UUID, maxPixelSize: Int = 1280) throws -> CGImage {
        try photoPrintPreview(id, maxPixelSize: maxPixelSize).image
    }

    func photoPrintPreview(_ id: UUID, maxPixelSize: Int) throws -> (image: CGImage, physicalSize: CGSize?) {
        let (source, ranges, index) = try photoSource(id)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              !ranges.failed else { throw VaultError.damaged }
        try gate.check()
        return (image, PrintDocument.physicalPhotoSize(properties))
    }

    func savePhotoEdits(_ edits: [PhotoEdit], to id: UUID) throws -> UUID {
        try gate.check()
        guard !edits.isEmpty, let entry = entries[id], let document = entry.document else { throw VaultError.unavailable }
        try authorizeLocal(.add, scope: entry.scope)
        let (source, ranges, index) = try photoSource(id)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        guard let full = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw VaultError.damaged }
        let result = try PhotoEdit.render(CIImage(cgImage: full).oriented(forExifOrientation: orientation), applying: edits)
        guard !ranges.failed else { throw VaultError.damaged }
        try gate.check()

        let originalType = CGImageSourceGetType(source) as String?
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        let type = [UTType.jpeg, .heic, .png].first { $0.identifier == originalType && writable.contains($0.identifier) } ?? .png
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil) else {
            throw VaultError.unavailable
        }
        CGImageDestinationAddImage(destination, result, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TransportError(message: "Impossible d’encoder la photo retouchée.") }
        let name = document.labels.name as NSString
        let outputName = UTType(filenameExtension: name.pathExtension) == type ? document.labels.name
            : name.deletingPathExtension + "." + (type.preferredFilenameExtension ?? "png")
        return try importData(bytes as Data, name: outputName, versionOf: id)
    }
}
