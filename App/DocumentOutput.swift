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
    func presentOriginal(_ item: ListedDocument, from store: VaultStore, size: DocumentPrintSize, onError: @escaping (Error) -> Void) async {
        do {
            let bytes = try await store.originalForOutput(item.id)
            try Task.checkCancellation()
            try store.gate.check()
            try present(bytes, name: item.labels.name, size: size, onError: onError)
        } catch {
            if !Task.isCancelled, (try? store.gate.check()) != nil { onError(error) }
        }
    }

    #if os(iOS)
    weak var anchor: UIView?
    private var active: UIPrintInteractionController?

    func present(_ bytes: Data, name: String, size: DocumentPrintSize, onError: @escaping (Error) -> Void) throws {
        guard let anchor, anchor.window != nil else { throw VaultError.unavailable }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = name
        info.outputType = .general
        controller.printInfo = info
        controller.printFormatter = nil
        controller.printingItem = nil
        let document = try PrintDocument(bytes)
        try document.validate(size)
        controller.printPageRenderer = SizedPageRenderer(document: document, size: size)
        active = controller
        let finished: UIPrintInteractionController.CompletionHandler = { [weak self] controller, _, error in
            controller.printPageRenderer = nil
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
        active?.printPageRenderer = nil
        active = nil
    }
    #else
    weak var anchor: NSView?
    private weak var printSheet: NSWindow?
    func present(_ bytes: Data, name: String, size: DocumentPrintSize, onError: @escaping (Error) -> Void) throws {
        guard let window = anchor?.window else { throw VaultError.unavailable }
        let document = try PrintDocument(bytes).documentForPrinting(size)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.scalingFactor = 1
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        guard let operation = document.printOperation(for: info,
            scalingMode: size == .fit ? .pageScaleToFit : .pageScaleNone, autoRotate: true)
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
final class SizedPageRenderer: UIPrintPageRenderer {
    let document: PrintDocument
    let size: DocumentPrintSize
    init(document: PrintDocument, size: DocumentPrintSize) {
        self.document = document
        self.size = size
        super.init()
    }
    override var numberOfPages: Int { document.pages }

    override func drawContentForPage(at pageIndex: Int, in contentRect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let rect = document.target(page: pageIndex, mode: size, printable: contentRect)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: contentRect)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        document.draw(page: pageIndex, in: CGRect(origin: .zero, size: rect.size), context: context)
    }
}
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

struct PrintSizeMenu: View {
    let title: String
    let select: (DocumentPrintSize) -> Void

    var body: some View {
        Menu {
            ForEach(DocumentPrintSize.allCases, id: \.self) { size in
                Button(size.title) { select(size) }
            }
        } label: { Label(title, systemImage: "printer") }
    }
}
