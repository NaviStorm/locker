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
    @State private var archiveSelection: SelectedImport?
    @State private var scanner = false
    @State private var versionParent: UUID?
    @State private var pendingRename: ListedDocument?
    @State private var documentName = ""
    @State private var pendingDelete: ListedDocument?

    private var folderDocuments: [ListedDocument] { model.library.documents(in: folder) }
    private var selectedDocument: ListedDocument? { folderDocuments.first { $0.id == selection } }

    private var filtered: [ListedDocument] {
        folderDocuments.filter { row in
            let labels = row.labels
            return (category.isEmpty || category == labels.category)
                && (query.isEmpty || [labels.name, labels.category, labels.folder, labels.notes]
                    .contains { $0.localizedStandardContains(query) })
        }
    }
    private var showsFolders: Bool {
        folder.isEmpty && query.isEmpty && category.isEmpty && !model.library.folders.isEmpty
    }

    private var browser: some View {
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
                    .contextMenu { documentActions(for: item) }
                }
            }
            .overlay {
                if filtered.isEmpty && !showsFolders {
                    ContentUnavailableView(query.isEmpty ? "Aucun document" : "Aucun résultat",
                                           systemImage: query.isEmpty ? "folder" : "magnifyingglass")
                }
            }
            .searchable(text: $query, prompt: folder.isEmpty ? "Rechercher à la racine" : "Rechercher dans ce dossier")
            .navigationTitle(folder.isEmpty ? model.vaultTitle : folder)
            .onChange(of: folder) { category = ""; query = "" }
            .onChange(of: selectedDocument?.id) { _, id in
                if id == nil { selection = nil }
            }
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: folder.isEmpty ? .navigation : .automatic) { folderButton }
                ToolbarItemGroup {
                    Menu {
                        importButton
                        if ScanScreen.supported {
                            Button("Numériser", systemImage: "document.viewfinder") { scanner = true }
                        }
                    } label: { Label("Ajouter", systemImage: "plus") }
                    Menu {
                        folderPicker
                        categoryPicker
                    } label: { Label("Filtrer", systemImage: "line.3.horizontal.decrease") }
                    Menu {
                        settingsButton
                        lockButton
                    } label: { Label("Coffre", systemImage: "lock.shield") }
                }
            }
            #endif
        } detail: {
            if let item = selectedDocument {
                DocumentScreen(model: model, item: item, select: selectVersion, addVersion: {
                    versionParent = item.id
                    importer = true
                }, actions: documentActions(for: item)).id(item.id)
            } else {
                ContentUnavailableView("Sélectionnez un document", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    var body: some View {
        browserWithCommands
        .fileImporter(isPresented: $importer, allowedContentTypes: [.item], allowsMultipleSelection: versionParent == nil) { result in
            switch result {
            case let .success(urls):
                let files = SelectedImport(urls)
                if versionParent == nil && files.containsArchive {
                    archiveSelection = files
                } else {
                    model.importOriginals(files, parent: versionParent, folder: folder)
                }
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError { model.problem = error.localizedDescription }
            }
        }
        .sheet(item: $archiveSelection) { files in
            ArchiveDestinationScreen(model: model, files: files, folder: folder)
        }
        .overlay(alignment: .bottom) {
            if model.extracting {
                ProgressView("Décompression…").padding().background(.regularMaterial, in: Capsule())
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
        .alert("Renommer le document", isPresented: Binding(get: { pendingRename != nil },
            set: { if !$0 { pendingRename = nil } }), presenting: pendingRename) { item in
            TextField("Nom du fichier", text: $documentName)
            Button("Renommer") {
                let name = documentName
                model.perform { try await $0.renameDocument(item.id, to: name) }
            }.disabled(documentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Annuler", role: .cancel) {}
        }
        .confirmationDialog("Supprimer « \(pendingDelete?.labels.name ?? "") » ?", isPresented: Binding(get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { item in
            Button("Supprimer", role: .destructive) {
                model.perform { store in
                    try await store.change(item.id, labels: nil)
                    if selection == item.id { selection = nil }
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: { item in
            if model.documents.contains(where: { $0.lineage == item.lineage && $0.id != item.id }) {
                Text("La suppression concerne uniquement la version sélectionnée.")
            }
        }
    }

    @ViewBuilder private var browserWithCommands: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                folderButton
                importButton
                Button("Photographier un document", systemImage: "camera") { scanner = true }
                    .help("Photographier un document")
                Divider()
                Menu {
                    folderPicker.pickerStyle(.inline)
                } label: { Label("Choisir un dossier", systemImage: "folder") }
                .help("Choisir un dossier")
                Menu {
                    categoryPicker.pickerStyle(.inline)
                } label: { Label("Filtrer par catégorie", systemImage: "line.3.horizontal.decrease") }
                .help(category.isEmpty ? "Filtrer par catégorie" : "Catégorie : \(category)")
                Spacer(minLength: 8)
                settingsButton
                lockButton
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            browser
        }
        #else
        browser
        #endif
    }

    @ViewBuilder private var folderButton: some View {
        if folder.isEmpty {
            Button("Nouveau dossier", systemImage: "folder.badge.plus") {
                folderName = ""
                creatingFolder = true
            }
            .labelStyle(.iconOnly)
            .help("Nouveau dossier")
        } else {
            Button("Retour au coffre", systemImage: "chevron.backward") { folder = "" }
                .help("Retour au coffre")
        }
    }

    private var importButton: some View {
        Button("Importer un fichier", systemImage: "doc.badge.plus") { versionParent = nil; importer = true }
            .help("Importer un fichier")
            .disabled(model.extracting)
    }

    private var settingsButton: some View {
        Button("Réglages du coffre", systemImage: "gearshape") { settings = true }
            .help("Réglages du coffre")
    }

    private var lockButton: some View {
        Button("Verrouiller", systemImage: "lock") { model.lock() }
            .help("Verrouiller le coffre")
    }

    private var folderPicker: some View {
        Picker("Dossier", selection: $folder) {
            Text("Racine du coffre").tag("")
            ForEach(model.library.folders, id: \.self) { Text($0).tag($0) }
        }
    }

    private var categoryPicker: some View {
        Picker("Catégorie", selection: $category) {
            Text("Toutes les catégories").tag("")
            ForEach(Array(Set(folderDocuments.map(\.labels.category))).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
        }
    }

    @ViewBuilder private func documentActions(for item: ListedDocument) -> some View {
        Button("Renommer…", systemImage: "pencil") {
            documentName = item.labels.name
            pendingRename = item
        }
        Menu("Déplacer vers", systemImage: "folder") {
            Button("Racine du coffre") { move(item, to: "") }.disabled(item.labels.folder.isEmpty)
            ForEach(model.library.folders, id: \.self) { destination in
                Button(destination) { move(item, to: destination) }.disabled(destination == item.labels.folder)
            }
        }
        Button("Supprimer…", systemImage: "trash", role: .destructive) { pendingDelete = item }
    }

    private func selectVersion(_ id: UUID) {
        guard let version = model.documents.first(where: { $0.id == id }) else { return }
        folder = version.labels.folder
        selection = id
    }

    private func move(_ item: ListedDocument, to destination: String) {
        model.perform { store in
            try await store.moveDocument(item.id, to: destination)
            if selection == item.id && folder != destination { selection = nil }
        }
    }
}
