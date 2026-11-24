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
    let folder: String
    @Environment(\.dismiss) private var dismiss
    @State private var destination: ArchiveDestination
    @State private var method: VaultAuthenticationMethod
    @State private var protectNewKey = true

    init(model: LockerModel, files: SelectedImport, folder: String) {
        self.model = model
        self.files = files
        self.folder = folder
        _method = State(initialValue: model.authenticationMethod)
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
                            Text(model.vaultNames[slot] ?? ("Coffre " + slot.prefix(8))).tag(ArchiveDestination.existing(slot))
                        }
                        Text("Nouveau coffre").tag(ArchiveDestination.new)
                    }
                    .onChange(of: destination) { _, target in
                        if case .existing(let slot) = target { method = .preferred(for: slot) }
                        else { method = model.authenticationMethod }
                    }
                    if destination == .new {
                        Toggle("Exiger une authentification pour le nouveau coffre", isOn: $protectNewKey)
                    }
                    if destination != .existing(model.slot) && (destination != .new || protectNewKey) {
                        AuthenticationMethodPicker(selection: $method)
                    }
                } footer: {
                    if destination == .existing(model.slot) && !folder.isEmpty {
                        Text("Dossier de destination : \(folder)")
                    } else { Text("Les fichiers seront importés à la racine du coffre choisi et dans les dossiers de l’archive.") }
                }
                Button("Décompresser dans ce coffre") {
                    dismiss()
                    model.extract(files, to: destination, folder: folder, protectNewKey: protectNewKey, method: method)
                }
                Button("Importer sans décompresser dans le coffre ouvert") {
                    dismiss()
                    model.importOriginals(files, parent: nil, folder: folder)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Importer une archive")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } } }
        }.frame(idealWidth: 480, idealHeight: 420)
    }
}

extension LockerModel {
    func importOriginals(_ files: SelectedImport, parent: UUID?, folder: String) {
        perform { store in
            defer { withExtendedLifetime(files) {} }
            for url in files.urls { _ = try await store.importCoordinated(url, parent: parent, folder: folder) }
        }
    }

    func extract(_ files: SelectedImport, to destination: ArchiveDestination, folder: String, protectNewKey: Bool = true,
                 method: VaultAuthenticationMethod? = nil) {
        guard store != nil, !extracting else { return }
        if destination == .existing(slot) {
            extractHere(files, folder: folder)
            return
        }
        if case let .existing(id) = destination, !slots.contains(id) {
            problem = "Le coffre de destination est indisponible."
            return
        }
        lock()
        let afterOpen = { self.extractHere(files, folder: "") }
        switch destination {
        case let .existing(id):
            slot = id
            open(.unlock, using: method, afterOpen: afterOpen)
        case .new:
            open(.create, newSlot: true, protectNewKey: protectNewKey, using: method, afterOpen: afterOpen)
        }
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
