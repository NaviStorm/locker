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
    @AppStorage("libraryShowsThumbnails") private var showsThumbnails = false
    @AppStorage("libraryDocumentSortField") private var sortField = DocumentSortField.name
    @AppStorage("libraryDocumentSortAscending") private var sortAscending = true
    @State private var selectingDocuments = false
    @State private var marked = Set<UUID>()
    @State private var moving = false
    #if os(macOS)
    @State private var showSidebar = true
    #endif
    #if os(iOS)
    @State private var familySharing = false
    #endif
    @State private var resumedNearby: NearbyRole?
    @State private var settings = false
    @State private var importer = false
    @State private var versionImporter = false
    @State private var renamingFolder: String?
    @State private var deletingFolder: String?
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
    private var orderedDocuments: [ListedDocument] {
        // The catalogue already supplies documents in ascending name order.
        if sortField == .name && sortAscending { return filtered }
        return sortField.sorted(filtered, ascending: sortAscending)
    }

    private var subfolders: [String] { model.library.subfolders(in: folder) }
    private var showsFolders: Bool {
        query.isEmpty && category.isEmpty && !subfolders.isEmpty
    }

    private func listContents(compact: Bool) -> some View {
        List(selection: compact || selectingDocuments ? nil : $selection) {
            if showsFolders {
                Section("Dossiers") {
                    ForEach(subfolders, id: \.self) { name in
                        HStack(spacing: 8) {
                            Button { folder = name } label: {
                                HStack(spacing: 12) {
                                    VaultGlyph(symbol: "folder.fill")
                                    Text(name.components(separatedBy: "/").last ?? name).font(.body.weight(.medium))
                                    Spacer(minLength: 4)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Menu { folderActions(name) } label: {
                                Label("Actions du dossier « \(name) »", systemImage: "ellipsis.circle")
                                    .labelStyle(.iconOnly)
                            }.menuIndicator(.hidden).fixedSize()
                        }.padding(.vertical, 2)
                        .contextMenu { folderActions(name) }
                    }
                }
            }
            if !filtered.isEmpty {
                Section("Documents") {
                    ForEach(orderedDocuments) { item in
                        if selectingDocuments {
                            markButton(item) { documentRow(item) }
                        } else {
                            documentLink(item, compact: compact)
                                .contextMenu { documentActions(for: item) }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.lockerCanvas)
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    private func documentList(compact: Bool = false) -> some View {
        Group {
            if showsThumbnails { gridContents }
            else { listContents(compact: compact) }
        }
        .overlay {
            if filtered.isEmpty && !showsFolders {
                let searching = !query.isEmpty || !category.isEmpty
                ContentUnavailableView {
                    Label(searching ? "Aucun résultat" : "Aucun document",
                          systemImage: searching ? "magnifyingglass" : "tray")
                } actions: {
                    if searching {
                        Button("Effacer les filtres") { query = ""; category = "" }
                    } else {
                        importButton
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { collectionControls }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectingDocuments {
                Menu {
                    Button("Racine du coffre") { moveMarked(to: "") }.disabled(folder.isEmpty)
                    ForEach(model.library.folders, id: \.self) { target in
                        Button(target) { moveMarked(to: target) }.disabled(target == folder)
                    }
                } label: {
                    Label("Déplacer (\(marked.count))", systemImage: "folder")
                }
                .disabled(marked.isEmpty || moving)
                .padding(8).frame(maxWidth: .infinity).background(.bar)
            }
        }
        .onChange(of: filtered.map(\.id)) { _, ids in marked.formIntersection(ids) }
        .searchable(text: $query, prompt: folder.isEmpty ? "Rechercher à la racine" : "Rechercher dans ce dossier")
        .navigationTitle(folder.isEmpty ? model.vaultTitle : folder)
        .onChange(of: folder) { category = ""; query = ""; marked.removeAll(); selectingDocuments = false }
        .onChange(of: folderDocuments) { previous, current in
            guard let id = selection, !current.contains(where: { $0.id == id }),
                  let old = previous.first(where: { $0.id == id }) else { return }
            selection = current.first { $0.lineage == old.lineage }?.id
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if !folder.isEmpty { parentButton }
                folderButton
            }
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
                    Button("Partage familial", systemImage: "person.2") { familySharing = true }
                    settingsButton
                    lockButton
                } label: { Label("Coffre", systemImage: "lock.shield") }
            }
        }
        #endif
    }

    private var sortMenu: some View {
        Menu {
            Picker("Trier par", selection: $sortField) {
                Text("Nom").tag(DocumentSortField.name)
                Text("Date de la version").tag(DocumentSortField.date)
                Text("Taille").tag(DocumentSortField.size)
            }.pickerStyle(.inline)
            Divider()
            Picker("Ordre", selection: $sortAscending) {
                Text("Croissant").tag(true)
                Text("Décroissant").tag(false)
            }.pickerStyle(.inline)
        } label: {
            Label("Trier les documents", systemImage: "arrow.up.arrow.down")
        }
        .labelStyle(.iconOnly)
        .help("Trier les documents")
    }

    private var collectionControls: some View {
        HStack {
            Picker("Affichage", selection: $showsThumbnails) {
                Label("Liste", systemImage: "list.bullet").tag(false)
                Label("Vignettes", systemImage: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented).labelStyle(.iconOnly).labelsHidden()
            .frame(width: 92)
            #if os(iOS)
            sortMenu
            #endif
            Spacer()
            Button(selectingDocuments ? "Annuler" : "Sélectionner") {
                selection = nil
                marked.removeAll()
                selectingDocuments.toggle()
            }.disabled(moving || (!selectingDocuments && filtered.isEmpty))
        }
        .padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
    }

    private var gridContents: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 115, maximum: 180), spacing: 14)],
                      alignment: .leading, spacing: 16) {
                if showsFolders {
                    ForEach(subfolders, id: \.self) { name in
                        Button { folder = name } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(Color.lockerTint)
                                    .frame(maxWidth: .infinity).frame(height: 90)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                                Text(name.components(separatedBy: "/").last ?? name)
                                    .font(.callout.weight(.medium)).lineLimit(2)
                            }
                        }.contextMenu { folderActions(name) }
                    }
                }
                ForEach(orderedDocuments) { item in
                    let tile = DocumentTile(item: item, store: model.store)
                    if selectingDocuments {
                        markButton(item) { tile }
                    } else {
                        NavigationLink(value: item.id) { tile }
                            .contextMenu { documentActions(for: item) }
                    }
                }
            }.buttonStyle(.plain).padding(14)
        }.background(Color.lockerCanvas)
    }

    private func markButton<Content: View>(_ item: ListedDocument, @ViewBuilder content: () -> Content) -> some View {
        Button {
            if !marked.insert(item.id).inserted { marked.remove(item.id) }
        } label: {
            if showsThumbnails {
                content().overlay(alignment: .topTrailing) { selectionMark(item).padding(5) }
            } else {
                HStack { selectionMark(item); content(); Spacer(minLength: 0) }.contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(marked.contains(item.id) ? .isSelected : [])
        .disabled(moving)
    }

    private func selectionMark(_ item: ListedDocument) -> some View {
        Image(systemName: marked.contains(item.id) ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(Color.lockerTint).background(.background, in: Circle())
            .accessibilityHidden(true)
    }

    private func moveMarked(to destination: String) {
        guard !moving, !marked.isEmpty, model.store != nil else { return }
        let ids = marked
        moving = true
        model.perform { store in
            defer { moving = false }
            try await store.moveDocuments(ids, to: destination)
            marked.removeAll()
            selectingDocuments = false
        }
    }

    private var stackedBrowser: some View {
        NavigationStack(path: Binding(get: { selection.map { [$0] } ?? [] },
                                      set: { selection = $0.last })) {
            documentList(compact: true)
                .navigationDestination(for: UUID.self) { id in
                    if let item = model.documents.first(where: { $0.id == id }) {
                        documentView(item)
                    }
                }
        }
    }

    @ViewBuilder private func documentLink(_ item: ListedDocument, compact: Bool) -> some View {
        #if os(macOS)
        if compact {
            NavigationLink(value: item.id) { documentRow(item) }
        } else {
            documentRow(item).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle()).tag(item.id)
        }
        #else
        NavigationLink(value: item.id) { documentRow(item) }
        #endif
    }

    private func documentRow(_ item: ListedDocument) -> some View {
        HStack(spacing: 12) {
            DocumentGlyph(name: item.labels.name)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.labels.name).font(.body.weight(.medium)).lineLimit(2)
                Text([item.labels.category, item.size.formatted(.byteCount(style: .file))]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }

    private func documentView(_ item: ListedDocument) -> some View {
        DocumentScreen(model: model, item: item, select: selectVersion, addVersion: {
            versionParent = item.id
            versionImporter = true
        }, actions: documentActions(for: item)).id(item.id)
    }

    private var browser: some View {
        #if os(macOS)
        HSplitView {
            if showSidebar {
                documentList()
                    .frame(minWidth: 210, idealWidth: 270, maxWidth: 360)
            }
            detail.frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(showSidebar ? "Masquer la barre latérale" : "Afficher la barre latérale",
                       systemImage: "sidebar.leading") { showSidebar.toggle() }
            }
        }
        #else
        NavigationSplitView { documentList() } detail: { detail }
        #endif
    }

    @ViewBuilder private var detail: some View {
        if let item = selectedDocument {
            documentView(item)
        } else {
            VaultOverview(title: folder.isEmpty ? model.vaultTitle : folder,
                          provider: model.configuration.provider.rawValue,
                          documents: filtered,
                          folderCount: folder.isEmpty ? subfolders.count : nil,
                          open: selectVersion)
        }
    }

    var body: some View {
        browserWithCommands
        .sheet(isPresented: $importer) {
            DocumentImportScreen(model: model, folder: folder)
        }
        .fileImporter(isPresented: $versionImporter, allowedContentTypes: [.item]) { result in
            defer { versionParent = nil }
            switch result {
            case let .success(url):
                guard let versionParent else { return }
                model.importOriginals(SelectedImport([url]), parent: versionParent, folder: folder)
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError { model.problem = error.localizedDescription }
            }
        }
        .onChange(of: model.pendingArchivePlacement?.id, initial: true) { _, _ in
            if let files = model.pendingArchivePlacement {
                folder = ""
                archiveSelection = files
                model.pendingArchivePlacement = nil
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
                let parent = folder
                model.perform { store in
                    folder = try await store.createFolder(name, in: parent)
                    category = ""
                    query = ""
                }
            }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Annuler", role: .cancel) {}
        }
        .alert("Renommer le dossier", isPresented: Binding(get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }), presenting: renamingFolder) { source in
            TextField("Nom du dossier", text: $folderName)
            Button("Renommer") {
                let name = folderName
                model.perform { store in
                    let target = try await store.renameFolder(source, to: name)
                    if folder == source { folder = target }
                }
            }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Annuler", role: .cancel) {}
        }
        .confirmationDialog("Supprimer le dossier « \(deletingFolder ?? "") » ?", isPresented: Binding(
            get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
            titleVisibility: .visible, presenting: deletingFolder) { name in
            Button("Supprimer le dossier et son contenu", role: .destructive) {
                model.perform { store in
                    try await store.deleteFolder(name)
                    if folder == name || folder.hasPrefix(name + "/") { folder = VaultLibrary.parent(of: name); selection = nil }
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: { _ in Text("Les documents, leurs versions et les sous-dossiers de cet emplacement seront supprimés.") }
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
        #if os(iOS)
        .lockerPanel(isPresented: $familySharing) { FamilyScreen(model: model) }
        .sheet(item: $resumedNearby) { role in
            if let store = model.store { NearbyFamilyScreen(model: model, role: role, store: store) }
        }
        #endif
        .sheet(isPresented: Binding(get: { model.recovery != nil }, set: { if !$0 { model.recovery = nil } }), onDismiss: {
            resumedNearby = model.pendingNearbyRole
            model.pendingNearbyRole = nil
        }) {
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
            if model.library.versions(of: item.lineage).count > 1 {
                Text("La suppression concerne uniquement la version sélectionnée.")
            }
        }
    }

    @ViewBuilder private var browserWithCommands: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !folder.isEmpty { parentButton }
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
                sortMenu
                Spacer(minLength: 8)
                settingsButton
                lockButton
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.bar)
            Divider()
            GeometryReader { geometry in
                if showsThumbnails || geometry.size.width < 680 { stackedBrowser }
                else { browser }
            }
        }
        #else
        if showsThumbnails { stackedBrowser } else { browser }
        #endif
    }

    private var folderButton: some View {
        Button("Nouveau dossier", systemImage: "folder.badge.plus") {
            folderName = ""
            creatingFolder = true
        }
        .labelStyle(.iconOnly)
        .help("Nouveau dossier")
    }

    private var parentButton: some View {
        Button("Remonter d’un dossier", systemImage: "chevron.backward") {
            folder = VaultLibrary.parent(of: folder)
        }
        .labelStyle(.iconOnly)
        .help("Remonter d’un dossier")
    }

    @ViewBuilder private func folderActions(_ name: String) -> some View {
        Button("Renommer le dossier…", systemImage: "pencil") {
            folderName = name.components(separatedBy: "/").last ?? name
            renamingFolder = name
        }
        Button("Supprimer le dossier…", systemImage: "trash", role: .destructive) { deletingFolder = name }
    }

    private var importButton: some View {
        Button("Importer un fichier", systemImage: "doc.badge.plus") { importer = true }
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
