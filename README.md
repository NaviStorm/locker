# Locker

Coffre documentaire natif pour iPhone, iPad et Mac. Le stockage local est le mode initial. Créer un coffre, le déverrouiller, importer, classer, rechercher, lire et modifier des documents fonctionne hors ligne. Le NAS intervient uniquement dans les coffres configurés pour WebDAV.

## Compiler et signer

1. Ouvrir `Locker.xcodeproj` avec Xcode 27.2 ou ultérieur. Le schéma partagé se nomme **Locker**. Les cibles minimales sont iOS et iPadOS 17.4 et macOS 14.4.
2. Pour une installation signée, choisir son équipe dans **Signing & Capabilities**, attribuer un identifiant unique à la cible Locker et sélectionner le conteneur privé `iCloud.<identifiant-du-bundle>`. Associer ce conteneur au même identifiant d’application pour les deux plateformes. Les entitlements distincts activent aussi le bac à sable, le réseau sortant, la caméra et les fichiers sélectionnés sur Mac. Le Trousseau de protection des données nécessite une signature et des droits cohérents.
3. Sélectionner un simulateur, un appareil ou **My Mac**, puis exécuter le schéma. Les tests de logique sur Mac se lancent aussi avec `swift test` à la racine. Dans Xcode, **Product → Test** exécute la suite avec l’application hôte.
4. Pour Dropbox, ajouter le réglage de compilation utilisateur `DROPBOX_APP_KEY` à la cible Locker dans Debug et Release. Il contient l’identifiant **public** de l’application Dropbox. Xcode inscrit son schéma `db-<clé>` dans Info.plist. Les secrets de compte proviennent de l’autorisation individuelle. [Configuration du SDK officiel](https://github.com/dropbox/SwiftyDropbox/blob/master/README.md)

Pour compiler sans installer ni signer, depuis la racine du projet :

```sh
xcodebuild -project Locker.xcodeproj -scheme Locker -destination 'generic/platform=iOS' -derivedDataPath .validation/ios CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Locker.xcodeproj -scheme Locker -destination 'platform=macOS' -derivedDataPath .validation/mac CODE_SIGNING_ALLOWED=NO build
swift test
```

## Utiliser le coffre

- **Premier appareil.** Choisir si le nouveau coffre exige une authentification, puis **Créer un coffre** et recopier le code de récupération. Dans **Réglages du coffre → Sécurité → Méthode d’authentification**, choisir la biométrie ou le code de l’appareil (mot de passe de session sur Mac). Locker applique ce réglage à chaque ouverture du coffre sur cet appareil. Sans préférence enregistrée, un coffre protégé utilise le code de l’appareil ou le mot de passe du Mac. Chaque coffre a sa clé, sa file et son fournisseur. Les identifiants courts permettent de sélectionner le coffre avant authentification.
- **Documents.** Le bouton **Ajouter** ouvre Fichiers ou la caméra. VisionKit produit un PDF multipage sur les appareils compatibles. Sur Mac, la caméra fournit une photographie. La fiche contient le nom, le dossier, la catégorie et la description. Les filtres et la recherche s’appliquent après déverrouillage.
- **Dossiers.** À la racine, le bouton **Nouveau dossier** (icône de dossier avec un signe plus) crée un dossier. Le menu **…** du dossier, également accessible par clic secondaire ou appui long, permet de renommer le dossier ou de le supprimer avec son contenu après confirmation. La racine affiche les dossiers et les documents sans dossier. Chaque dossier affiche les documents qu’il contient.
- **Archives.** Dans **Importer un document**, choisissez **Décompresser une archive…**, puis sélectionnez une archive ZIP, TAR (y compris compressée), 7z, RAR, GZip, BZip2 ou XZ. Choisissez le coffre de destination, puis la **Racine du coffre** ou un dossier existant. Pour un autre coffre, ouvrez-le d’abord afin de choisir son dossier. **Décompresser ici** importe le contenu et **Importer sans décompresser** conserve l’archive à l’emplacement choisi. Un nouveau coffre reçoit les fichiers à sa racine. Les chemins internes deviennent des noms de dossier dans Locker. Les archives protégées par mot de passe ne sont pas prises en charge.
- **Gérer un document.** Faites un appui long sur sa ligne (clic secondaire sur Mac), ou ouvrez le menu **Actions** dans son aperçu. Choisissez **Renommer…**, **Déplacer vers** ou **Supprimer…**. Le déplacement propose les dossiers du coffre et sa racine. La suppression demande confirmation.
- **Versions.** **Ajouter une version** conserve les contenus précédents. Deux versions ajoutées hors ligne restent consultables. L’historique de la fiche conserve les anciennes métadonnées, y compris les modifications concurrentes. La suppression vise la version sélectionnée.
- **Consultation et sortie.** PDFKit, les images natives et le texte UTF-8 couvrent les formats courants. Les PDF de plus de 32 Mio utilisent un lecteur paginé par blocs authentifiés. Les autres formats ou les fichiers volumineux peuvent être exportés dans un dossier choisi. Le partage système d’une copie en clair est explicite et limité à 32 Mio. Pour partager durablement des données confidentielles, utiliser le coffre familial.
- **Autre appareil personnel.** Récupérer le coffre avec son code puis sélectionner le même fournisseur. Un appareil déjà approuvé peut aussi produire une autorisation HPKE après comparaison des deux empreintes dans **Mes appareils**.
- **Appareil personnel perdu.** **Renouveler mon coffre personnel** crée une nouvelle clé de coffre et rechiffre chaque version dans un nouvel espace. Le coffre d’origine passe en local sur cet appareil. Conserver le nouveau code, configurer le fournisseur puis enrôler uniquement les appareils conservés. Les anciennes copies et l’ancien espace distant dépendent toujours des anciennes clés.

## Choisir le fournisseur

| Choix | Configuration | Comportement |
|---|---|---|
| Local uniquement | Aucune | Aucune connexion réseau pour ce coffre. Conserver une copie chiffrée indépendante pour survivre à la perte du disque. |
| iCloud | Compte iCloud et capacité CloudKit | Zone privée pour un coffre personnel. Zone partagée privée avec participants explicites pour un coffre familial. |
| Dropbox | Application OAuth et autorisation par compte | Dropbox API v2, code avec PKCE S256 et renouvellement dans le Trousseau. Pour le partage entre comptes, configurer Full Dropbox avec les portées de métadonnées, de lecture/écriture des fichiers et de partage requises. |
| WebDAV / Synology | URL HTTPS d’un dossier existant, compte individuel et mot de passe | Dossier de coffre créé sous cette URL. Le serveur doit fournir des ETag forts et respecter les écritures conditionnelles. Chaque membre dispose de ses propres droits sur le dossier partagé. |

Pour CloudKit, le type de données **LockerObject** utilise un champ **bytes** de type Asset. Valider le schéma dans le conteneur de développement de l’équipe avant de le déployer en production. Pour Dropbox, accepter l’invitation au dossier avec le compte destinataire et le monter dans son Dropbox. Indiquer le dossier parent local si les deux montages se trouvent à des emplacements différents. [CloudKit](https://developer.apple.com/documentation/cloudkit/ckdatabase) · [API fichiers Dropbox](https://developers.dropbox.com/dbx-file-access-guide) · [OAuth Dropbox](https://developers.dropbox.com/oauth-guide)

Pour le NAS, saisir son adresse accessible sur le réseau local avec un certificat TLS approuvé par l’appareil. Aucune ouverture de port, connexion VPN ou modification du routeur n’est nécessaire. Une erreur réseau laisse les modifications locales dans la file chiffrée. Locker réessaie pendant que le coffre est ouvert. Le partage entre deux réseaux fonctionne via iCloud ou Dropbox indépendamment du NAS.

## Inviter un membre de la famille

1. Dans **Réglages du coffre → Partage familial**, le propriétaire choisit **Inviter un proche → Créer le coffre familial** dans un coffre local vide. Il enregistre ensuite iCloud ou Dropbox dans les réglages de ce coffre pour partager entre réseaux, et y importe les documents.
2. Dans son propre coffre local vide, le proche choisit **Rejoindre le coffre d’un proche → Envoyer ma carte publique**. Le propriétaire colle la carte reçue et compare l’empreinte avec le proche par téléphone ou en personne.
3. Le propriétaire choisit les documents et les droits, indique l’adresse du compte iCloud ou Dropbox du proche, puis choisit **Préparer l’invitation → Envoyer l’invitation à mon proche**.
4. Le proche colle l’invitation dans Locker. La carte du propriétaire est incluse dans les nouvelles invitations. Après comparaison de l’empreinte par téléphone ou en personne, il accepte et enregistre le même fournisseur avec son propre compte. Pour Dropbox, il accepte également le partage du dossier dans Dropbox.
5. Le propriétaire conserve le **kit de secours chiffré** séparément du code de récupération. Après perte des appareils, récupérer d’abord le coffre personnel avec le code, restaurer le kit dans **Partage familial**, puis reconnecter le fournisseur. Les deux éléments et une copie des données permettent de retrouver l’autorité de secours sans l’ancien Secure Enclave.

Pour retirer un appareil familial, sélectionner son empreinte dans **Appareils autorisés**, puis **Révoquer**. La rotation des clés de partage est systématique. Le rechiffrement des contenus locaux est proposé et activé par défaut. Une copie déjà téléchargée ou exportée peut subsister.

## Documents du projet

- [Architecture et limites d’exploitation](Docs/Architecture.md)
- [Modèle de sécurité et récupération](Docs/Securite.md)
- [Conception du partage et autorisations](Docs/Partage.md)
- [Résultats de validation](Docs/Validation.md)
