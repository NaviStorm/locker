import SwiftUI

struct IdentityScreen: View {
    let model: LockerModel
    @Environment(\.dismiss) private var dismiss
    @State private var mine: PublicIdentity?
    @State private var card = ""
    @State private var confirmed = false
    @State private var invitation = ""
    @State private var received = ""
    @State private var problem = ""
    private var peer: PublicIdentity? { try? PublicIdentity(card: card) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Identité de cet appareil") {
                    if let mine {
                        Text(mine.fingerprint).font(.system(.caption, design: .monospaced))
                        ShareLink("Envoyer la carte publique", item: mine.card)
                    }
                }
                Section("Vérifier l’autre appareil") {
                    TextField("Carte publique reçue", text: $card, axis: .vertical)
                        .onChange(of: card) { confirmed = false; invitation = "" }
                    if let peer {
                        Text(peer.fingerprint).font(.system(.caption, design: .monospaced))
                        Toggle("Empreinte comparée sur un deuxième canal", isOn: $confirmed)
                    }
                }
                Section("Ajouter mon propre appareil") {
                    Text("Cette autorisation donne le contrôle complet du coffre personnel à votre autre appareil.")
                    Button("Créer l’autorisation chiffrée") {
                        guard let peer else { return }
                        model.perform { invitation = try await $0.inviteOwnDevice(card: peer) }
                    }.disabled(!confirmed || peer == nil)
                    if !invitation.isEmpty { ShareLink("Envoyer l’autorisation", item: invitation) }
                    TextField("Autorisation reçue", text: $received, axis: .vertical)
                    Button("Ouvrir le coffre autorisé") {
                        guard let store = model.store, let peer else { return }
                        Task {
                            do {
                                let code = try await store.acceptOwnDevice(received, from: peer)
                                try store.gate.check()
                                model.lock()
                                model.open(.recover(code), newSlot: true)
                            } catch { problem = error.localizedDescription }
                        }
                    }.disabled(!confirmed || peer == nil || received.isEmpty)
                }
                if !problem.isEmpty { Text(problem) }
            }.vaultFormStyle().navigationTitle("Identités et invitations")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { dismiss() } } }
        }.frame(idealWidth: 560, idealHeight: 540)
        .task {
            guard let store = model.store else { return }
            do { mine = try await store.publicIdentity() } catch { problem = error.localizedDescription }
        }
    }
}
