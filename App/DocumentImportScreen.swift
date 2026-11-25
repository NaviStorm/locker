import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct DocumentImportScreen: View {
    let model: LockerModel
    let folder: String
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var capture: CaptureSource?
    @State private var selecting = false
    @State private var archivesOnly = false
    @State private var selection: SelectedImport?
    @State private var problem: String?

    var body: some View {
        if let capture, let store = model.store {
            CaptureScreen(source: capture) { result in
                guard model.store === store else { return }
                switch result {
                case let .success(document):
                    model.importCaptured(document.bytes, name: document.name, folder: folder)
                    dismiss()
                case let .failure(error):
                    problem = error.localizedDescription
                    self.capture = nil
                }
            } cancel: { self.capture = nil }
        } else if let selection {
            ArchiveDestinationScreen(model: model, files: selection, folder: folder)
        } else {
            NavigationStack {
                Form {
                    Button("Choisir des fichiers…", systemImage: "doc.badge.plus") {
                        archivesOnly = false
                        selecting = true
                    }
                    PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                        Label("Choisir dans la photothèque…", systemImage: "photo.on.rectangle")
                    }
                    ForEach(CaptureSource.allCases) { source in
                        Button(source.title, systemImage: source.symbol) { capture = source }
                            .disabled(!source.available)
                    }
                    if !CaptureSource.photo.available && !CaptureSource.document.available {
                        Text("La caméra est indisponible sur cet appareil.").font(.footnote)
                    }
                    Button("Décompresser une archive…", systemImage: "archivebox") {
                        archivesOnly = true
                        selecting = true
                    }
                    if photo != nil { ProgressView("Chargement de la photo…") }
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
                .disabled(photo != nil)
                .vaultFormStyle()
                .navigationTitle("Importer un document")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                }
            }
            .frame(idealWidth: 480, idealHeight: 380)
            .task(id: photo) {
                guard let photo, let store = model.store else { return }
                do {
                    guard let image = try await photo.loadTransferable(type: LibraryPhoto.self) else {
                        throw TransportError(message: "Impossible de charger cette photo depuis la photothèque.")
                    }
                    try Task.checkCancellation()
                    guard model.store === store else { return }
                    model.importCaptured(image.bytes, name: image.name, folder: folder)
                    dismiss()
                } catch {
                    guard !Task.isCancelled else { return }
                    problem = error.localizedDescription
                    self.photo = nil
                }
            }
            .fileImporter(isPresented: $selecting,
                          allowedContentTypes: archivesOnly ? Self.archiveTypes : [.item],
                          allowsMultipleSelection: true) { result in
                do {
                    let urls = try result.get()
                    guard !urls.isEmpty else { return }
                    let files = SelectedImport(urls)
                    if archivesOnly && !urls.allSatisfy({ ArchiveKind($0) != nil }) {
                        throw ArchiveIssue.unsupported
                    }
                    if files.containsArchive { selection = files }
                    else {
                        model.importOriginals(files, parent: nil, folder: folder)
                        dismiss()
                    }
                } catch {
                    if (error as NSError).code != NSUserCancelledError { problem = error.localizedDescription }
                }
            }
        }
    }

    private static let archiveTypes = ArchiveKind.allCases.flatMap(\.extensions).compactMap { UTType(filenameExtension: $0) }
}

struct LibraryPhoto: Transferable {
    let bytes: Data
    let name: String

    init(file: URL) throws {
        bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), let ext = type.preferredFilenameExtension else {
            throw TransportError(message: "Le format de cette photo est illisible.")
        }
        let base = file.deletingPathExtension().lastPathComponent
        name = (base.isEmpty ? "Photo" : base) + "." + ext
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try LibraryPhoto(file: received.file)
        }
    }
}
