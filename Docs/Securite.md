# Modèle de menace et choix techniques

Locker protège le contenu contre la lecture de son répertoire de stockage, des sauvegardes de ce répertoire et des enregistrements CloudKit. Un destinataire iCloud peut observer les tailles, les dates, le nombre d’objets et des identifiants opaques. AES-GCM détecte la modification du contenu. Un attaquant peut toujours détruire les données ou rejouer une ancienne copie cohérente. Un appareil compromis, les captures d’écran par l’utilisateur, un destinataire de partage et les originaux importés sont hors de cette protection.

## Clés et enrôlement

CryptoKit génère un secret aléatoire de 256 bits pour chaque coffre. HKDF-SHA256 dérive des clés distinctes pour le catalogue local et les enveloppes de synchronisation. Chaque importation génère sa propre clé AES-256. Seules les enveloppes chiffrées contiennent cette clé. Les identifiants aléatoires et les indices de blocs sont liés au contenu par les données authentifiées de GCM.

Le Trousseau conserve le secret sur l’appareil avec un contrôle d’accès exigeant la présence de l’utilisateur. Security.framework applique ce contrôle à la lecture avec un LAContext neuf. iOS exige un code appareil. macOS utilise le trousseau de protection des données et le mot de passe de session ou Touch ID. Le Secure Enclave peut participer à l’authentification système. Locker ne prétend pas y exécuter AES ni y rendre le secret de récupération non exportable. [Contrôle d’accès Apple](https://developer.apple.com/documentation/localauthentication/accessing-keychain-items-with-face-id-or-touch-id)

Le code de secours représente le secret aléatoire avec une somme de contrôle de saisie. Le conserver sur papier, à l’écart des appareils. Toute personne qui possède ce code et le stockage chiffré peut tout lire. Sur un nouvel appareil, saisir le code, autoriser le Trousseau local puis activer iCloud avec le même compte Apple. Hors ligne, le code seul ne recrée aucun document. En l’absence du code et de tout appareil pouvant encore ouvrir le coffre, les documents sont irrécupérables.

Chaque nouvelle version de contenu a une clé indépendante. La commande de renouvellement personnel rechiffre les versions directement entre deux coffres, sans fichier intermédiaire en clair. Elle désactive la synchronisation de l’ancien coffre sur l’appareil qui effectue la rotation. Les appareils conservés doivent rejoindre le nouvel espace. Après compromission d’un code, les anciennes copies restent lisibles avec ce code. En famille, les changements de membres renouvellent la clé d’époque et la révocation peut rechiffrer les versions existantes.


## Persistance et synchronisation

Le moteur de stockage sérialise les mutations. Un fichier chiffré est achevé avant la publication atomique du catalogue. Une suppression remplace la fiche et sa clé par un identifiant marqué supprimé avant la collecte du fichier. Les marqueurs persistent pour éviter la résurrection depuis un appareil hors ligne. L’effacement physique de supports flash, instantanés et sauvegardes échappe à l’application.

Les trois fournisseurs reçoivent des pièces chiffrées et des manifestes. Un contrôle de version détecte les écritures concurrentes. Chaque nouvelle version conserve sa filiation. Les conflits de classement conservent les anciennes fiches. Les lecteurs familiaux vérifient aussi la politique, la signature de l’auteur et la portée du document. Les étapes de configuration et les limites de disponibilité figurent dans le guide d’architecture.

L’aperçu est déchiffré en mémoire. Les frameworks graphiques, les copies internes de Swift, la mémoire virtuelle du système, le presse-papiers utilisé volontairement et les applications recevant un partage échappent au contrôle intégral de Locker. Le verrouillage interrompt les nouveaux accès applicatifs et les lectures par blocs. Il ne constitue pas une garantie d’effacement instantané de la mémoire physique.
