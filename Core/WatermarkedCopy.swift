import PDFKit
import CoreText
import UniformTypeIdentifiers

extension VaultStore {
    nonisolated func watermarkedCopy(of item: ListedDocument, message: String) async throws -> Data {
        let mark = message.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !mark.isEmpty, mark.count <= 180 else {
            throw TransportError(message: "Saisissez un filigrane de 1 à 180 caractères.")
        }
        let type = UTType(filenameExtension: (item.labels.name as NSString).pathExtension)
        let pdf: PagedPDF?
        if type?.conforms(to: .pdf) == true { pdf = try await pagedPDF(item.id) }
        else if type?.conforms(to: .image) == true { pdf = nil }
        else { throw VaultError.unavailable }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let output = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw VaultError.unavailable }
        var annotatedDocument: PDFDocument?
        for page in 1...(pdf?.pages ?? 1) {
            try gate.check()
            try Task.checkCancellation()
            let original: CGImage
            var size: CGSize
            if let pdf {
                size = try await pdf.pageSize(page)
                if try await pdf.hasAnnotations(on: page) {
                    if annotatedDocument == nil {
                        guard item.size <= 128 * 1024 * 1024 else {
                            throw TransportError(message: "Ce PDF annoté dépasse la taille admise pour préparer une copie.")
                        }
                        annotatedDocument = PDFDocument(data: try await preview(item.id, limit: 128 * 1024 * 1024))
                    }
                    guard let annotated = annotatedDocument?.page(at: page - 1) else { throw VaultError.damaged }
                    original = try Self.flatten(annotated, size: size)
                } else { original = try await pdf.render(page) }
            } else {
                let photo = try await photoPrintPreview(item.id, maxPixelSize: 3200)
                original = photo.image
                if let physical = photo.physicalSize { size = physical }
                else {
                    let pixels = CGSize(width: original.width, height: original.height)
                    let scale = min(1, 842 / max(pixels.width, pixels.height))
                    size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
                }
            }
            try autoreleasepool {
                let stamped = try Self.stamp(original, message: mark)
                var rect = CGRect(origin: .zero, size: size)
                let box = Data(bytes: &rect, count: MemoryLayout<CGRect>.size)
                output.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)
                output.draw(stamped, in: rect)
                output.endPDFPage()
            }
            if data.length > 96 * 1024 * 1024 {
                throw TransportError(message: "La copie avec filigrane dépasse 96 Mo.")
            }
        }
        output.closePDF()
        try Task.checkCancellation()
        try gate.check()
        return data as Data
    }

    private nonisolated static func flatten(_ page: PDFPage, size: CGSize) throws -> CGImage {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { throw VaultError.damaged }
        let scale = 1800 / max(size.width, size.height)
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw VaultError.unavailable }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.displaysAnnotations = true
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw VaultError.damaged }
        return image
    }

    private nonisolated static func stamp(_ image: CGImage, message: String) throws -> CGImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw VaultError.unavailable }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.draw(image, in: bounds)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, min(width, height) * 0.09, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 0.55),
            .init(kCTStrokeColorAttributeName as String): CGColor(gray: 1, alpha: 0.75),
            .init(kCTStrokeWidthAttributeName as String): -2.0
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: message, attributes: attributes))
        let length = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let scale = min(1, hypot(width, height) * 0.80 / max(1, length))
        context.translateBy(x: width / 2, y: height / 2)
        context.rotate(by: atan2(height, width))
        context.scaleBy(x: scale, y: scale)
        context.textPosition = CGPoint(x: -length / 2, y: -CTFontGetCapHeight(font) / 2)
        CTLineDraw(line, context)
        guard let result = context.makeImage() else { throw VaultError.unavailable }
        return result
    }
}
