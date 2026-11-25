import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class BackupOperation {
    enum Action { case create, verify, restore }
    enum Status: Equatable {
        case idle, working(String), success(String), failure(String)
    }
    var status = Status.idle
    var busy: Bool {
        if case .working = status { return true }
        return false
    }

    func handle(_ selection: Result<URL, Error>, action: Action, code: String, model: LockerModel) async {
        guard !busy else { return }
        guard let store = model.store else { status = .failure(VaultError.locked.localizedDescription); return }
        defer { if model.store !== store { status = .idle } }
        do {
            let url = try selection.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            model.activity()
            switch action {
            case .create:
                status = .working("Création de la sauvegarde…")
                let saved = try await store.writeBackup(in: url)
                guard model.store === store else { return }
                status = .success("Sauvegarde créée • " + saved.lastPathComponent)
            case .verify, .restore:
                let restoring = action == .restore
                status = .working(restoring ? "Restauration en cours…" : "Vérification de la sauvegarde…")
                let count = try await store.readBackup(url, code: code, restore: restoring)
                guard model.store === store else { return }
                let total = count == 1 ? "1 élément" : "\(count) éléments"
                if restoring {
                    let library = try await store.library()
                    guard model.store === store else { return }
                    model.library = library
                    status = .success("Restauration terminée • " + total)
                } else {
                    status = .success("Sauvegarde vérifiée • " + total)
                }
            }
        } catch {
            guard model.store === store else { return }
            let failure = error as NSError
            status = failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError
                ? .idle : .failure(error.localizedDescription)
        }
    }
}

struct BackupScreen: View {
    let model: LockerModel
    @State var operation = BackupOperation()
    @State private var action = BackupOperation.Action.create
    @State private var choosing = false
    @State private var code = ""
    @FocusState private var enteringCode: Bool

    var body: some View {
        Form {
            Section("Copie chiffrée du coffre") {
                Text("La sauvegarde contient les fichiers locaux, leurs versions, les dossiers et la corbeille. Conservez le code de récupération séparément.")
                Button("Créer une sauvegarde…") { pick(.create) }
            }
            Section("Lire une sauvegarde") {
                SecureField("Code de récupération de la sauvegarde", text: $code)
                    .autocorrectionDisabled()
                    .focused($enteringCode)
                Button("Tester la restauration…") { pick(.verify) }.disabled(code.isEmpty)
                Button("Restaurer dans ce coffre…") { pick(.restore) }.disabled(code.isEmpty)
                Text("Pour restaurer, ouvrez un coffre personnel vide en mode local. Il conserve son propre code de récupération. Les partages et les comptes de synchronisation restent à configurer.")
                    .font(.footnote)
            }
        }
        .vaultFormStyle().navigationTitle("Sauvegarde et restauration")
        .disabled(operation.busy)
        .safeAreaInset(edge: .top, spacing: 0) {
            if operation.status != .idle {
                Group {
                    switch operation.status {
                    case .idle: EmptyView()
                    case let .working(message): ProgressView(message)
                    case let .success(message): Label(message, systemImage: "checkmark.circle.fill")
                    case let .failure(message): Label(message, systemImage: "exclamationmark.triangle.fill")
                    }
                }
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: action == .create ? [.folder] : [UTType(exportedAs: "fr.locker.document-backup", conformingTo: .data)]) { selection in
            let mode = action
            let recovery = code
            if case .success = selection { code = "" }
            Task { await operation.handle(selection, action: mode, code: recovery, model: model) }
        }
    }

    private func pick(_ value: BackupOperation.Action) {
        enteringCode = false
        model.activity()
        action = value
        operation.status = .idle
        choosing = true
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
