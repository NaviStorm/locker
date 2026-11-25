import SwiftUI
import UniformTypeIdentifiers

struct DocumentImportScreen: View {
    let model: LockerModel
    let folder: String
    @Environment(\.dismiss) private var dismiss
    @State private var selecting = false
    @State private var archivesOnly = false
    @State private var selection: SelectedImport?
    @State private var problem: String?

    var body: some View {
        if let selection {
            ArchiveDestinationScreen(model: model, files: selection, folder: folder)
        } else {
            NavigationStack {
                Form {
                    Button("Choisir des fichiers…", systemImage: "doc.badge.plus") {
                        archivesOnly = false
                        selecting = true
                    }
                    Button("Décompresser une archive…", systemImage: "archivebox") {
                        archivesOnly = true
                        selecting = true
                    }
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
                .vaultFormStyle()
                .navigationTitle("Importer un document")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                }
            }
            .frame(idealWidth: 480, idealHeight: 320)
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
