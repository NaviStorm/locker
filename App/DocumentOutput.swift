import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct OriginalDocumentShare: Transferable {
    let store: VaultStore
    let item: ListedDocument
    var type: UTType { UTType(filenameExtension: (item.labels.name as NSString).pathExtension) ?? .data }

    private static func representation(_ type: UTType) -> some TransferRepresentation<Self> {
        DataRepresentation(exportedContentType: type) { (source: Self) in
            try await source.store.originalForOutput(source.item.id)
        }
        .exportingCondition { $0.type.conforms(to: type) }
        .suggestedFileName { $0.item.labels.name }
    }

    static var transferRepresentation: some TransferRepresentation {
        representation(.pdf)
        representation(.jpeg)
        representation(.png)
        representation(.heic)
        representation(.tiff)
        representation(.gif)
        representation(.plainText)
        representation(.data)
    }
}

@MainActor
final class DocumentPrinter {
    func presentOriginal(_ item: ListedDocument, from store: VaultStore, onError: @escaping (Error) -> Void) async {
        do {
            let bytes = try await store.originalForOutput(item.id)
            try Task.checkCancellation()
            try store.gate.check()
            try present(bytes, name: item.labels.name, onError: onError)
        } catch {
            if !Task.isCancelled, (try? store.gate.check()) != nil { onError(error) }
        }
    }

    #if os(iOS)
    weak var anchor: UIView?
    private var active: UIPrintInteractionController?

    func present(_ bytes: Data, name: String, onError: @escaping (Error) -> Void) throws {
        guard let anchor, anchor.window != nil else { throw VaultError.unavailable }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = name
        info.outputType = .general
        controller.printInfo = info
        controller.printFormatter = nil
        controller.printingItem = nil
        if UIPrintInteractionController.canPrint(bytes) { controller.printingItem = bytes }
        else if let image = UIImage(data: bytes) { controller.printingItem = image }
        else { throw TransportError(message: "Ce format ne peut pas être imprimé sur cet appareil.") }
        active = controller
        let finished: UIPrintInteractionController.CompletionHandler = { [weak self] controller, _, error in
            controller.printingItem = nil
            self?.active = nil
            if let error { onError(error) }
        }
        let presented: Bool
        if anchor.traitCollection.userInterfaceIdiom == .pad {
            let point = CGRect(x: anchor.bounds.midX, y: anchor.bounds.minY, width: 1, height: 1)
            presented = controller.present(from: point, in: anchor, animated: true, completionHandler: finished)
        } else { presented = controller.present(animated: true, completionHandler: finished) }
        if !presented { cancel(); throw TransportError(message: "La fenêtre d’impression est indisponible.") }
    }

    func cancel() {
        active?.dismiss(animated: false)
        active?.printingItem = nil
        active = nil
    }
    #else
    weak var anchor: NSView?
    private weak var printSheet: NSWindow?
    func present(_ bytes: Data, name: String, onError: @escaping (Error) -> Void) throws {
        guard let window = anchor?.window else { throw VaultError.unavailable }
        let document: PDFDocument
        if let pdf = PDFDocument(data: bytes), pdf.pageCount > 0 { document = pdf }
        else if let image = NSImage(data: bytes), let page = PDFPage(image: image) {
            document = PDFDocument()
            document.insert(page, at: 0)
        } else { throw TransportError(message: "Ce format ne peut pas être imprimé sur ce Mac.") }
        guard let operation = document.printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: true)
        else { throw VaultError.unavailable }
        operation.jobTitle = name
        let previous = window.attachedSheet
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        if window.attachedSheet !== previous { printSheet = window.attachedSheet }
    }

    func cancel() {
        if let sheet = printSheet { sheet.sheetParent?.endSheet(sheet, returnCode: .cancel) }
        printSheet = nil
    }
    #endif
}

#if os(iOS)
struct DocumentPrintAnchor: UIViewRepresentable {
    let printer: DocumentPrinter
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        printer.anchor = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
    func makeCoordinator() -> DocumentPrinter { printer }
    static func dismantleUIView(_ view: UIView, coordinator: DocumentPrinter) { coordinator.cancel() }
}
#else
struct DocumentPrintAnchor: NSViewRepresentable {
    let printer: DocumentPrinter
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        printer.anchor = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    func makeCoordinator() -> DocumentPrinter { printer }
    static func dismantleNSView(_ view: NSView, coordinator: DocumentPrinter) { coordinator.cancel() }
}
#endif
