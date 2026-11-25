import SwiftUI

struct AboutLockerSection: View {
    var body: some View {
        Section("À propos de Locker") {
            NavigationLink("Mentions légales") { LockerLegalNotices() }
            NavigationLink("Politique de confidentialité") { LockerPrivacyPolicy() }
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                LabeledContent("Version", value: "\(version)+\(build)")
            }
        }
    }
}

private struct PublisherContact: View {
    var body: some View {
        Link("app@perouges.eu", destination: URL(string: "mailto:app@perouges.eu")!)
    }
}

private struct LockerLegalNotices: View {
    var body: some View {
        Form {
            Section("Éditeur de l’application") {
                Text("ANDREU-ASCENSIO Thierry")
                PublisherContact()
            }
            Section("Hébergement des documents") {
                Text("En mode local, votre appareil héberge le coffre. Si vous activez la synchronisation, les copies distantes sont hébergées par Apple (iCloud), Dropbox ou l’exploitant du serveur WebDAV que vous choisissez.")
            }
            Section("Propriété intellectuelle") {
                Text("Les textes, images, icônes et le code de Locker sont protégés par le droit d’auteur. Les éléments de tiers restent la propriété de leurs titulaires. Vous conservez vos droits sur les documents que vous importez.")
            }
        }
        .vaultFormStyle()
        .navigationTitle("Mentions légales")
    }
}

private struct LockerPrivacyPolicy: View {
    var body: some View {
        Form {
            Section("Données utilisées") {
                Text("Locker traite les fichiers que vous importez ainsi que leurs noms, dossiers, notes et versions pour vous permettre de les classer, de les retrouver et de les consulter hors ligne.")
                Text("Le sélecteur de photos transmet à Locker la photo que vous choisissez. La caméra sert à prendre des photos ou à scanner des pages à votre demande.")
            }
            Section("Sécurité du coffre") {
                Text("Locker chiffre les documents et leur catalogue sur votre appareil. Le Trousseau protège les clés locales. Le nom du coffre peut apparaître avant son déverrouillage.")
                Text("Conservez votre code de récupération en lieu sûr. Il permet d’accéder aux copies chiffrées du coffre.")
            }
            Section("Synchronisation et partage") {
                Text("En mode local, les documents du coffre restent sur cet appareil. Si vous choisissez iCloud, Dropbox ou WebDAV, Locker transmet le contenu chiffré au fournisseur. Celui-ci peut voir des informations techniques, notamment la taille et la date des transferts.")
                Text("Si vous partagez un coffre, les destinataires autorisés peuvent consulter les documents selon les droits accordés. Retirer un accès laisse au destinataire les copies qu’il a déjà exportées.")
            }
            Section("Conservation et suppression") {
                Text("Les documents placés dans la corbeille peuvent être restaurés jusqu’à leur suppression définitive. Vous pouvez aussi supprimer d’anciennes versions depuis l’historique du document.")
                Text("Supprimer un coffre de cet appareil efface sa copie locale. Les sauvegardes, les originaux importés et les copies déjà synchronisées sont à gérer séparément.")
            }
            Section("Vos droits et contact") {
                Text("Vous pouvez consulter, modifier et supprimer vos documents depuis Locker. Pour toute question sur vos données ou pour exercer vos droits auprès de l’éditeur, écrivez à l’adresse ci-dessous.")
                PublisherContact()
            }
            Text("Dernière mise à jour le 25 novembre 2026").font(.footnote)
        }
        .vaultFormStyle()
        .navigationTitle("Politique de confidentialité")
    }
}
