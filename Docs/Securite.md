# Modèle de menace et choix techniques

Locker protège le contenu contre la lecture de son répertoire de stockage, des sauvegardes de ce répertoire et des enregistrements CloudKit. Un destinataire iCloud peut observer les tailles, les dates, le nombre d’objets et des identifiants opaques. AES-GCM détecte la modification du contenu. Un attaquant peut toujours détruire les données ou rejouer une ancienne copie cohérente. Un appareil compromis, les captures d’écran par l’utilisateur, un destinataire de partage et les originaux importés sont hors de cette protection.

## Clés et enrôlement

CryptoKit génère un secret aléatoire de 256 bits pour chaque coffre. HKDF-SHA256 dérive des clés distinctes pour le catalogue local et les enveloppes de synchronisation. Chaque importation génère sa propre clé AES-256. Seules les enveloppes chiffrées contiennent cette clé. Les identifiants aléatoires et les indices de blocs sont liés au contenu par les données authentifiées de GCM.

Le Trousseau conserve le secret sur l’appareil avec un contrôle d’accès exigeant la présence de l’utilisateur. Security.framework applique ce contrôle à la lecture avec un LAContext neuf. iOS exige un code appareil. macOS utilise le trousseau de protection des données et le mot de passe de session ou Touch ID. Le Secure Enclave peut participer à l’authentification système. Locker ne prétend pas y exécuter AES ni y rendre le secret de récupération non exportable. [Contrôle d’accès Apple](https://developer.apple.com/documentation/localauthentication/accessing-keychain-items-with-face-id-or-touch-id)

Le code de secours représente le secret aléatoire avec une somme de contrôle de saisie. Le conserver sur papier, à l’écart des appareils. Toute personne qui possède ce code et le stockage chiffré peut tout lire. Sur un nouvel appareil, saisir le code, autoriser le Trousseau local puis activer iCloud avec le même compte Apple. Hors ligne, le code seul ne recrée aucun document. En l’absence du code et de tout appareil pouvant encore ouvrir le coffre, les documents sont irrécupérables.

Chaque nouveau document a une clé indépendante. Pour une rotation complète après compromission, créer un nouveau coffre sur une installation distincte, transférer explicitement les documents dans un environnement maîtrisé, vérifier les copies et distribuer le nouveau code uniquement aux appareils autorisés. Retirer ensuite les anciens documents et synchroniser leurs suppressions. La rotation ne peut révoquer des copies déjà déchiffrées. La migration manuelle implique des exports en clair sous la responsabilité de l’utilisateur.

## Persistance et synchronisation

Le moteur de stockage sérialise les mutations. Un fichier chiffré est achevé avant la publication atomique du catalogue. Une suppression remplace la fiche et sa clé par un identifiant marqué supprimé avant la collecte du fichier. Les marqueurs persistent pour éviter la résurrection depuis un appareil hors ligne. L’effacement physique de supports flash, instantanés et sauvegardes échappe à l’application.

La base privée CloudKit reçoit une enveloppe authentifiée et un fichier déjà chiffré par document. Un contrôle de version serveur détecte les écritures concurrentes. La suppression l’emporte toujours. Deux modifications concurrentes de classement convergent selon un compteur logique puis un identifiant de révision. Le contenu importé est immuable. Le transport est injectable pour les essais sans compte iCloud. [Base CloudKit](https://developer.apple.com/documentation/cloudkit/ckdatabase)
