import CryptoKit
import SwiftUI

@MainActor
enum ShareRecipient {
    static let credential = ProviderCredential(account: "incoming-v1", serviceSuffix: ".share-recipient")

    static func prepare(_ inbox: ShareInbox) throws {
        if try !credential.exists() {
            try credential.save(Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        }
        let publicKey = try privateKey().publicKey.rawRepresentation
        if (try? Data(contentsOf: inbox.recipient)) != publicKey {
            try publicKey.write(to: inbox.recipient, options: .atomic)
        }
    }

    static func privateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try .init(rawRepresentation: credential.read())
    }
}

extension VaultStore {
    @discardableResult
    func receive(_ id: UUID, from inbox: ShareInbox, privateKey: Curve25519.KeyAgreement.PrivateKey,
                 folder: String, choices: ImportChoices = [:]) throws -> UUID? {
        try gate.check()
        var open: UUID?
        if importedShares?.contains(id) != true {
            let (items, key) = try inbox.open(id, privateKey: privateKey)
            guard try folder.isEmpty || library().folders.contains(folder) else { throw VaultError.changed }
            var staged = [Entry]()
            do {
                for item in items {
                    var index = 0
                    let entry = try stageDocument(name: item.name, folder: folder) {
                        guard index < item.chunks else { return Data() }
                        let bytes = try Data(contentsOf: item.url(in: inbox.directory(id), at: index))
                        let clear = try AES.GCM.open(.init(combined: bytes), using: key, authenticating: item.context(index))
                        index += 1
                        return clear
                    }
                    staged.append(entry)
                }
                open = try publishImports(staged, choices: choices, share: id)
            } catch {
                for entry in staged { try? FileManager.default.removeItem(at: blob(entry.id)) }
                throw error
            }
        }
        try FileManager.default.removeItem(at: inbox.directory(id))
        return open
    }
}

struct IncomingShares: View {
    let model: LockerModel
    @Environment(\.scenePhase) private var phase
    @State private var batches = [UUID]()
    @State private var folder = ""
    @State private var selectedBatch: UUID?
    @State private var reviewing = false
    @State private var names = [String]()

    var body: some View {
        Group {
            if !batches.isEmpty {
                if model.store != nil {
                    Button("Importer les éléments partagés", systemImage: "square.and.arrow.down") {
                        do {
                            guard let id = batches.first else { return }
                            names = try ShareInbox.local().open(id, privateKey: ShareRecipient.privateKey()).0.map(\.name)
                            selectedBatch = id
                            folder = ""
                            reviewing = true
                        } catch { model.problem = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).padding(8)
                } else {
                    Text("Partage reçu · Ouvrez le coffre de destination.").padding(8)
                }
            }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            do {
                let inbox = try ShareInbox.local()
                try ShareRecipient.prepare(inbox)
                while !Task.isCancelled {
                    batches = try inbox.pending()
                    try await Task.sleep(for: .seconds(3))
                }
            } catch is CancellationError {
            } catch {
                // Local vaults remain accessible if the optional inbox is unavailable.
                if !batches.isEmpty { model.problem = error.localizedDescription }
            }
        }
        .onChange(of: model.store == nil) { _, locked in
            if locked { reviewing = false; names = [] }
        }
        .sheet(isPresented: $reviewing, onDismiss: { names = [] }) {
            NavigationStack {
                Form {
                    Section(model.vaultTitle) {
                        Picker("Destination", selection: $folder) {
                            Text("Racine du coffre").tag("")
                            ForEach(model.library.folders, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Section("Éléments reçus") {
                        ForEach(names.indices, id: \.self) { Text(names[$0]) }
                    }
                }
                .vaultFormStyle()
                .navigationTitle("Importer le partage")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { reviewing = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Importer") { importBatch() }.disabled(model.reviewingImport)
                    }
                }
            }.frame(idealWidth: 450, idealHeight: 340)
        }
    }

    private func importBatch() {
        guard !model.reviewingImport, let id = selectedBatch, let store = model.store else { return }
        do {
            let inbox = try ShareInbox.local()
            let key = try ShareRecipient.privateKey()
            let destination = folder
            reviewing = false
            model.reviewImport { session, choices in
                guard session === store else { throw VaultError.changed }
                return try await session.receive(id, from: inbox, privateKey: key, folder: destination, choices: choices)
            }
        } catch { model.problem = error.localizedDescription }
    }
}
