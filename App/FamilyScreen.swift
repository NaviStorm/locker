import SwiftUI

struct FamilyScreen: View {
    let model: LockerModel
    #if os(iOS)
    @State private var nearby: NearbyRole?
    @State private var manual = false
    #else
    private let manual = true
    #endif
    private enum Route { case invite, join }
    @State private var route: Route?
    @State private var canStart = false
    @State private var hasCloudInvitation = false
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
    @State private var editing: Member?
    @State private var editedRole = FamilyRole.reader
    @State private var recoveryFingerprint: String?
    @State private var deviceNames: [String: String] = [:]
    @State private var renamingID: String?
    @State private var proposedName = ""
    @State private var revoke: Member?
    @State private var reencrypt = true
    @State private var rescue = ""
    @State private var kit = ""
    private var isAdmin: Bool { members.contains { $0.card.fingerprint == principal && $0.role == .admin } }

    var body: some View {
        NavigationStack {
            Form {
                if !members.isEmpty { authorizedDevices }
                #if os(iOS)
                if mine == nil && !manual && problem.isEmpty { ProgressView() }
                if mine != nil, members.isEmpty || (isAdmin && [.local, .cloud].contains(model.configuration.provider)) {
                    Section("Deux iPhones à proximité") {
                        if members.isEmpty && !canStart {
                            Text("Locker créera un coffre familial séparé. Vos documents personnels resteront dans le coffre actuel.")
                        }
                        Button("Inviter à proximité") { beginNearby(.owner) }
                        if members.isEmpty { Button("Recevoir un coffre") { beginNearby(.guest) } }
                        Text("Gardez les deux iPhones côte à côte. Le proche recevra un accès en lecture via iCloud.").font(.footnote)
                    }
                    Button(manual ? "Masquer le partage manuel" : "Autres méthodes de partage") { manual.toggle() }
                }
                #endif
                if manual || (!members.isEmpty && (!isAdmin || ![.local, .cloud].contains(model.configuration.provider))) {
                    manualSharing
                }
                if !members.isEmpty {
                    if let mine {
                        DisclosureGroup("Ma carte publique") { deviceCard(mine) }
                    }
                }
                if isAdmin || members.isEmpty {
                    DisclosureGroup("Secours du propriétaire") {
                        if isAdmin {
                            Button("Préparer le kit de secours chiffré") { run { kit = try await $0.makeRescueKit() } }
                            if !kit.isEmpty { ShareLink("Conserver le kit de secours", item: kit) }
                        } else {
                            TextField("Kit associé au code de récupération", text: $rescue, axis: .vertical)
                            Button("Restaurer mon autorité de secours") { run { try await $0.restoreRescueKit(rescue) } }
                                .disabled(rescue.isEmpty)
                        }
                    }
                }
                if !problem.isEmpty { Text(problem).foregroundStyle(.red) }
                if working { ProgressView() }
            }
            #if os(iOS)
            .sheet(item: $nearby, onDismiss: {
                if let store = model.store {
                    Task { do { try await refresh(store) } catch { problem = error.localizedDescription } }
                }
            }) { role in
                if let store = model.store { NearbyFamilyScreen(model: model, role: role, store: store) }
            }
            #endif
            .alert("Nom de l’appareil dans ce coffre", isPresented: Binding(
                get: { renamingID != nil }, set: { if !$0 { renamingID = nil } }), presenting: renamingID) { id in
                TextField("Ex. Mac de mon conjoint", text: $proposedName)
                Button("Enregistrer") {
                    let name = proposedName
                    run(synchronize: false) { try await $0.nameDevice(id, name: name) }
                }
                Button("Annuler", role: .cancel) {}
            } message: { _ in Text("Ce nom est conservé dans le coffre sur cet appareil.") }
            .vaultFormStyle().navigationTitle("Partage familial")
            .onChange(of: model.syncing) {
                guard !model.syncing, let store = model.store else { return }
                Task { do { try await refresh(store) } catch { problem = error.localizedDescription } }
            }
            .onChange(of: role) { issued = "" }
            .onChange(of: restricted) { issued = "" }
            .onChange(of: chosen) { issued = "" }
            .onChange(of: email) { issued = "" }
            .onChange(of: existingAccess) { issued = "" }
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
                if draft != FamilyJoinDraft() {
                    route = .join
                    #if os(iOS)
                    manual = true
                    #endif
                }
                try await refresh(store)
            } catch { problem = error.localizedDescription }
        }
    }

    private var authorizedDevices: some View {
        Section("Appareils autorisés") {
            ForEach(members, id: \.card.fingerprint) { member in
                let id = member.card.fingerprint
                VStack(alignment: .leading, spacing: 6) {
                    if id == recoveryFingerprint {
                        Text("Secours du propriétaire").bold()
                    } else {
                        HStack {
                            Text(deviceNames[id] ?? (id == principal ? "Cet appareil" : "Appareil du proche")).bold()
                            Button {
                                proposedName = deviceNames[id] ?? ""
                                renamingID = id
                            } label: { Image(systemName: "pencil") }.accessibilityLabel("Nommer cet appareil")
                        }
                    }
                    Text(id.prefix(16)).font(.system(.body, design: .monospaced))
                    Text(member.role.rawValue + " · " + (member.documents.map { "\($0.count) document(s)" } ?? "Tout le coffre"))
                        .font(.caption)
                    if isAdmin, id != principal, id != recoveryFingerprint {
                        if let original = editing, original.card == member.card {
                            Picker("Permission", selection: $editedRole) {
                                ForEach(FamilyRole.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            if editedRole == .admin {
                                Text("Cet appareil pourra gérer tous les documents du coffre et les droits des autres membres.")
                                    .font(.footnote)
                            }
                            if model.configuration.provider == .webdav, editedRole != .reader {
                                Text("Le compte du proche doit aussi avoir accès en écriture au dossier WebDAV sur le NAS.").font(.footnote)
                            }
                            HStack {
                                Button("Enregistrer") {
                                    let selected = editedRole
                                    run { store in
                                        try await store.updateMemberRole(original, to: selected)
                                        editing = nil
                                    }
                                }.disabled(editedRole == original.role)
                                Button("Annuler") { editing = nil }
                            }
                        } else {
                            HStack {
                                Button("Modifier les droits") { editedRole = member.role; editing = member }
                                Spacer()
                                Button("Révoquer", role: .destructive) { revoke = member }
                            }
                        }
                    }
                }.buttonStyle(.borderless)
            }
            if isAdmin { Toggle("Rechiffrer les fichiers locaux à la révocation", isOn: $reencrypt) }
        }
    }

    @ViewBuilder private var manualSharing: some View {
        if let mine {
            if members.isEmpty {
                if canStart {
                    if route == nil {
                        Section("Que souhaitez-vous faire ?") {
                            Button("Inviter un proche") { route = .invite }
                            Button("Rejoindre le coffre d’un proche") { route = .join }
                        }
                    } else {
                        Button("Changer de parcours") { route = nil }
                        if route == .invite {
                            Section("Créer le coffre à partager") {
                                Text("Ce coffre vide deviendra le coffre familial. Vous pourrez y importer les documents à partager.")
                                Button("Créer le coffre familial") { run { try await $0.createFamily() } }
                            }
                        } else {
                            Section("1. Envoyer ma carte au propriétaire") {
                                Text("Envoyez votre carte depuis cet appareil. Le propriétaire l’utilisera pour préparer votre invitation.")
                                deviceCard(mine)
                            }
                        }
                    }
                } else {
                    Section("Commencer dans un coffre vide") {
                        Text("Le partage familial démarre dans un coffre local vide. Créez un coffre séparé, conservez son code de récupération, puis rouvrez Réglages du coffre → Partage familial.")
                        Button("Créer un coffre séparé pour le partage") {
                            model.lock()
                            model.open(.create, newSlot: true)
                        }
                    }
                }
            } else {
                Section(isAdmin ? "Partager ce coffre" : "Coffre familial rejoint") {
                    if justJoined { Label("Invitation acceptée", systemImage: "checkmark.circle") }
                    if model.configuration.provider == .local {
                        if isAdmin || hasCloudInvitation {
                            Button("Utiliser iCloud pour ce coffre") {
                                run { _ in try await model.configure(ProviderSettings(provider: .cloud), credential: nil) }
                            }
                        }
                        Text(isAdmin
                            ? "Pour partager à distance, choisissez iCloud ici ou enregistrez Dropbox dans les réglages du coffre."
                            : "Choisissez le même fournisseur que le propriétaire avec votre propre compte pour recevoir les documents.")
                    } else {
                        LabeledContent("Synchronisation", value: model.configuration.provider.rawValue)
                    }
                }
            }
        } else if problem.isEmpty { ProgressView() }
        if isAdmin {
            Section("1. Vérifier la carte du proche") {
                Text("Sur son appareil, votre proche choisit Partage familial → Rejoindre le coffre d’un proche et vous envoie sa carte. Collez-la ici.")
                PasteButton(payloadType: String.self) { values in
                    if let card = values.first { verificationBinding(\.card).wrappedValue = card }
                }
                TextField("Carte publique du correspondant", text: verificationBinding(\.card), axis: .vertical)
                    .autocorrectionDisabled()
                if let peer = verification.peer {
                    Text(peer.fingerprint).font(.system(.caption, design: .monospaced))
                    Toggle("J’ai comparé cette empreinte avec mon proche, en personne ou par téléphone", isOn: verificationBinding(\.isConfirmed))
                }
                if !verification.card.isEmpty && verification.peer == nil {
                    Text("Carte illisible. Demandez le texte complet envoyé avec « Envoyer ma carte publique ».")
                }
                if let verificationProblem { Text(verificationProblem).foregroundStyle(.red) }
                else if verification.isConfirmed {
                    Text("Vérification mémorisée dans ce coffre sur cet appareil.").font(.footnote)
                }
            }
            Section("2. Choisir les documents et les droits") {
                Picker("Permission", selection: $role) {
                    ForEach(FamilyRole.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if role != .admin {
                    Toggle("Limiter à certains documents", isOn: $restricted)
                    if restricted {
                        ForEach(model.documents) { row in
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
            }
            Section("3. Envoyer l’invitation") {
                if let missing = invitationHint { Text(missing).font(.footnote) }
                Button("Préparer l’invitation") {
                    guard invitationHint == nil, let peer = verification.peer else { return }
                    run { store in
                        let scope = restricted && role != .admin ? chosen : nil
                        try await store.changeMembership(card: peer, role: role, scope: scope)
                        if existingAccess { issued = try await store.familyTicket(for: peer) }
                        else { issued = try await store.issueTicket(to: peer, email: email) }
                    }
                }.disabled(invitationHint != nil)
                if !issued.isEmpty, let mine {
                    ShareLink("Envoyer l’invitation à mon proche", item: issued)
                    Text("Demandez à votre proche de coller l’invitation dans Locker, puis de comparer votre empreinte avec vous.")
                    fingerprint(mine)
                }
            }
        } else if members.isEmpty && canStart && route == .join {
            Section("2. Accepter l’invitation du propriétaire") {
                PasteButton(payloadType: String.self) { values in
                    if let ticket = values.first { joinDraft.pasteInvitation(ticket) }
                }
                TextField("Coller l’invitation reçue", text: Binding(get: { joinDraft.ticket }, set: { joinDraft.pasteInvitation($0) }), axis: .vertical)
                    .lineLimit(1...4).autocorrectionDisabled()
                if joinDraft.owner == nil && !joinDraft.ticket.isEmpty {
                    TextField("Carte du propriétaire (ancienne invitation)", text: $joinDraft.card, axis: .vertical)
                        .lineLimit(1...3).autocorrectionDisabled()
                } else if joinDraft.owner != nil {
                    DisclosureGroup("Carte du propriétaire") {
                        TextField("Carte publique", text: $joinDraft.card, axis: .vertical).autocorrectionDisabled()
                    }
                }
                if let owner = joinDraft.owner {
                    fingerprint(owner)
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
            }.disabled(savedDraft == nil)
        }
    }

    #if os(iOS)
    private func beginNearby(_ role: NearbyRole) {
        if members.isEmpty && !canStart {
            model.lock()
            model.open(.create, newSlot: true) { model.pendingNearbyRole = role }
        } else { nearby = role }
    }
    #endif

    private var invitationHint: String? {
        if verificationProblem != nil || !verification.isConfirmed { return "Vérifiez d’abord la carte de votre proche à l’étape 1." }
        if verification.peer == mine { return "Collez la carte de l’appareil de votre proche à l’étape 1." }
        if restricted && role != .admin && chosen.isEmpty { return "Sélectionnez au moins un document à l’étape 2." }
        if [.cloud, .dropbox].contains(model.configuration.provider), !existingAccess,
           email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Indiquez l’adresse du compte de votre proche à l’étape 2." }
        return nil
    }

    private func fingerprint(_ identity: PublicIdentity) -> some View {
        Text(identity.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    }

    @ViewBuilder private func deviceCard(_ identity: PublicIdentity) -> some View {
        ShareLink("Envoyer ma carte publique", item: identity.card)
        Text("Empreinte à comparer en personne ou par téléphone").font(.caption)
        fingerprint(identity)
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
        canStart = try await store.canStartFamily()
        mine = try await store.publicIdentity()
        let family = await store.family
        principal = family?.principal ?? ""
        recoveryFingerprint = family?.recoveryFingerprint
        hasCloudInvitation = family?.cloudURL != nil
        members = try await store.members()
        deviceNames = Dictionary(uniqueKeysWithValues: members.compactMap { member -> (String, String)? in
            let id = member.card.fingerprint
            return family?.displayName(for: id).map { (id, $0) }
        })
        if let original = editing, !members.contains(where: {
            $0.card == original.card && $0.role == original.role && $0.documents == original.documents
        }) { editing = nil }
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

    private func run(synchronize: Bool = true, _ operation: @escaping (VaultStore) async throws -> Void) {
        guard !working, let store = model.store else { return }
        working = true
        problem = ""
        Task {
            defer { working = false }
            do {
                try await operation(store)
                try await refresh(store)
                model.library = try await store.library()
                if synchronize { model.sync() }
            } catch {
                try? await refresh(store)
                problem = error.localizedDescription
            }
        }
    }
}
