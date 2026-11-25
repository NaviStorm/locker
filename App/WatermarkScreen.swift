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

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Texte du filigrane", text: $message, prompt: Text("Ex. Uniquement pour mon dossier de location"),
                          axis: .vertical).textFieldStyle(.roundedBorder)
                Text("Le filigrane est intégré à chaque page d’une copie PDF.").font(.footnote)
                if let copy {
                    DocumentPreview(data: copy.bytes, name: copy.name)
                    ShareLink(item: copy, preview: SharePreview(copy.name)) {
                        Label("Partager la copie", systemImage: "square.and.arrow.up")
                    }.buttonStyle(.borderedProminent)
                } else {
                    if requested != nil { ProgressView("Préparation de la copie…") }
                    else {
                        Button("Prévisualiser la copie") { problem = nil; requested = message }
                            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.count > 180)
                    }
                    if message.count > 180 { Text("180 caractères maximum.").font(.footnote) }
                    if let problem { Text(problem).foregroundStyle(.red) }
                    Spacer()
                }
            }
            .padding().navigationTitle("Copie avec filigrane").modifier(VaultDismissToolbar())
        }
        .frame(idealWidth: 560, idealHeight: 550)
        .onChange(of: message) { requested = nil; copy = nil; problem = nil }
        .task(id: requested) {
            guard let requested else { return }
            do {
                let bytes = try await store.watermarkedCopy(of: item, message: requested)
                try Task.checkCancellation()
                try store.gate.check()
                copy = WatermarkedPDF(bytes: bytes, name: (item.labels.name as NSString).deletingPathExtension + "-filigrane.pdf")
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription; self.requested = nil }
            }
        }
    }
}
