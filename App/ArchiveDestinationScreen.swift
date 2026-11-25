import SwiftUI

// Hold the picker grants across the destination sheet and any authentication prompt.
final class SelectedImport: Identifiable {
    let urls: [URL]
    private let granted: [URL]
    var containsArchive: Bool { urls.contains { ArchiveKind($0) != nil } }

    init(_ urls: [URL]) {
        self.urls = urls
        granted = urls.filter { $0.startAccessingSecurityScopedResource() }
    }

    deinit { for url in granted { url.stopAccessingSecurityScopedResource() } }
}

enum ArchiveDestination: Hashable {
    case existing(String)
    case new
}

struct ArchiveDestinationScreen: View {
    let model: LockerModel
    let files: SelectedImport
    @State private var folder: String
    @Environment(\.dismiss) private var dismiss
    @State private var destination: ArchiveDestination
    @State private var secret = ""
    @State private var protectNewKey = true

    init(model: LockerModel, files: SelectedImport, folder: String) {
        self.model = model
        self.files = files
        _folder = State(initialValue: model.library.folders.contains(folder) ? folder : "")
        _destination = State(initialValue: .existing(model.slot))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sélection") {
                    ForEach(Array(files.urls.enumerated()), id: \.offset) { _, url in
                        Text(url.lastPathComponent)
                    }
                }
                Section {
                    Picker("Coffre de destination", selection: $destination) {
                        ForEach(model.slots, id: \.self) { slot in
                            Text(model.pickerTitle(for: slot)).tag(ArchiveDestination.existing(slot))
                        }
                        Text("Nouveau coffre").tag(ArchiveDestination.new)
                    }
                    if destination == .new {
                        Toggle("Exiger une authentification pour le nouveau coffre", isOn: $protectNewKey)
                    }
                }

                if destination == .existing(model.slot) || destination == .new {
                    Section("Emplacement") {
                        if destination == .new {
                            Label("Racine du coffre", systemImage: "folder")
                        } else {
                            Picker("Dossier de destination", selection: $folder) {
                                Text("Racine du coffre").tag("")
                                ForEach(model.library.folders, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                        }
                    }
                    Button("Décompresser ici", systemImage: "archivebox") { finish(extract: true) }
                    Button("Importer sans décompresser", systemImage: "doc.badge.plus") { finish(extract: false) }
                } else if case let .existing(id) = destination {
                    let method = LockerModel.method(for: id)
                    if method.isCustom { VaultSecretField(title: method.secretTitle, method: method, text: $secret) }
                    Button("Ouvrir ce coffre pour choisir l’emplacement") {
                        dismiss()
                        model.chooseArchiveFolder(files, in: id, secret: secret)
                        secret = ""
                    }.disabled(method.isCustom && secret.isEmpty)
                }
            }
            .vaultFormStyle()
            .navigationTitle("Importer une archive")
            .onChange(of: destination) { secret = "" }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } } }
        }.frame(idealWidth: 480, idealHeight: 420)
    }
    private func finish(extract: Bool) {
        dismiss()
        model.importArchive(files, inNewVault: destination == .new, folder: folder,
                            extract: extract, protectNewKey: protectNewKey)
    }

}

extension LockerModel {
    func importOriginals(_ files: SelectedImport, parent: UUID?, folder: String) {
        perform { store in
            defer { withExtendedLifetime(files) {} }
            for url in files.urls { _ = try await store.importCoordinated(url, parent: parent, folder: folder) }
        }
    }

    func chooseArchiveFolder(_ files: SelectedImport, in id: String, secret: String = "") {
        guard store != nil, !extracting else { return }
        guard slots.contains(id) else {
            problem = "Le coffre de destination est indisponible."
            return
        }
        lock()
        slot = id
        open(authenticationMethod.isCustom ? .unlockWithSecret(secret) : .unlock) { self.pendingArchivePlacement = files }
    }

    func importArchive(_ files: SelectedImport, inNewVault: Bool, folder: String, extract: Bool,
                       protectNewKey: Bool = true) {
        guard store != nil, !extracting else { return }
        let target = inNewVault ? "" : folder
        guard target.isEmpty || library.folders.contains(target) else {
            problem = "Le dossier de destination est indisponible."
            return
        }
        let placeFiles = {
            if extract { self.extractHere(files, folder: target) }
            else { self.importOriginals(files, parent: nil, folder: target) }
        }
        if inNewVault {
            lock()
            open(.create, newSlot: true, protectNewKey: protectNewKey, afterOpen: placeFiles)
        } else { placeFiles() }
    }

    private func extractHere(_ files: SelectedImport, folder: String) {
        extracting = true
        perform { store in
            defer {
                withExtendedLifetime(files) {}
                if self.store === store { self.extracting = false }
            }
            try await store.extractSelection(files.urls, folder: folder)
        }
    }
}
