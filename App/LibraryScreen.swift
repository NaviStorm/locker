import SwiftUI
import UniformTypeIdentifiers

struct LibraryScreen: View {
    @Bindable var model: LockerModel
    @State private var query = ""
    @State private var folder = ""
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var category = ""
    @State private var selection: UUID?
    @State private var settings = false
    @State private var importer = false
    @State private var scanner = false
    @State private var versionParent: UUID?
    @State private var pendingDelete: ListedDocument?

    private var filtered: [ListedDocument] {
        model.documents.filter { row in
            let labels = row.labels
            return (folder.isEmpty || folder == labels.folder) && (category.isEmpty || category == labels.category)
                && (query.isEmpty || [labels.name, labels.category, labels.folder, labels.notes]
                    .contains { $0.localizedStandardContains(query) })
        }
    }
    private var showsFolders: Bool {
        folder.isEmpty && query.isEmpty && category.isEmpty && !model.library.folders.isEmpty
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if showsFolders {
                    Section("Dossiers") {
                        ForEach(model.library.folders, id: \.self) { name in
                            Button { folder = name } label: { Label(name, systemImage: "folder") }
                        }
                    }
                }
                ForEach(filtered) { item in
                    NavigationLink(value: item.id) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.labels.name).lineLimit(2)
                                Text([item.labels.folder, item.labels.category,
                                      ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "doc.text").foregroundStyle(.tint) }
                    }
                }
            }
            .overlay {
                if filtered.isEmpty && !showsFolders {
                    ContentUnavailableView(query.isEmpty ? "Aucun document" : "Aucun résultat",
                                           systemImage: query.isEmpty ? "folder" : "magnifyingglass")
                }
            }
            .searchable(text: $query, prompt: "Rechercher dans le coffre")
            .navigationTitle(folder.isEmpty ? model.vaultTitle : folder)
            .onChange(of: folder) { selection = nil }
            .toolbar {
                ToolbarItemGroup {
                    if !folder.isEmpty {
                        Button("Retour au coffre", systemImage: "chevron.backward") { folder = "" }
                    }
                    Menu {
                        if folder.isEmpty {
                            Button("Nouveau dossier", systemImage: "folder.badge.plus") {
                                folderName = ""
                                creatingFolder = true
                            }
                        }
                        Button("Importer un fichier", systemImage: "doc.badge.plus") { versionParent = nil; importer = true }
                        #if os(iOS)
                        if ScanScreen.supported { Button("Numériser", systemImage: "document.viewfinder") { scanner = true } }
                        #else
                        Button("Photographier un document", systemImage: "camera") { scanner = true }
                        #endif
                    } label: { Label("Ajouter", systemImage: "plus") }
                    Menu {
                        Picker("Dossier", selection: $folder) {
                            Text("Tous les dossiers").tag("")
                            ForEach(model.library.folders, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("Catégorie", selection: $category) {
                            Text("Toutes les catégories").tag("")
                            ForEach(Array(Set(model.documents.map(\.labels.category))).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                        }
                    } label: { Label("Filtrer", systemImage: "line.3.horizontal.decrease") }
                    Menu {
                        Button("Réglages du coffre", systemImage: "gearshape") { settings = true }
                        Button("Verrouiller", systemImage: "lock") { model.lock() }
                    } label: { Label("Coffre", systemImage: "lock.shield") }
                }
            }
        } detail: {
            if let item = model.documents.first(where: { $0.id == selection }) {
                DocumentScreen(model: model, item: item, select: { selection = $0 }, addVersion: {
                    versionParent = item.id
                    importer = true
                }, remove: { pendingDelete = item }).id(item.id)
            } else {
                ContentUnavailableView("Sélectionnez un document", systemImage: "doc.text.magnifyingglass")
            }
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.item], allowsMultipleSelection: versionParent == nil) { result in
            switch result {
            case let .success(urls):
                let parent = versionParent
                let destination = folder
                model.perform { store in
                    for url in urls {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        _ = try await store.importCoordinated(url, parent: parent, folder: destination)
                    }
                }
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError { model.problem = error.localizedDescription }
            }
        }
        .alert("Nouveau dossier", isPresented: $creatingFolder) {
            TextField("Nom du dossier", text: $folderName)
            Button("Créer") {
                let name = folderName
                model.perform { store in
                    folder = try await store.createFolder(name)
                    category = ""
                    query = ""
                }
            }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Annuler", role: .cancel) {}
        }
        .lockerPanel(isPresented: $settings) { SettingsScreen(model: model) }
        .sheet(isPresented: $scanner) {
            ScanScreen { result in
                scanner = false
                switch result {
                case let .success(scan): model.perform { _ = try await $0.importData(scan.bytes, name: scan.name, folder: folder) }
                case let .failure(error): model.problem = error.localizedDescription
                }
            } cancel: { scanner = false }
        }
        .sheet(isPresented: Binding(get: { model.recovery != nil }, set: { if !$0 { model.recovery = nil } })) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Code de récupération", systemImage: "key").font(.title2.bold())
                Text("Recopiez ce code et conservez-le en lieu sûr. Il donne accès aux copies chiffrées de ce coffre.")
                Text(model.recovery ?? "").font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                Button("J’ai conservé le code") { model.recovery = nil }.buttonStyle(.borderedProminent)
            }.padding(28).frame(idealWidth: 430)
        }
        .confirmationDialog("Supprimer cette version du coffre ?", isPresented: Binding(get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { item in
            Button("Supprimer", role: .destructive) {
                selection = nil
                model.perform { try await $0.change(item.id, labels: nil) }
            }
        }
    }
}
