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
