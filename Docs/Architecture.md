# Architecture

## Coffre local

`VaultStore` est un acteur par session. Son catalogue AES-GCM authentifié contient les fiches, clés de document, versions en attente, marqueurs de suppression et état familial local. L’import écrit d’abord le fichier chiffré, puis remplace atomiquement le catalogue. La suppression enlève la référence à la clé avant de retirer le fichier. Le démarrage récupère les fichiers de contenu orphelins. L’index de recherche se construit en mémoire après authentification. Les dossiers de coffre sont exclus de la sauvegarde système automatique.

`BlockCipher` traite des trames de 1 Mio au maximum. Chaque trame authentifie l’identifiant du document et sa position. Une dernière trame vide authentifiée et la longueur attendue détectent troncature ou ajout. `PagedPDF` vérifie le document puis fournit des plages à Core Graphics et rend une page à la fois. Un index d’offsets et un bloc déchiffré servent les accès aléatoires. L’export authentifie le contenu avant d’ouvrir, en création exclusive, le fichier explicitement choisi. Une interruption brutale du processus pendant cet export peut laisser un export partiel à cette destination.

`VaultAccess` lit la clé protégée dans le Trousseau. `LockerModel` retire les métadonnées affichées et invalide une autorisation de session partagée avec les lecteurs et les transferts au verrouillage. Sur iOS, une fenêtre opaque masque le contenu dès la désactivation. Sur Mac, la désactivation masque la fenêtre et verrouille la session. Le délai d’inactivité utilise une horloge monotone.

## Moteur de synchronisation

Le catalogue et sa file persistante sont validés dans la même écriture. Chaque entrée de file désigne un identifiant et une révision. Une réponse réseau tardive peut acquitter uniquement cette révision. Le moteur tourne au premier plan dès l’ouverture, après une modification, puis environ toutes les 30 secondes. Une application suspendue ou un coffre verrouillé reprend à la prochaine ouverture. Chaque coffre a sa configuration chiffrée et son propre état. Aucun client réseau ne participe au chemin de lecture d’un document local.

Les trois adaptateurs implémentent `ObjectBucket`. Les documents volumineux transitent en pièces chiffrées de 4 Mio. Le nom d’une pièce est son SHA-256. L’envoi reprend à partir de l’inventaire du fournisseur. Le téléchargement reprend à partir du cache local de pièces dont le hachage est revérifié, puis l’AES-GCM authentifie le document reconstitué. La liste distante peut être parcourue en entier, mais les révisions déjà acquittées et les pièces présentes évitent de retransférer le contenu inchangé. Le cache local de transfert est libéré après une synchronisation réussie. Les morceaux distants orphelins chiffrés peuvent continuer à occuper de l’espace chez le fournisseur.

Pour un coffre personnel, les versions CloudKit, les révisions Dropbox et les ETag WebDAV conditionnent la publication du manifeste. Deux ajouts de contenu ont des identifiants distincts et conservent leur filiation. Deux modifications de métadonnées conservent les deux fiches dans l’historique. Un compteur logique, puis l’UUID de révision, déterminent la fiche courante. Un marqueur de suppression est définitif pour la version concernée.

## Gestion des identités et du partage

`DeviceIdentity`, `Policy`, `FamilyInvitation` et `FamilyEvent` vérifient les identités, la portée et les signatures indépendamment du fournisseur. Les identités matérielles P-256 utilisent le Secure Enclave lorsqu’il est disponible. Les représentations des clés privées et les jetons sont stockés dans le Trousseau et liés au coffre local. Le moteur familial ne transmet jamais la clé personnelle du propriétaire.

Le modèle familial conserve des événements signés immuables pour les écritures courantes. Une suppression publiée remplace les anciennes enveloppes de clé de ce document dans l’espace actif par un marqueur signé. Le service peut conserver ses propres révisions ou sauvegardes. Les certificats de politique forment une chaîne vérifiée depuis le point approuvé par invitation. Les modifications concurrentes de politique incompatibles suspendent les échanges et préservent le contenu local. Pour résoudre une divergence administrative, comparer les politiques entre administrateurs et rejoindre la branche convenue dans un coffre vide avec une nouvelle invitation, après conservation des versions locales à récupérer.

## Limites opérationnelles

- Le catalogue et les listes de révisions résident en mémoire. Le coût du transfert d’un gros fichier reste borné par la taille des pièces, mais le coût du catalogue augmente avec le nombre de versions.
- Un fournisseur peut supprimer, retarder ou dissimuler des objets. Une première installation qui ne possède aucun point de contrôle récent ne peut pas établir seule la fraîcheur globale des données. Une sauvegarde indépendante reste nécessaire pour se protéger d’une perte du fournisseur.
- Un coffre n’utilise qu’un fournisseur actif. Une migration de famille doit être coordonnée entre les membres. Le propriétaire qui a l’historique des politiques peut initialiser un nouvel espace vide. L’ancien espace et ses autorisations côté fournisseur doivent être gérés séparément.
- Les téléchargements déjà effectués restent accessibles en l’absence de réseau jusqu’à la réception d’une révocation. Le nouvel état supprime les documents devenus inaccessibles dans le catalogue local. Un destinataire peut conserver une copie indépendante. Si le fournisseur lui a déjà retiré l’accès à la zone, l’appareil peut ne jamais recevoir cette notification et garder son cache antérieur.
- Un administrateur familial signe les droits dans Locker. L’ajout d’un nouveau compte au transport nécessite également les droits accordés par ce fournisseur, notamment ceux du propriétaire de zone sur iCloud. Pour un compte déjà admis au transport, utiliser l’option correspondante dans l’invitation.
- Les tests utilisent des identités et des documents fictifs. La validation matérielle et celle des vrais services sont décrites dans le bilan.
