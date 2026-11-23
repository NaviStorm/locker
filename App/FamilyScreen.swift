import SwiftUI

struct FamilyScreen: View {
    let model: LockerModel
    @Environment(\.dismiss) private var dismiss
    @State private var members: [Member] = []
    @State private var principal = ""
    @State private var mine: PublicIdentity?
    @State private var remoteCard = ""
    @State private var verified = false
    @State private var role = FamilyRole.reader
    @State private var restricted = false
    @State private var chosen = Set<UUID>()
    @State private var email = ""
    @State private var existingAccess = false
    @State private var received = ""
    @State private var issued = ""
    @State private var problem = ""
    @State private var working = false
    @State private var revoke: Member?
    @State private var reencrypt = true
    @State private var rescue = ""
    @State private var kit = ""
    private var peer: PublicIdentity? { try? PublicIdentity(card: remoteCard) }
    private var lineages: [ListedDocument] {
        var seen = Set<UUID>()
        return model.documents.filter { seen.insert($0.lineage).inserted }
    }
    private var isAdmin: Bool { members.contains { $0.card.fingerprint == principal && $0.role == .admin } }

    var body: some View {
        NavigationStack {
            Form {
                if members.isEmpty {
                    Section("Coffre familial") {
                        Button("Créer un coffre familial ici") { run { try await $0.createFamily() } }
                        Text("La création et l’adhésion utilisent un coffre local vide. Chaque participant conserve son propre compte.")
                    }
                } else {
                    Section("Appareils autorisés") {
                        ForEach(members, id: \.card.fingerprint) { member in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(member.card.fingerprint.prefix(16)).font(.system(.body, design: .monospaced))
                                    Text(member.role.rawValue + " · " + (member.documents.map { "\($0.count) document(s)" } ?? "Tout le coffre"))
                                        .font(.caption)
                                }
                                Spacer()
                                if isAdmin, member.card.fingerprint != principal {
                                    Button("Révoquer", role: .destructive) { revoke = member }
                                }
                            }
                        }
                        if isAdmin { Toggle("Rechiffrer les fichiers locaux à la révocation", isOn: $reencrypt) }
                    }
                }
                Section("Carte publique de cet appareil") {
                    if let mine {
                        Text(mine.fingerprint).font(.system(.caption, design: .monospaced))
                        ShareLink("Envoyer ma carte publique", item: mine.card)
                    }
                }
                if isAdmin || members.isEmpty {
                    Section("Vérification sur un second canal") {
                        TextField("Carte publique du correspondant", text: $remoteCard, axis: .vertical)
                            .onChange(of: remoteCard) { verified = false; issued = "" }
                        if let peer {
                            Text(peer.fingerprint).font(.system(.caption, design: .monospaced))
                            Toggle("J’ai comparé cette empreinte avec le correspondant", isOn: $verified)
                        }
                    }
                    if isAdmin {
                        Section("Inviter ou modifier les droits") {
                            Picker("Permission", selection: $role) {
                                ForEach(FamilyRole.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            if role != .admin {
                                Toggle("Limiter à certains documents", isOn: $restricted)
                                if restricted {
                                    ForEach(lineages) { row in
                                        Toggle(row.labels.name, isOn: Binding(get: { chosen.contains(row.lineage) }, set: {
                                            if $0 { chosen.insert(row.lineage) } else { chosen.remove(row.lineage) }
                                        }))
                                    }
                                }
                            }
                            if [.cloud, .dropbox].contains(model.configuration.provider) {
                                Toggle("Le destinataire a déjà accès au dossier ou à la zone", isOn: $existingAccess)
                                if !existingAccess { TextField("Adresse du compte du destinataire", text: $email) }
                            }
                            Button("Autoriser et préparer l’invitation") {
                                guard let peer else { return }
                                run { store in
                                    let scope = restricted && role != .admin ? chosen : nil
                                    try await store.changeMembership(card: peer, role: role, scope: scope)
                                    if existingAccess { issued = try await store.familyTicket(for: peer) }
                                    else { issued = try await store.issueTicket(to: peer, email: email) }
                                }
                            }.disabled(!verified || peer == nil || (restricted && role != .admin && chosen.isEmpty))
                            if !issued.isEmpty { ShareLink("Transmettre l’invitation chiffrée", item: issued) }
                        }
                    } else if members.isEmpty {
                        Section("Rejoindre un coffre familial") {
                            TextField("Invitation chiffrée", text: $received, axis: .vertical)
                            Button("Accepter l’invitation") {
                                guard let peer else { return }
                                run { try await $0.joinFamily(received, from: peer) }
                            }.disabled(!verified || peer == nil || received.isEmpty)
                        }
                    }
                }
                Section("Secours du propriétaire") {
                    if isAdmin {
                        Button("Préparer le kit de secours chiffré") { run { kit = try await $0.makeRescueKit() } }
                        if !kit.isEmpty { ShareLink("Conserver le kit de secours", item: kit) }
                    } else if members.isEmpty {
                        TextField("Kit associé au code de récupération", text: $rescue, axis: .vertical)
                        Button("Restaurer mon autorité de secours") { run { try await $0.restoreRescueKit(rescue) } }
                            .disabled(rescue.isEmpty)
                    }
                }
                if !problem.isEmpty { Text(problem).foregroundStyle(.red) }
                if working { ProgressView() }
            }
            .formStyle(.grouped).navigationTitle("Partage familial")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { dismiss() } } }
            .disabled(working)
            .confirmationDialog("Retirer l’autorisation de cet appareil ?", isPresented: Binding(get: { revoke != nil },
                set: { if !$0 { revoke = nil } }), presenting: revoke) { member in
                Button("Révoquer", role: .destructive) {
                    run { try await $0.revokeMember(member.card, reencrypt: reencrypt) }
                }
            }
        }.frame(idealWidth: 570, idealHeight: 600)
        .task { if let store = model.store { do { try await refresh(store) } catch { problem = error.localizedDescription } } }
    }

    private func refresh(_ store: VaultStore) async throws {
        mine = try await store.publicIdentity()
        principal = await store.family?.principal ?? ""
        members = try await store.members()
        model.familyMode = !members.isEmpty
    }

    private func run(_ operation: @escaping (VaultStore) async throws -> Void) {
        guard !working, let store = model.store else { return }
        working = true
        problem = ""
        Task {
            defer { working = false }
            do {
                try await operation(store)
                try await refresh(store)
                model.documents = try await store.list()
                model.sync()
            } catch {
                try? await refresh(store)
                problem = error.localizedDescription
            }
        }
    }
}
