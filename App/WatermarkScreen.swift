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
    @State private var printingOriginal = false

    var body: some View {
        NavigationStack {
            Group {
                if let copy {
                    ExpandableDocumentReader(expanded: $expanded) {
                        DocumentPreview(data: copy.bytes, name: copy.name)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.lockerCanvas)
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                HStack {
                                    Button(expanded ? "Quitter le plein écran" : "Plein écran",
                                           systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                                        expanded.toggle()
                                    }
                                    Menu {
                                        Button("Imprimer la copie avec filigrane") {
                                            do {
                                                try store.gate.check()
                                                try printer.present(copy.bytes, name: copy.name) { problem = $0.localizedDescription }
                                            } catch { problem = error.localizedDescription }
                                        }
                                        Button("Imprimer l’original") { printingOriginal = true }.disabled(printingOriginal)
                                    } label: { Label("Imprimer", systemImage: "printer") }
                                    Menu {
                                        ShareLink(item: copy, preview: SharePreview(copy.name)) {
                                            Text("Partager la copie avec filigrane")
                                        }
                                        ShareLink(item: OriginalDocumentShare(store: store, item: item),
                                                  preview: SharePreview(item.labels.name)) { Text("Partager l’original") }
                                    } label: { Label("Partager", systemImage: "square.and.arrow.up") }
                                }
                                .labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.large)
                                .padding(6).frame(maxWidth: .infinity).background(.bar)
                            }
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
            guard printingOriginal else { return }
            await printer.presentOriginal(item, from: store) { problem = $0.localizedDescription }
            printingOriginal = false
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
