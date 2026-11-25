import SwiftUI

struct VaultSecretField: View {
    let title: String
    let method: VaultAuthenticationMethod
    @Binding var text: String

    var isNew = false

    var body: some View {
        SecureField(title, text: $text)
            .autocorrectionDisabled()
            .privacySensitive()
            #if os(iOS)
            .textContentType(method == .vaultPassword ? (isNew ? .newPassword : .password) : nil)
            .keyboardType(method == .numericCode ? .numberPad : .default)
            .textInputAutocapitalization(.never)
            #endif
    }
}

struct NewVaultSecretSettings: View {
    let mode: AccessMode
    let create: (LockerModel.NewVaultSecret) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var method = VaultAuthenticationMethod.numericCode
    @State private var secret = ""
    @State private var confirmation = ""
    @State private var errorText = ""

    private var isRecovery: Bool {
        if case .recover = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Déverrouiller avec", selection: $method) {
                        Text("Code numérique du coffre").tag(VaultAuthenticationMethod.numericCode)
                        Text("Mot de passe du coffre").tag(VaultAuthenticationMethod.vaultPassword)
                    }
                    VaultSecretField(title: method.secretTitle, method: method, text: $secret, isNew: true)
                    VaultSecretField(title: "Confirmer la saisie", method: method, text: $confirmation, isNew: true)
                } header: {
                    Text("Protection du coffre")
                } footer: {
                    Text(method == .numericCode ? "Choisissez au moins 10 chiffres." :
                         "Choisissez au moins 12 caractères avec une majuscule, une minuscule, un chiffre et un symbole.")
                }
                Text("Le simulateur ne prend pas en charge le code de l’appareil pour ce coffre.")
                if !errorText.isEmpty { Text(errorText).foregroundStyle(.red) }
            }
            .vaultFormStyle()
            .navigationTitle(isRecovery ? "Réglages de récupération" : "Réglages du nouveau coffre")
            .onChange(of: method) { secret = ""; confirmation = ""; errorText = "" }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isRecovery ? "Récupérer" : "Créer") {
                        do {
                            try method.validateNewSecret(secret)
                            guard secret == confirmation else { throw VaultSecretError.mismatch }
                            create(.init(method: method, value: secret))
                        } catch { errorText = error.localizedDescription }
                    }
                    .disabled(secret.isEmpty || confirmation.isEmpty)
                }
            }
        }
    }
}

enum SecretChange: Identifiable {
    case method(VaultAuthenticationMethod), disable, rotate

    var id: String {
        switch self {
        case let .method(method): return method.rawValue
        case .disable: return "disable"
        case .rotate: return "rotate"
        }
    }
}

struct VaultSecretEditor: View {
    let model: LockerModel
    let action: SecretChange
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var proposed = ""
    @State private var confirmation = ""
    @State private var errorText = ""
    @State private var saving = false

    private var newMethod: VaultAuthenticationMethod? {
        if case let .method(method) = action, method.isCustom { return method }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.authenticationMethod.isCustom {
                    Section("Confirmer la méthode actuelle") {
                        VaultSecretField(title: model.authenticationMethod.secretTitle, method: model.authenticationMethod, text: $current)
                    }
                }
                if let method = newMethod {
                    Section("Nouvelle méthode") {
                        VaultSecretField(title: method.secretTitle, method: method, text: $proposed, isNew: true)
                        VaultSecretField(title: "Confirmer la saisie", method: method, text: $confirmation, isNew: true)
                        Text(method == .numericCode ? "Au moins 10 chiffres de 0 à 9."
                             : "Au moins 12 caractères avec majuscule, minuscule, chiffre et symbole. Évitez les mots de passe courants et les répétitions.")
                            .font(.footnote)
                    }
                    Text("Ce choix s’applique à ce coffre sur cet appareil. En cas d’oubli, utilisez le code de récupération.")
                        .font(.footnote)
                } else if case .disable = action {
                    Text("Le coffre pourra s’ouvrir dès que l’appareil est déverrouillé.")
                } else if case .rotate = action {
                    Text("Le nouveau coffre sera protégé par le même secret.")
                }
                if !errorText.isEmpty { Text(errorText).foregroundStyle(.red) }
                if saving { ProgressView() }
            }
            .vaultFormStyle()
            .navigationTitle("Déverrouillage du coffre")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Valider") { save() } }
            }
            .disabled(saving)
        }
        .interactiveDismissDisabled(saving)
        .frame(idealWidth: 470, idealHeight: 390)
    }

    private func save() {
        guard !saving else { return }
        do {
            if let method = newMethod {
                try method.validateNewSecret(proposed)
                guard proposed == confirmation else { throw VaultSecretError.mismatch }
            }
        } catch { errorText = error.localizedDescription; return }
        errorText = ""
        saving = true
        model.activity()
        Task {
            defer { saving = false }
            do {
                switch action {
                case let .method(target):
                    try await model.setSecretProtection(to: target, required: true, currentSecret: current, newSecret: proposed)
                case .disable:
                    try await model.setSecretProtection(to: .passcode, required: false, currentSecret: current, newSecret: "")
                case .rotate: try await model.rotatePersonal(secret: current)
                }
                current = ""; proposed = ""; confirmation = ""
                dismiss()
            } catch { errorText = error.localizedDescription }
        }
    }
}
