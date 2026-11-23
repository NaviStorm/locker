# Validation du 23 novembre 2026

Xcode 27.2 (27B52), SDK Apple 27.2 et Mac Apple Silicon. Les données utilisées sont fictives.

| Vérification | Résultat |
|---|---|
| Compilation de l’application pour macOS arm64 | Réussie |
| Compilation générique iOS et iPadOS pour appareil physique | Réussie, sans signature de distribution |
| Tests du moteur avec Swift Package Manager sur Mac | 17 exécutés, 0 échec |
| Tests Xcode dans l’application hôte sur iPhone Duo, iOS 27.2 | 18 exécutés, 0 échec |
| Installation et lancement sur iPhone Duo simulé | Effectués. Accueil vérifié sur l’écran extérieur actif. |
| Migration de fenêtre au dépliage et affichage sur iPad physique | À vérifier sur ces configurations |
| Signature avec une équipe Apple et distribution | À qualifier avec le profil de l’équipe |

Le dix-huitième test exercé sur simulateur vérifie le modèle de session SwiftUI. Les 17 scénarios de logique sont communs aux deux suites.

## Scénarios vérifiés

- Un NAS simulé laisse une requête en attente pendant que l’utilisateur importe, modifie et consulte un document local. Un second coffre termine sa propre synchronisation au même moment. Après l’échec réseau, la file du premier coffre reste présente.
- Une coupure après la première pièce d’un transfert de 5 Mo laisse le document accessible après redémarrage. La reprise envoie la pièce manquante puis le manifeste. Le second appareil retrouve les octets d’origine.
- Un PDF fictif de plus de 33 Mio s’ouvre par plages authentifiées. Le rendu d’une page est refusé dès le verrouillage. L’export préserve un fichier préexistant à destination.
- L’altération d’un bloc, l’ajout de données ou la disparition du marqueur final font échouer la lecture. La vérification du stockage recherche des marqueurs fictifs sensibles et la clé racine en clair.
- La récupération personnelle échoue avec une mauvaise clé. Une nouvelle clé de coffre et de nouvelles clés de contenu permettent de reprendre les versions après rotation personnelle.
- Deux appareils modifient la même fiche hors ligne et convergent. Les marqueurs de suppression empêchent la réapparition d’une version supprimée. Deux versions de contenu restent consultables.
- Une famille échange entre trois identités. Un lecteur limité reçoit une seule lignée de documents. Un contributeur ajoute une version et se voit refuser la modification d’une fiche. La révocation, la rotation, la restauration par kit et le rejet d’une ancienne politique sont exercés.
- Les invitations sont liées à l’émetteur vérifié et au destinataire. Les tests refusent un tiers, un autre type de message et la création d’une politique par un lecteur.
- Des réponses HTTP simulées vérifient l’inventaire WebDAV, la création du dossier, les ETag, la pagination Dropbox, le renouvellement du jeton et le refus des écritures en conflit.
- L’expiration de la session efface les fiches et le code affichés. L’ancienne référence au lecteur ne peut plus déchiffrer.

## Limites de preuve

Les tests de partage utilisent des identités logicielles et un transport contrôlé. Les échanges entre deux comptes Apple ou Dropbox réellement distincts, la connexion à un Synology et la gestion de ses ACL restent à vérifier avec des comptes et un serveur dédiés. Les essais n’ont envoyé aucun document à ces services. Le fonctionnement matériel de Face ID, Touch ID, Secure Enclave et de la caméra reste à vérifier sur appareil. Le déploiement de production CloudKit et un audit cryptographique indépendant restent ouverts.

Le premier lancement de la suite Xcode a révélé que la cible de tests produisait un paquet sans nom. Le projet fixe maintenant explicitement `PRODUCT_NAME = LockerTests`. La suite finale a été exécutée dans l’application hôte.

## Reproduire

Depuis la racine du projet, exécuter `swift test` sur Mac. Pour le simulateur, sélectionner le schéma **Locker**, choisir un iPhone et lancer **Product → Test**. Le fichier de résultats de cette session est conservé localement sous `.validation/DuoFinal.xcresult`, avec les journaux de compilation et la capture `.validation/Locker-iPhone-Duo.png`. Ces produits générés sont exclus de Git.
