# Conception du partage et modèle de menace

## Frontières de confiance

Un fournisseur curieux, un membre en lecture seule qui modifie son client, la substitution de clé pendant une invitation, le vol d’un appareil, le rejeu d’une ancienne politique et deux auteurs hors ligne constituent des menaces distinctes. Le service de stockage peut censurer les échanges. Aucun client isolé ne peut prouver qu’il voit la dernière politique mondiale. Après un effacement complet, il faut un point de confiance récent obtenu d’un appareil approuvé.

## Identité et admission

Chaque appareil présente deux clés publiques P-256, une d’accord et une de signature. L’empreinte SHA-256 de la carte publique doit être comparée sur un canal indépendant. La clé privée reste sur l’appareil. Le destinataire compare aussi l’empreinte de l’émetteur. Une invitation transporte une enveloppe HPKE RFC 9180 adressée à cette carte, liée au coffre et au destinataire. Une signature JWS au format JSON aplati avec ES256 lie le contenu exact à l’identité vérifiée. Le type protégé distingue invitations, politiques et événements. [RFC 7515](https://www.rfc-editor.org/rfc/rfc7515) · [RFC 7518](https://www.rfc-editor.org/rfc/rfc7518) Les encodages signés sont conservés tels quels pour éviter la recanonisation de JSON.

## Autorisations

Le secret de récupération personnel reste exclusivement chez le propriétaire. La clé d’époque du coffre familial est indépendante. Les membres de tout le coffre reçoivent chacun leur propre enveloppe de cette clé. Une invitation limitée transporte uniquement des clés de documents et les métadonnées autorisées. Les membres limités n’obtiennent jamais la clé générale. Chaque opération de mutation doit être signée, liée au coffre, à sa version de politique, à la version de document parente et à l’identité de l’auteur. Chaque lecteur doit vérifier la chaîne d’autorisation avant application. La connaissance d’une clé AES ne confère aucun droit d’écriture. Un administrateur approuvé autorise les changements de politique. Le transport doit en plus accorder à chaque personne son propre accès au répertoire ou à la zone partagée.

## Révocation, historique et récupération

La révocation publie une nouvelle politique signée, renouvelle les clés d’époque et exclut le membre ou l’appareil révoqué des nouvelles enveloppes. Toute nouvelle version utilise une nouvelle clé de document. Un rechiffrement explicite est nécessaire pour protéger les futures copies d’un contenu ancien. Les autres appareils refusent les politiques antérieures à leur point de contrôle et signalent les branches concurrentes. Un appareil révoqué peut garder les fichiers déjà consultés. Les révisions concurrentes doivent rester consultables. Une politique signée ancienne, même cryptographiquement valide, n’est pas une preuve actuelle d’autorisation.

La possession du code de récupération personnel exige une rotation après compromission. Le développeur ne possède aucune clé de secours. L’admission d’un appareil et la révocation de son droit d’écriture doivent utiliser le même mécanisme vérifiable que l’admission d’un membre. Un dossier Dropbox partagé ou un mot de passe WebDAV commun ne fournit pas cette garantie.

[HPKE dans CryptoKit](https://developer.apple.com/documentation/cryptokit/hpke) · [RFC 9180](https://www.rfc-editor.org/rfc/rfc9180.html)
