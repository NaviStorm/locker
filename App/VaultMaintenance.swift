import SwiftUI
import UniformTypeIdentifiers

struct BackupScreen: View {
    let model: LockerModel
    private enum Action { case create, verify, restore }
    @State private var action = Action.create
    @State private var choosing = false
    @State private var code = ""
    @State private var result = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("Copie chiffrée du coffre") {
                Text("La sauvegarde contient les fichiers locaux, leurs versions, les dossiers et la corbeille. Conservez le code de récupération séparément.")
                Button("Créer une sauvegarde…") { pick(.create) }
            }
            Section("Lire une sauvegarde") {
                SecureField("Code de récupération de la sauvegarde", text: $code)
                    .autocorrectionDisabled()
                Button("Tester la restauration…") { pick(.verify) }.disabled(code.isEmpty)
                Button("Restaurer dans ce coffre…") { pick(.restore) }.disabled(code.isEmpty)
                Text("Pour restaurer, ouvrez un coffre personnel vide en mode local. Il conserve son propre code de récupération. Les partages et les comptes de synchronisation restent à configurer.")
                    .font(.footnote)
            }
            if busy { ProgressView("Traitement de la sauvegarde…") }
            if !result.isEmpty { Text(result) }
        }
        .vaultFormStyle().navigationTitle("Sauvegarde et restauration")
        .disabled(busy)
        .fileImporter(isPresented: $choosing, allowedContentTypes: action == .create ? [.folder] : [UTType(exportedAs: "fr.locker.document-backup", conformingTo: .data)]) { selection in
            guard case let .success(url) = selection else {
                if case let .failure(error) = selection, (error as NSError).code != NSUserCancelledError {
                    result = error.localizedDescription
                }
                return
            }
            execute(url)
        }
    }

    private func pick(_ value: Action) {
        model.activity()
        action = value
        result = ""
        choosing = true
    }

    private func execute(_ url: URL) {
        guard let store = model.store else { return }
        let mode = action
        let recovery = code
        code = ""
        busy = true
        model.activity()
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
                busy = false
            }
            do {
                switch mode {
                case .create:
                    let saved = try await store.writeBackup(in: url)
                    result = "Sauvegarde créée : " + saved.lastPathComponent
                case .verify, .restore:
                    let count = try await store.readBackup(url, code: recovery, restore: mode == .restore)
                    guard model.store === store else { return }
                    if mode == .restore { model.library = try await store.library() }
                    result = mode == .restore ? "\(count) éléments restaurés." : "Vérification réussie pour \(count) éléments."
                }
            } catch { result = error.localizedDescription }
        }
    }
}

struct TrashScreen: View {
    let model: LockerModel
    @State private var items: [TrashItem] = []
    @State private var purging: TrashItem?
    @State private var message = ""
    @State private var working = false
    @State private var canModify = false

    var body: some View {
        List {
            if items.isEmpty { Text("La corbeille est vide.").foregroundStyle(.secondary) }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Label(item.name, systemImage: item.isFolder ? "folder" : "doc")
                    Text(item.date.formatted()).font(.caption).foregroundStyle(.secondary)
                    if canModify {
                        HStack {
                            Button("Restaurer") { update(item, purge: false) }
                            Spacer()
                            Button("Supprimer définitivement…", role: .destructive) { purging = item }
                        }.buttonStyle(.borderless)
                    }
                }
            }
            if !message.isEmpty { Text(message) }
        }
        .navigationTitle("Corbeille")
        .disabled(working)
        .task(id: model.syncing) {
            guard let store = model.store else { return }
            do {
                let state = await store.family
                canModify = try state.map { state in
                    guard let role = try state.tip.decoded().member(state.principal)?.role else { return false }
                    return role == .admin || role == .editor
                } ?? true
                items = try await store.trashItems()
            } catch { message = error.localizedDescription }
        }
        .confirmationDialog("Supprimer définitivement cet élément et ses versions ?", isPresented: Binding(
            get: { purging != nil }, set: { if !$0 { purging = nil } }), presenting: purging) { item in
            Button("Supprimer définitivement", role: .destructive) { update(item, purge: true) }
            Button("Annuler", role: .cancel) {}
        }
    }

    private func update(_ item: TrashItem, purge: Bool) {
        guard let store = model.store else { return }
        working = true
        message = ""
        model.activity()
        Task {
            defer { working = false }
            do {
                if purge { try await store.purgeTrash(item) } else { try await store.restoreTrash(item) }
                guard model.store === store else { return }
                items = try await store.trashItems()
                model.library = try await store.library()
                model.sync()
            } catch { message = error.localizedDescription }
        }
    }
}

struct VaultSyncStatus: View {
    let model: LockerModel
    @State private var lastSuccess: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.syncing, let meter = model.store?.syncProgress {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let state = meter.snapshot
                    if let total = state.total, total > 0 {
                        ProgressView(value: Double(state.completed), total: Double(total)) {
                            Text("\(state.title) · \(state.completed) sur \(total)")
                        }
                        if let detail = state.detail { Text(detail) }
                    } else { ProgressView(state.title) }
                }
            } else {
                if !model.syncStatus.isEmpty && !model.syncStatus.hasPrefix("À jour") { Text(model.syncStatus) }
                Text("Modifications locales en attente : \(model.library.pendingCount)")
                if model.library.pendingSharingCount > 0 {
                    Text("Opérations de partage en attente : \(model.library.pendingSharingCount)")
                }
            }
            if let lastSuccess { Text("Dernière synchronisation réussie le \(lastSuccess.formatted()).") }
        }.font(.footnote)
        .task(id: model.syncing) { lastSuccess = try? await model.store?.lastSuccessfulSync() }
    }
}
