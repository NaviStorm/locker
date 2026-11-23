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
    init(model: LockerModel) {
        self.model = model
        _draft = State(initialValue: model.configuration)
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
                    Button("Identités et invitations") { sharing = true }
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
            .sheet(isPresented: $sharing) { IdentityScreen(model: model) }
        }.frame(idealWidth: 530, idealHeight: 520)
    }

    private func save() {
        busy = true
        errorText = ""
        Task {
            defer { busy = false }
            do {
                let credential: String?
                if draft.provider == .dropbox {
                    let oauth = DropboxAuthorization(client: draft.appKey)
                    let callback = try await webSession.authenticate(using: oauth.startURL, callbackURLScheme: "locker-vault",
                                                                      preferredBrowserSession: .ephemeral)
                    credential = try await oauth.finish(callback: callback)
                } else { credential = draft.provider == .webdav && !password.isEmpty ? password : nil }
                try await model.configure(draft, credential: credential)
                password = ""
            } catch { errorText = error.localizedDescription }
        }
    }
}
