import PDFKit
import UniformTypeIdentifiers
import Vision

extension VaultStore {
    private func searchKey(_ item: ListedDocument) throws -> VaultKeys {
        try gate.check()
        guard let entry = entries[item.id], entry.trash == nil, let doc = entry.document,
              (doc.labels.name as NSString).pathExtension.lowercased() == (item.labels.name as NSString).pathExtension.lowercased()
        else { throw VaultError.changed }
        return try VaultKeys(secret: doc.key)
    }

    private func cachedText(_ item: ListedDocument, purpose: String) throws -> String? {
        let key = try searchKey(item)
        let url = blob(item.id).deletingPathExtension().appendingPathExtension("search")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.unpack(String.self, data: data, keys: key, purpose: purpose)
    }

    private func cacheText(_ text: String, item: ListedDocument, purpose: String) throws {
        let bytes = try Self.pack(text, keys: searchKey(item), purpose: purpose)
        try gate.authorized {
            try VaultFiles.save(bytes, to: blob(item.id).deletingPathExtension().appendingPathExtension("search"))
        }
    }

    nonisolated func matchesContent(_ item: ListedDocument, query: String) async throws -> Bool {
        let type = UTType(filenameExtension: (item.labels.name as NSString).pathExtension)
        if item.size > 32 * 1024 * 1024, type?.conforms(to: .plainText) == true {
            return try await scanLargeText(item, query: query)
        }
        return try await searchableText(item).localizedStandardContains(query)
    }

    // Search long text directly in authenticated blocks to avoid a second, document-sized allocation.
    private func scanLargeText(_ item: ListedDocument, query: String) throws -> Bool {
        _ = try searchKey(item)
        guard let doc = entries[item.id]?.document else { throw VaultError.unavailable }
        var tail = Data()
        var encoding: String.Encoding?
        var total = 0
        var found = false
        try BlockCipher.decrypt(id: item.id, info: doc, from: blob(item.id), gate: gate) { chunk in
            guard !found else { return }
            if total == 0 {
                if chunk.starts(with: [0xff, 0xfe]) { encoding = .utf16LittleEndian }
                if chunk.starts(with: [0xfe, 0xff]) { encoding = .utf16BigEndian }
            }
            var window = tail + chunk
            if encoding != nil && (total - tail.count) % 2 != 0 { window.removeFirst() }
            let text: String
            if let encoding {
                let aligned = window.prefix(window.count - window.count % 2)
                text = String(data: aligned, encoding: encoding) ?? ""
            } else { text = String(decoding: window, as: UTF8.self) }
            func matches(_ value: String) -> Bool {
                value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").localizedStandardContains(query)
            }
            found = matches(text)
            if !found, encoding == nil, text.contains("\u{fffd}"), let latin = String(data: window, encoding: .isoLatin1) {
                found = matches(latin)
            }
            tail = Data(window.suffix(max(64, query.utf8.count * 4 + 8)))
            total += chunk.count
        }
        try gate.check()
        return found
    }

    nonisolated func searchableText(_ item: ListedDocument) async throws -> String {
        let ext = (item.labels.name as NSString).pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext),
              type.conforms(to: .pdf) || type.conforms(to: .image) || type.conforms(to: .plainText)
        else { return "" }
        let purpose = "search-v1/" + item.id.uuidString + "/" + ext
        if let cached = try await cachedText(item, purpose: purpose) { return cached }
        try Task.checkCancellation()
        let text: String
        if type.conforms(to: .pdf) {
            let pdf = try await pagedPDF(item.id)
            let native: PDFDocument?
            if item.size <= 32 * 1024 * 1024 { native = PDFDocument(data: try await preview(item.id)) }
            else { native = nil }
            var pages = [String]()
            for number in 1...pdf.pages {
                try Task.checkCancellation()
                try gate.check()
                let page = native?.page(at: number - 1)
                let embedded = page?.string ?? ""
                if embedded.trimmingCharacters(in: .whitespacesAndNewlines).count < 24 || Self.hasGraphicObjects(page) {
                    let image = try await pdf.render(number)
                    pages.append(embedded + " " + (try Self.recognize(image)))
                } else { pages.append(embedded) }
            }
            text = pages.joined(separator: " ")
        } else if type.conforms(to: .image) {
            let image = try await photoEditingPreview(item.id, maxPixelSize: 3000)
            text = try Self.recognize(image)
        } else {
            let data = try await preview(item.id)
            if let decoded = String(data: data, encoding: .utf8) { text = decoded }
            else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
                text = String(data: data, encoding: .utf16) ?? ""
            } else { text = String(data: data, encoding: .isoLatin1) ?? "" }
        }
        try Task.checkCancellation()
        let normalized = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        try await cacheText(normalized, item: item, purpose: purpose)
        return normalized
    }

    // A scan can have a native text header and a photographed body on the same page.
    private nonisolated static func hasGraphicObjects(_ page: PDFPage?) -> Bool {
        var node = page?.pageRef?.dictionary
        for _ in 0..<64 {
            guard let current = node else { return false }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources {
                var objects: CGPDFDictionaryRef?
                return CGPDFDictionaryGetDictionary(resources, "XObject", &objects)
                    && objects.map { CGPDFDictionaryGetCount($0) > 0 } == true
            }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(current, "Parent", &parent) else { return false }
            node = parent
        }
        return false
    }

    private nonisolated static func recognize(_ image: CGImage) throws -> String {
        try autoreleasepool {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["fr-FR", "en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
    }
}
