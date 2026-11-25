import PDFKit
import ImageIO

enum DocumentPrintSize: CaseIterable {
    case actual, card, fit

    var title: String {
        switch self {
        case .actual: return "Taille réelle (100 %)"
        case .card: return "Carte de crédit (85,60 × 53,98 mm)"
        case .fit: return "Adapter à la feuille"
        }
    }
}

/// All dimensions are in printer points (72 per inch), independent of display or printer resolution.
final class PrintDocument {
    let pdf: PDFDocument?
    private let image: CGImage?
    private let photoSize: CGSize?
    var pages: Int { pdf?.pageCount ?? 1 }

    init(_ bytes: Data) throws {
        if let source = CGImageSourceCreateWithData(bytes as CFData, nil),
           CGImageSourceGetType(source) as String? != "com.adobe.pdf" {
            let index = CGImageSourceGetPrimaryImageIndex(source)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            photoSize = Self.physicalPhotoSize(properties)
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096]
            guard let raster = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                throw VaultError.damaged
            }
            image = raster
            pdf = nil
        } else {
            guard let document = PDFDocument(data: bytes), !document.isLocked, document.pageCount > 0 else {
                throw TransportError(message: "Ce document ne peut pas être imprimé.")
            }
            pdf = document
            image = nil
            photoSize = nil
        }
    }

    static func physicalPhotoSize(_ properties: [CFString: Any]?) -> CGSize? {
        guard let properties, let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              let x = properties[kCGImagePropertyDPIWidth] as? NSNumber, let y = properties[kCGImagePropertyDPIHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, x.doubleValue.isFinite, y.doubleValue.isFinite,
              x.doubleValue > 0, y.doubleValue > 0 else { return nil }
        let size = CGSize(width: width.doubleValue * 72 / x.doubleValue, height: height.doubleValue * 72 / y.doubleValue)
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? CGSize(width: size.height, height: size.width) : size
    }

    func sourceSize(page index: Int) -> CGSize {
        if let page = pdf?.page(at: index) {
            let bounds = page.bounds(for: .cropBox)
            return abs(page.rotation % 180) == 90 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        }
        if let image { return photoSize ?? CGSize(width: image.width, height: image.height) }
        return .zero
    }

    func validate(_ mode: DocumentPrintSize) throws {
        if mode == .actual, image != nil, photoSize == nil {
            throw TransportError(message: "Cette image ne précise pas sa taille physique. Choisissez « Carte de crédit » pour un permis ou « Adapter à la feuille ».")
        }
        for index in 0..<pages {
            let size = sourceSize(page: index)
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw VaultError.damaged }
        }
    }

    func target(page: Int, mode: DocumentPrintSize, printable: CGRect) -> CGRect {
        let source = sourceSize(page: page)
        let scale: CGFloat
        switch mode {
        case .actual: scale = 1
        case .card:
            let long = 85.60 * 72 / 25.4, short = 53.98 * 72 / 25.4
            let landscape = source.width >= source.height
            scale = min((landscape ? long : short) / source.width, (landscape ? short : long) / source.height)
        case .fit: scale = min(printable.width / source.width, printable.height / source.height)
        }
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: printable.midX - size.width / 2, y: printable.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Draw into a Quartz context whose positive y axis points upwards.
    func draw(page index: Int, in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        if let page = pdf?.page(at: index) {
            let size = sourceSize(page: index)
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
            page.draw(with: .cropBox, to: context)
        } else if let image { context.draw(image, in: rect) }
    }

    #if os(macOS)
    func documentForPrinting(_ mode: DocumentPrintSize) throws -> PDFDocument {
        try validate(mode)
        if mode != .card, let pdf { return pdf }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw VaultError.unavailable }
        for index in 0..<pages {
            let natural = CGRect(origin: .zero, size: sourceSize(page: index))
            var box = CGRect(origin: .zero, size: target(page: index, mode: mode, printable: natural).size)
            let mediaBox = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: mediaBox] as CFDictionary)
            draw(page: index, in: box, context: context)
            context.endPDFPage()
        }
        context.closePDF()
        guard let result = PDFDocument(data: data as Data) else { throw VaultError.damaged }
        return result
    }
    #endif
}
