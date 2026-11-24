import SwiftUI

struct FamilyScreen: View {
    let model: LockerModel
    @State private var members: [Member] = []
    @State private var principal = ""
    @State private var mine: PublicIdentity?
    @State private var verification = FamilyPeerVerification()
    @State private var verificationProblem: String?
    @State private var role = FamilyRole.reader
    @State private var restricted = false
    @State private var chosen = Set<UUID>()
    @State private var email = ""
    @State private var existingAccess = false
    @State private var joinDraft = FamilyJoinDraft()
    @State private var savedDraft: FamilyJoinDraft?
    @State private var justJoined = false
    @State private var issued = ""
    @State private var problem = ""
    @State private var working = false
    @State private var revoke: Member?
    @State private var reencrypt = true
    @State private var rescue = ""
    @State private var kit = ""
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
                        if justJoined { Label("Invitation acceptée. Ce coffre est maintenant partagé.", systemImage: "checkmark.circle") }
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
                if isAdmin {
                    Section("Vérification sur un second canal") {
                        TextField("Carte publique du correspondant", text: verificationBinding(\.card), axis: .vertical)
                            .autocorrectionDisabled()
                        if let peer = verification.peer {
                            Text(peer.fingerprint).font(.system(.caption, design: .monospaced))
                            Toggle("J’ai comparé cette empreinte avec le correspondant", isOn: verificationBinding(\.isConfirmed))
                        }
                        if let verificationProblem { Text(verificationProblem).foregroundStyle(.red) }
                        else if verification.isConfirmed {
                            Text("Vérification mémorisée dans ce coffre sur cet appareil.").font(.footnote)
                        }
                    }
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
                            guard verificationProblem == nil, verification.isConfirmed, let peer = verification.peer else { return }
                            run { store in
                                let scope = restricted && role != .admin ? chosen : nil
                                try await store.changeMembership(card: peer, role: role, scope: scope)
                                if existingAccess { issued = try await store.familyTicket(for: peer) }
                                else { issued = try await store.issueTicket(to: peer, email: email) }
                            }
                        }.disabled(verificationProblem != nil || !verification.isConfirmed || (restricted && role != .admin && chosen.isEmpty))
                        if !issued.isEmpty { ShareLink("Transmettre l’invitation chiffrée", item: issued) }
                    }
                } else if members.isEmpty {
                    Section("Rejoindre un coffre familial") {
                        TextField("Invitation chiffrée", text: $joinDraft.ticket, axis: .vertical)
                            .lineLimit(1...4).autocorrectionDisabled()
                        TextField("Carte publique du propriétaire", text: $joinDraft.card, axis: .vertical)
                            .lineLimit(1...3).autocorrectionDisabled()
                        if let owner = joinDraft.owner {
                            Text(owner.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Toggle("J’ai comparé cette empreinte avec le propriétaire", isOn: $joinDraft.fingerprintConfirmed)
                        }
                        if let hint = joinDraft.nextStep { Text(hint).font(.footnote) }
                        Button("Accepter l’invitation") {
                            guard let owner = joinDraft.owner, joinDraft.nextStep == nil else { return }
                            let ticket = joinDraft.ticket
                            run { store in
                                try await store.joinFamily(ticket, from: owner)
                                joinDraft = FamilyJoinDraft()
                                savedDraft = nil
                                justJoined = true
                            }
                        }.disabled(joinDraft.nextStep != nil)
                        Button("Enregistrer le brouillon pour plus tard") { saveDraft() }
                            .disabled(joinDraft == savedDraft)
                        if joinDraft == savedDraft && joinDraft != FamilyJoinDraft() {
                            Text("Brouillon enregistré dans ce coffre sur cet appareil.").font(.footnote)
                        }
                        if savedDraft != nil && !problem.isEmpty { Text(problem).foregroundStyle(.red) }
                    }.disabled(savedDraft == nil)
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
                if !problem.isEmpty && (!members.isEmpty || savedDraft == nil) { Text(problem).foregroundStyle(.red) }
                if working { ProgressView() }
            }
            .formStyle(.grouped).navigationTitle("Partage familial")
            .modifier(VaultDismissToolbar())
            .disabled(working)
            .confirmationDialog("Retirer l’autorisation de cet appareil ?", isPresented: Binding(get: { revoke != nil },
                set: { if !$0 { revoke = nil } }), presenting: revoke) { member in
                Button("Révoquer", role: .destructive) {
                    run { try await $0.revokeMember(member.card, reencrypt: reencrypt) }
                }
            }
        }.frame(idealWidth: 570, idealHeight: 600)
        .task {
            guard let store = model.store else { return }
            do {
                let draft = try await store.familyJoinDraft()
                joinDraft = draft
                savedDraft = draft
                try await refresh(store)
            } catch { problem = error.localizedDescription }
        }
    }

    private func verificationBinding<Value>(_ key: WritableKeyPath<FamilyPeerVerification, Value>) -> Binding<Value> {
        Binding(get: { verification[keyPath: key] }, set: { value in
            guard let store = model.store else { return }
            var updated = verification
            updated[keyPath: key] = value
            issued = ""
            do {
                try store.saveFamilyPeerVerification(updated)
                verification = updated
                verificationProblem = nil
            } catch { verificationProblem = error.localizedDescription }
        })
    }

    private func saveDraft() {
        guard !working, let store = model.store else { return }
        let draft = joinDraft
        working = true
        problem = ""
        Task {
            defer { working = false }
            do {
                try await store.saveFamilyJoinDraft(draft)
                savedDraft = draft
            } catch { problem = error.localizedDescription }
        }
    }

    private func refresh(_ store: VaultStore) async throws {
        mine = try await store.publicIdentity()
        principal = await store.family?.principal ?? ""
        members = try await store.members()
        model.familyMode = !members.isEmpty
        if isAdmin {
            do {
                verification = try store.familyPeerVerification()
                verificationProblem = nil
            } catch {
                verification = FamilyPeerVerification()
                verificationProblem = error.localizedDescription
            }
        }
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
                model.library = try await store.library()
                model.sync()
            } catch {
                try? await refresh(store)
                problem = error.localizedDescription
            }
        }
    }
}
