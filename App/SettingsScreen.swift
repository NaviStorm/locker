import AuthenticationServices
import SwiftUI

struct SettingsScreen: View {
    @Bindable var model: LockerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webSession
    @State private var draft: ProviderSettings
    @State private var vaultName: String
    @State private var nameError: String?
    @State private var protectionError: String?
    @State private var password = ""
    @State private var savedPasswordFor: ProviderSettings?
    @State private var editingPassword = false
    @State private var busy = false
    @State private var errorText = ""
    @State private var code: String?
    @State private var sharing = false
    @State private var family = false
    @State private var rotate = false
    @State private var removal: String?
    private static var dropboxKey: String {
        Bundle.main.object(forInfoDictionaryKey: "LockerDropboxKey") as? String ?? ""
    }

    init(model: LockerModel) {
        self.model = model
        _vaultName = State(initialValue: model.vaultTitle)
        var config = model.configuration
        if config.provider == .dropbox && config.appKey.isEmpty { config.appKey = Self.dropboxKey }
        _draft = State(initialValue: config)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom du coffre", text: $vaultName)
                    Button("Renommer le coffre") {
                        do {
                            try model.renameVault(vaultName)
                            vaultName = model.vaultTitle
                            nameError = nil
                        } catch { nameError = error.localizedDescription }
                    }.disabled(vaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vaultName == model.vaultTitle)
                    if let nameError { Text(nameError).foregroundStyle(.red) }
                } header: { Text("Nom du coffre") }
                  footer: { Text("Ce nom est visible sur cet appareil avant le déverrouillage.") }
                Section("Sécurité") {
                    Toggle("Exiger une authentification à l’ouverture", isOn: Binding(
                        get: { model.requiresAuthentication },
                        set: { value in
                            protectionError = nil
                            Task {
                                do { try await model.setAuthenticationRequired(value) }
                                catch { protectionError = error.localizedDescription }
                            }
                        }
                    ))
                    .disabled(model.changingProtection)
                    AuthenticationMethodPicker(selection: Binding(
                        get: { model.authenticationMethod },
                        set: { model.rememberAuthenticationMethod($0) }
                    ))
                    .disabled(model.changingProtection)
                    if let protectionError { Text(protectionError).foregroundStyle(.red) }
                    Text("Si vous désactivez l’authentification, toute personne utilisant l’appareil déverrouillé pourra l’ouvrir.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Verrouillage après inactivité", selection: $model.timeout) {
                        ForEach([30, 60, 120, 300, 900], id: \.self) { Text($0 < 60 ? "30 secondes" : "\($0 / 60) min").tag($0) }
                    }
                    if let code { Text(code).font(.system(.body, design: .monospaced)) }
                    else {
                        Button("Afficher le code de récupération") {
                            model.perform { store in code = try await store.recoveryCode() }
                        }
                    }
                    Button("Partage familial") { family = true }
                    if !model.familyMode {
                        Button("Renouveler mon coffre personnel…") { rotate = true }
                        Button("Mes appareils") { sharing = true }
                    }
                }
                Section("Synchronisation de ce coffre") {
                    Picker("Fournisseur", selection: $draft.provider) {
                        ForEach(Provider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if draft.provider == .webdav {
                        TextField("URL HTTPS du dossier partagé", text: $draft.endpoint)
                        Text("Si le partage se nomme Documents, saisissez par exemple https://nas.example:5006/Documents/")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextField("Utilisateur du NAS", text: $draft.username)
                        if savedPasswordFor == draft && !editingPassword {
                            LabeledContent("Mot de passe du NAS") {
                                Text("••••••••").accessibilityLabel("Mot de passe enregistré")
                            }
                            Button("Modifier le mot de passe") { editingPassword = true }
                        } else {
                            SecureField("Mot de passe du NAS", text: $password)
                            if savedPasswordFor == draft {
                                Button("Conserver le mot de passe enregistré") {
                                    password = ""
                                    editingPassword = false
                                }
                            }
                        }
                    }
                    if draft.provider == .dropbox {
                        TextField("Identifiant public de l’application Dropbox", text: $draft.appKey)
                        TextField("Dossier parent (facultatif)", text: $draft.sharedFolder)
                    }
                    Button(draft.provider == .dropbox ? "Autoriser Dropbox et enregistrer" : "Enregistrer le fournisseur") {
                        save()
                    }.disabled(busy)
                    if model.configuration.provider != .local {
                        Button("Synchroniser maintenant") { model.sync() }.disabled(model.syncing)
                        Text(model.syncing ? "Synchronisation en cours…" : model.syncStatus).font(.footnote)
                    }
                    if !errorText.isEmpty { Text(errorText).foregroundStyle(.red) }
                }
                Section {
                    if model.vaultKinds[model.slot] == .family {
                        Label("Ce coffre familial est protégé contre la suppression.", systemImage: "person.2")
                    } else {
                        Button("Supprimer ce coffre de cet appareil…", role: .destructive) { removal = model.slot }
                            .disabled(model.removingVault)
                    }
                }
            }.vaultFormStyle().navigationTitle("Réglages du coffre")
            .modifier(LocalVaultRemovalDialog(model: model, request: $removal))
            .modifier(VaultDismissToolbar())
            .confirmationDialog("Créer un nouveau coffre avec de nouvelles clés et conserver l’ancien hors ligne ?", isPresented: $rotate) {
                Button("Rechiffrer les documents") {
                    Task {
                        do { try await model.rotatePersonal(); dismiss() }
                        catch { errorText = error.localizedDescription }
                    }
                }
            }
            .onChange(of: model.configuration) { _, config in
                if family { draft = config }
            }
            .onChange(of: draft.provider) { _, provider in
                if provider == .dropbox && draft.appKey.isEmpty { draft.appKey = Self.dropboxKey }
            }
            .onChange(of: draft) { _, _ in
                password = ""
                editingPassword = false
            }
            .task(id: draft) {
                let config = draft
                guard config.provider == .webdav, let store = model.store else { return }
                do {
                    let exists = try await store.hasSavedWebDAVPassword(for: config)
                    guard !Task.isCancelled, draft == config else { return }
                    savedPasswordFor = exists ? config : nil
                } catch {
                    if !Task.isCancelled && draft == config { errorText = error.localizedDescription }
                }
            }
            .lockerPanel(isPresented: $family) { FamilyScreen(model: model) }
            .sheet(isPresented: $sharing) { IdentityScreen(model: model) }
        }.frame(idealWidth: 530, idealHeight: 520)
    }

    private func save() {
        busy = true
        errorText = ""
        Task {
            defer { busy = false }
            do {
                let config = draft
                if config.provider == .dropbox {
                    guard !config.appKey.isEmpty, config.appKey == Self.dropboxKey else {
                        throw TransportError(message: "Renseignez DROPBOX_APP_KEY dans les réglages de compilation de Locker, puis recompilez.")
                    }
                    let handoff = try await model.prepareOAuth()
                    let oauth = DropboxAuthorization(client: config.appKey)
                    let callback = try await webSession.authenticate(using: oauth.startURL, callbackURLScheme: oauth.scheme,
                                                                      preferredBrowserSession: .ephemeral)
                    let refresh = try await oauth.finish(callback: callback)
                    try await model.finishOAuth(handoff, config: config, refresh: refresh)
                } else {
                    try await model.configure(config, credential: config.provider == .webdav && !password.isEmpty ? password : nil)
                }
                if config == draft {
                    if config.provider == .webdav { savedPasswordFor = config }
                    password = ""
                    editingPassword = false
                }
            } catch { errorText = error.localizedDescription }
        }
    }
}
