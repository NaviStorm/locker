import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct DocumentScreen<Actions: View>: View {
    @Bindable var model: LockerModel
    let item: ListedDocument
    let select: (UUID) -> Void
    let addVersion: () -> Void
    let actions: Actions
    @State private var bytes: Data?
    @State private var pdf: PagedPDF?
    @State private var notice = ""
    @State private var editing = false
    @State private var editingPhoto = false
    @State private var largePhoto: CGImage?
    private var isPhoto: Bool {
        UTType(filenameExtension: (item.labels.name as NSString).pathExtension)?.conforms(to: .image) == true
    }
    @State private var exporting = false
    @State private var history: [Labels] = []
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 12) {
            if let pdf { LargePDFScreen(pdf: pdf) }
            else if let largePhoto {
                ZoomablePhoto(image: Image(decorative: largePhoto, scale: 1),
                              size: CGSize(width: largePhoto.width, height: largePhoto.height))
            }
            else if let bytes {
                DocumentPreview(data: bytes, name: item.labels.name)
            } else if notice.isEmpty { ProgressView() }
            else { ContentUnavailableView("Aperçu indisponible", systemImage: "doc", description: Text(notice)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.lockerCanvas)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 10) {
                if !item.labels.folder.isEmpty {
                    Label(item.labels.folder, systemImage: "folder").lineLimit(1)
                }
                if !item.labels.category.isEmpty {
                    Label(item.labels.category, systemImage: "tag").lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(item.size.formatted(.byteCount(style: .file))).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(item.labels.name)
        .toolbar {
            ToolbarItemGroup {
                if isPhoto {
                    Button("Modifier la photo", systemImage: "slider.horizontal.3") { editingPhoto = true }
                        .help("Modifier la photo")
                }
                if let bytes {
                    ShareLink(item: SharedBytes(bytes: bytes, name: item.labels.name),
                              preview: SharePreview(item.labels.name)) { Label("Partager une copie", systemImage: "square.and.arrow.up") }
                }
                Menu {
                    actions
                    Divider()
                    Button("Exporter dans un dossier…", systemImage: "folder") { exporting = true }
                    Button("Modifier la fiche", systemImage: "pencil") { editing = true }
                    Button("Ajouter une version", systemImage: "doc.on.doc", action: addVersion)
                    Menu("Versions du document") {
                        ForEach(model.documents.filter { $0.lineage == item.lineage }.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }) { row in
                            Button(row.labels.name + " · " + (row.created?.formatted() ?? String(row.id.uuidString.prefix(6)))) { select(row.id) }
                        }
                    }
                    Button("Historique de la fiche") {
                        model.perform { store in history = try await store.labelHistory(item.id); showHistory = true }
                    }
                } label: { Label("Actions", systemImage: "ellipsis.circle") }
            }
        }
        .task(id: item.id) {
            guard let store = model.store else { return }
            do {
                if item.size > 32 * 1024 * 1024, (item.labels.name as NSString).pathExtension.lowercased() == "pdf" {
                    let paged = try await store.pagedPDF(item.id)
                    try store.gate.check()
                    pdf = paged
                    return
                }
                if item.size > 32 * 1024 * 1024, isPhoto {
                    let preview = try await store.photoEditingPreview(item.id, maxPixelSize: 4096)
                    try store.gate.check()
                    largePhoto = preview
                    return
                }
                let loaded = try await store.preview(item.id)
                try store.gate.check()
                bytes = loaded
            } catch { notice = error.localizedDescription }
        }
        .lockerPanel(isPresented: $editingPhoto) {
            if let store = model.store {
                PhotoEditorScreen(store: store, item: item) { id, library in
                    guard model.store === store else { return }
                    model.library = library
                    model.activity()
                    select(id)
                }
            }
        }
        .sheet(isPresented: $editing) { EditLabels(model: model, item: item) }
        .sheet(isPresented: $showHistory) {
            VStack {
                Text("Historique de la fiche").font(.headline)
                if history.isEmpty { Text("Aucune modification antérieure.") }
                List(Array(history.enumerated()), id: \.offset) { _, row in
                    Text([row.name, row.folder, row.category, row.notes].filter { !$0.isEmpty }.joined(separator: " · "))
                }
                Button("Fermer") { showHistory = false }
            }.padding().frame(idealWidth: 430, idealHeight: 320)
        }
        .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
            guard case let .success(dir) = result else { return }
            model.perform { store in
                let access = dir.startAccessingSecurityScopedResource()
                defer { if access { dir.stopAccessingSecurityScopedResource() } }
                let name = item.labels.name
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                    throw TransportError(message: "Renommez le document avant son exportation.")
                }
                try await store.export(item.id, to: dir.appendingPathComponent(name))
            }
        }
    }
}

private struct SharedBytes: Transferable {
    let bytes: Data
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .data) { $0.bytes }.suggestedFileName { $0.name }
    }
}

private struct EditLabels: View {
    let model: LockerModel
    let item: ListedDocument
    @State private var labels: Labels
    @Environment(\.dismiss) private var dismiss
    init(model: LockerModel, item: ListedDocument) {
        self.model = model
        self.item = item
        _labels = State(initialValue: item.labels)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Nom", text: $labels.name)
                HStack {
                    TextField("Dossier", text: $labels.folder)
                    Menu("Choisir un dossier", systemImage: "folder") {
                        Button("Sans dossier") { labels.folder = "" }
                        ForEach(model.library.folders, id: \.self) { name in
                            Button(name) { labels.folder = name }
                        }
                    }.labelStyle(.iconOnly)
                }
                TextField("Catégorie", text: $labels.category)
                TextField("Description", text: $labels.notes, axis: .vertical)
            }.vaultFormStyle().navigationTitle("Fiche du document")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        model.perform { try await $0.change(item.id, labels: labels); dismiss() }
                    }.disabled(labels.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.frame(idealWidth: 460, idealHeight: 380)
    }
}

private struct DocumentPreview: View {
    let data: Data
    let name: String
    private var type: UTType? { UTType(filenameExtension: (name as NSString).pathExtension) }
    var body: some View {
        if type?.conforms(to: .pdf) == true { NativePDF(data: data) }
        else if type?.conforms(to: .image) == true {
            #if os(iOS)
            if let image = UIImage(data: data) { ZoomablePhoto(image: Image(uiImage: image), size: image.size) }
            else { Text("Image illisible.") }
            #else
            if let image = NSImage(data: data) { ZoomablePhoto(image: Image(nsImage: image), size: image.size) }
            else { Text("Image illisible.") }
            #endif
        } else if type?.conforms(to: .text) == true, let value = String(data: data, encoding: .utf8) {
            ScrollView { Text(value).frame(maxWidth: .infinity, alignment: .leading).padding() }
        } else { ContentUnavailableView("Format sans aperçu", systemImage: "doc", description: Text(name)) }
    }
}

#if os(iOS)
private struct NativePDF: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView { pdfView(data) }
    func updateUIView(_ view: PDFView, context: Context) {}
}
#else
private struct NativePDF: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView { pdfView(data) }
    func updateNSView(_ view: PDFView, context: Context) {}
}
#endif

@MainActor private func pdfView(_ data: Data) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.document = PDFDocument(data: data)
    return view
}
