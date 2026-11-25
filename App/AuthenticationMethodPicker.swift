import LocalAuthentication
import SwiftUI

struct AuthenticationMethodPicker: View {
    @Binding var selection: VaultAuthenticationMethod

    private func biometryName(_ type: LABiometryType) -> String {
        switch type {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        default: return "Biométrie"
        }
    }

    var body: some View {
        let context = LAContext()
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        Picker("Méthode d’authentification", selection: $selection) {
            #if os(macOS)
            Text("Mot de passe du Mac").tag(VaultAuthenticationMethod.passcode)
            #else
            Text("Code de l’appareil").tag(VaultAuthenticationMethod.passcode)
            #endif
            Text(biometryName(context.biometryType))
                .tag(VaultAuthenticationMethod.biometrics)
                .disabled(!available)
            Text("Code numérique du coffre").tag(VaultAuthenticationMethod.numericCode)
            Text("Mot de passe du coffre").tag(VaultAuthenticationMethod.vaultPassword)
        }
    }
}
