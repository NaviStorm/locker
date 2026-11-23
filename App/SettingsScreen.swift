import AuthenticationServices
import SwiftUI

struct SettingsScreen: View {
    @Bindable var model: LockerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webSession
    @State private var draft: ProviderSettings
    @State private var password = ""
    @State private var busy = false
    @State private var errorText = ""
    @State private var code: String?
    @State private var sharing = false
    @State private var family = false
    @State private var rotate = false
    init(model: LockerModel) {
        self.model = model
        var config = model.configuration
        if config.appKey.isEmpty { config.appKey = Bundle.main.object(forInfoDictionaryKey: "LockerDropboxKey") as? String ?? "" }
        _draft = State(initialValue: config)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sécurité") {
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
                        TextField("URL HTTPS du dossier WebDAV", text: $draft.endpoint)
                        TextField("Utilisateur du NAS", text: $draft.username)
                        SecureField("Mot de passe du NAS", text: $password)
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
            }.formStyle(.grouped).navigationTitle("Réglages du coffre")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { dismiss() } } }
            .confirmationDialog("Créer un nouveau coffre avec de nouvelles clés et conserver l’ancien hors ligne ?", isPresented: $rotate) {
                Button("Rechiffrer les documents") {
                    Task {
                        do { try await model.rotatePersonal(); dismiss() }
                        catch { errorText = error.localizedDescription }
                    }
                }
            }
            .sheet(isPresented: $family) { FamilyScreen(model: model) }
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
                    guard !config.appKey.isEmpty, config.appKey == Bundle.main.object(forInfoDictionaryKey: "LockerDropboxKey") as? String else {
                        throw TransportError(message: "Renseignez DROPBOX_APP_KEY dans les réglages de compilation de Locker, puis recompilez.")
                    }
                    let handoff = try await model.prepareOAuth()
                    let oauth = DropboxAuthorization(client: draft.appKey)
                    let callback = try await webSession.authenticate(using: oauth.startURL, callbackURLScheme: oauth.scheme,
                                                                      preferredBrowserSession: .ephemeral)
                    let refresh = try await oauth.finish(callback: callback)
                    try await model.finishOAuth(handoff, config: config, refresh: refresh)
                } else {
                    try await model.configure(config, credential: config.provider == .webdav && !password.isEmpty ? password : nil)
                }
                password = ""
            } catch { errorText = error.localizedDescription }
        }
    }
}
