import SwiftUI
import UniformTypeIdentifiers

private struct WatermarkedPDF: Transferable {
    let bytes: Data
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { $0.bytes }.suggestedFileName { $0.name }
    }
}

struct WatermarkScreen: View {
    let store: VaultStore
    let item: ListedDocument
    @State private var message = ""
    @State private var requested: String?
    @State private var copy: WatermarkedPDF?
    @State private var problem: String?
    @State private var expanded = false
    @State private var printer = DocumentPrinter()
    @State private var printingOriginal: DocumentPrintSize?

    @ViewBuilder private func reader(_ copy: WatermarkedPDF) -> some View {
        let document = DocumentPreview(data: copy.bytes, name: copy.name)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.lockerCanvas)
        #if os(iOS)
        WatermarkReaderNavigation {
            document
        } actions: {
            readerActions(copy)
        }
        #else
        document.safeAreaInset(edge: .bottom, spacing: 0) {
            HStack { readerActions(copy) }
                .labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.large)
                .padding(6).frame(maxWidth: .infinity).background(.bar)
        }
        #endif
    }

    @ViewBuilder private func readerActions(_ copy: WatermarkedPDF) -> some View {
        Button(expanded ? "Quitter le plein écran" : "Plein écran",
               systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
            expanded.toggle()
        }
        Menu {
            PrintSizeMenu(title: "Imprimer la copie avec filigrane") { size in
                do {
                    try store.gate.check()
                    try printer.present(copy.bytes, name: copy.name, size: size) { problem = $0.localizedDescription }
                } catch { problem = error.localizedDescription }
            }
            PrintSizeMenu(title: "Imprimer l’original") { printingOriginal = $0 }.disabled(printingOriginal != nil)
        } label: { Label("Imprimer", systemImage: "printer") }
        Menu {
            ShareLink(item: copy, preview: SharePreview(copy.name)) {
                Text("Partager la copie avec filigrane")
            }
            ShareLink(item: OriginalDocumentShare(store: store, item: item),
                      preview: SharePreview(item.labels.name)) { Text("Partager l’original") }
        } label: { Label("Partager", systemImage: "square.and.arrow.up") }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let copy {
                    ExpandableDocumentReader(expanded: $expanded) {
                        reader(copy)
                            .background(DocumentPrintAnchor(printer: printer))
                            .alert("Impression", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                                Button("Fermer") { problem = nil }
                            } message: { Text(problem ?? "") }
                            .privacySensitive()
                    }
                    .toolbar {
                        Button("Modifier le filigrane", systemImage: "pencil") { self.copy = nil; requested = nil }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Texte du filigrane", text: $message,
                                  prompt: Text("Ex. Uniquement pour mon dossier de location"), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        Text("Le filigrane est intégré à chaque page d’une copie PDF.").font(.footnote)
                        if requested != nil { ProgressView("Préparation de la copie…") }
                        else {
                            Button("Prévisualiser la copie") { problem = nil; requested = message }
                                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.count > 180)
                        }
                        if message.count > 180 { Text("180 caractères maximum.").font(.footnote) }
                        if let problem { Text(problem).foregroundStyle(.red) }
                        Spacer()
                    }.padding()
                }
            }
            .navigationTitle("Copie avec filigrane").modifier(VaultDismissToolbar())
        }
        .frame(idealWidth: 560, idealHeight: 550)
        .task(id: printingOriginal) {
            guard let size = printingOriginal else { return }
            await printer.presentOriginal(item, from: store, size: size) { problem = $0.localizedDescription }
            printingOriginal = nil
        }
        .onChange(of: message) { requested = nil; copy = nil; problem = nil }
        .task(id: requested) {
            guard let requested else { return }
            do {
                let bytes = try await store.watermarkedCopy(of: item, message: requested)
                try Task.checkCancellation()
                try store.gate.check()
                expanded = true
                copy = WatermarkedPDF(bytes: bytes, name: (item.labels.name as NSString).deletingPathExtension + "-filigrane.pdf")
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription; self.requested = nil }
            }
        }
    }
}

#if os(iOS)
struct WatermarkReaderNavigation<Document: View, Actions: View>: View {
    @ViewBuilder let document: () -> Document
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        // This navigation stack travels with the PDF when its hosting controller goes full screen.
        NavigationStack {
            document()
                .toolbar(.hidden, for: .navigationBar)
                .toolbar {
                    if #available(iOS 27.1, *) {
                        items.axisBehavior(.verticalPreferred)
                    } else { items }
                }
        }
    }

    private var items: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) { actions() }
    }
}
#endif
