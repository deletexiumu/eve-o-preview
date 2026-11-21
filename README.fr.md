<p align="center"><img src="packaging/AppIcon.png" width="128" alt="Icône d'EVE-O Preview for macOS"></p>

# EVE-O Preview for macOS

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Русский](README.ru.md) | **Français** | [Deutsch](README.de.md) | [Español](README.es.md)

Cette traduction a été produite automatiquement ; en cas de divergence avec le [README anglais](README.md), c'est la version anglaise qui fait foi.

EVE-O Preview for macOS affiche une vignette en direct de chaque client EVE Online en cours d'exécution. Cliquez sur une vignette ou appuyez sur un raccourci global pour basculer vers ce client.

Il s'agit d'une réimplémentation native en Swift, pour macOS, des fonctionnalités d'[EveOPlus/eve-o-preview](https://github.com/EveOPlus/eve-o-preview) (Windows, GPL-3.0). Elle ne porte pas le code C# du projet d'origine, et son interface comme son format de configuration diffèrent de ceux du projet d'origine.
Elle est distribuée sous la GNU General Public License version 3 ou toute version ultérieure (GPL-3.0-or-later), conformément aux identifiants SPDX des fichiers source ; le projet d'origine est distribué sous GPL-3.0. Le texte complet figure dans [LICENSE](LICENSE).

Ce dépôt a commencé comme un fork GitHub d'EveOPlus/eve-o-preview et a été déplacé vers un dépôt indépendant pour la v1.0. C'est un projet indépendant : il ne partage aucun code avec la version Windows et n'est pas maintenu par les auteurs du projet d'origine.

## Fonctionnalités

- Détection des clients : les vignettes se mettent à jour automatiquement quand un client démarre, se ferme ou change de nom après la connexion.
- Vignettes en direct : un flux ScreenCaptureKit par client, avec une taille et une fréquence d'images réglables.
- Panneaux des vignettes : ils ne prennent jamais le focus, apparaissent sur tous les Spaces et peuvent, en option, rester au premier plan. Par défaut, ils ont une bordure gris clair de 2 points pour distinguer facilement les vignettes voisines ; la couleur et l'épaisseur sont réglables, et la bordure peut être désactivée.
- Bascule : un clic gauche sur une vignette bascule vers son client ; Ctrl+clic le réduit. Le menu contextuel propose « Réduire », « Tout réduire », « Ignorer dans le cycle », « Masquer cette vignette » et « Rétablir la taille par défaut ».
- Superpositions : nom du personnage en titre, bordure de surbrillance sur le client actif (couleur réglable par personnage ; elle remplace la bordure gris clair tant qu'elle est affichée) et marqueur « ignoré dans le cycle ».
- « Zoom au survol » (9 points d'ancrage) et opacité.
- Visibilité : masquer la vignette du client actif ; masquer quand EVE n'est pas au premier plan (avec un délai) ; masquer par personnage ; tout masquer.
- Disposition : glisser pour déplacer et redimensionner, avec aimantation aux autres vignettes et aux bords de l'écran, et verrouillage facultatif de la disposition. La position et la taille sont enregistrées par personnage ; les clients sur l'écran de connexion utilisent une position de départ distincte.
- Groupes de cycle : raccourcis « suivant » et « précédent », possibilité d'ignorer un personnage pendant la session en cours ; raccourcis par personnage ; un raccourci pour parcourir les clients sur l'écran de connexion ; raccourcis pour tout masquer et tout réduire. Les raccourcis peuvent utiliser le bouton central et les boutons latéraux de la souris, et chaque raccourci peut être global ou limité à EVE.
- Alertes de combat (désactivées par défaut) : l'app lit les journaux de jeu et fait clignoter la vignette d'un personnage quand celui-ci est attaqué.
- Overlay de renseignement (désactivé par défaut) : lit les journaux de discussion des canaux de renseignement que vous choisissez et affiche, pour le personnage de la fenêtre EVE au premier plan, dans quels systèmes des hostiles sont signalés, à combien de sauts ils se trouvent, combien ils sont et sur quels vaisseaux (voir [Overlay de renseignement](#overlay-de-renseignement)).
- Overlay de traduction du chat (désactivé par défaut) : traduit dans votre langue les messages en d'autres langues des canaux que vous choisissez, avec un service de modèle de votre choix et votre propre clé d'API (voir [Traduction du chat](#traduction-du-chat)).
- Profils : création, duplication, changement de nom, suppression et changement de profil.
- Mises à jour : l'app recherche les nouvelles versions sur GitHub et les installe depuis l'app après avoir vérifié le téléchargement et sa signature de code (voir [Mises à jour](#mises-à-jour)).
- Rapports de problème : l'app crée un zip de diagnostic anonymisé et ouvre une issue GitHub préremplie ; après un arrêt inopiné, le lancement suivant propose de le signaler (voir [Signaler un problème](#signaler-un-problème)).
- Une icône dans la barre des menus à la place de l'icône de la zone de notification de Windows.
- Une fenêtre de réglages de 10 pages : « Clients », « Vignettes », « Raccourcis », « Alertes », « Renseignement », « Traduction », « Profils », « Général », « Autorisations » et « À propos ».
- Langues de l'interface : anglais (par défaut), chinois, russe, japonais, coréen, français, allemand et espagnol. Changez de langue dans la page « Général », ou choisissez « Selon le système » ; le changement prend effet immédiatement. Les traductions russe, japonaise, coréenne, française, allemande et espagnole sont générées automatiquement ; les corrections sont les bienvenues.

## Fonctionnalités du projet d'origine non portées

| Fonctionnalité du projet d'origine | Raison |
| --- | --- |
| Limitation de la fréquence d'images et coupure sélective du son (injection Robin) | Le projet d'origine injecte une DLL dans les processus Windows ; macOS n'a pas de mécanisme public équivalent |
| Affinité processeur | Repose sur les CPU Sets de Windows ; Apple Silicon n'a pas d'API publique pour attacher un processus à des cœurs |
| Augments du journal de combat : chiffres de dégâts, DPS, quantités de réparation, superposition du système, données statiques pour FC | Un vaste sous-système séparé, hors du périmètre « aperçu et bascule » ; seul le « clignotement en cas d'attaque » a été porté |
| Thèmes, ancienne interface, styles personnalisés du menu contextuel | La version macOS suit l'apparence du système |
| Mode de capture de compatibilité (`PrintWindow`) | ScreenCaptureKit est la seule méthode de capture |
| Hook clavier de bas niveau | Les raccourcis clavier utilisent les raccourcis globaux Carbon ; une interception des événements souris n'est créée que lorsqu'un bouton de souris est attribué |

Les régions avec ancrage par glisser-déposer, la sélection multiple et le déplacement groupé, l'annulation, les guides d'aimantation, l'importation des configurations Windows et le lancement à l'ouverture de session sont prévus après la v1.

## Configuration requise

- macOS 14 ou ultérieur, sur Apple Silicon ou Intel. Le dmg de la version contient un binaire universel.
- Les clients EVE fonctionnent le mieux en mode fenêtré. Les clients en plein écran natif sont pris en charge depuis la 1.1.1 (les vignettes s'affichent par-dessus tant que « Garder les vignettes au premier plan » est activé), mais chacun occupe son propre Space, si bien que basculer vers l'un d'eux lance l'animation de changement de Space.
- La compilation depuis les sources nécessite Xcode ou les Command Line Tools (Swift 6).

## Installation

### Télécharger une version

1. Téléchargez `EVE-O-Preview-<version>.dmg` depuis la page [Releases](https://github.com/deletexiumu/eve-o-preview-macos/releases).
2. Ouvrez le dmg et faites glisser `EVE-O Preview.app` dans le dossier Applications.
3. Ouvrez l'app. Son icône apparaît dans la barre des menus et, au premier lancement, la fenêtre de réglages s'ouvre sur la page « Autorisations ».

Les versions publiées sont signées avec le certificat auto-signé du projet et ne sont pas notarisées, car le projet n'a pas d'identifiant Apple Developer ID. Au premier lancement, macOS bloque l'app avec un message indiquant qu'il ne peut pas vérifier le développeur. Pour l'ouvrir :

1. Ouvrez Réglages Système > Confidentialité et sécurité.
2. Faites défiler jusqu'au message concernant EVE-O Preview et cliquez sur « Ouvrir quand même », puis confirmez.

Si macOS indique que l'app « est endommagée et ne peut pas être ouverte », ou à la place des étapes ci-dessus, supprimez l'attribut de quarantaine dans Terminal :

```sh
xattr -dr com.apple.quarantine "/Applications/EVE-O Preview.app"
```

**Remarque :** chaque version est signée avec le même certificat, donc macOS conserve les autorisations « Enregistrement de l'écran » et « Accessibilité » lors d'une mise à niveau. Si les autorisations ne fonctionnent plus après une mise à niveau, réinitialisez-les avec les commandes `tccutil` à la fin de la section [Autorisations](#autorisations), puis accordez-les de nouveau.

Depuis la 1.1.0, l'app peut se mettre à jour elle-même (voir [Mises à jour](#mises-à-jour)). La version 1.0.0 n'a pas de système de mise à jour : installez donc la 1.1.0 une fois à la main en téléchargeant le dmg et en remplaçant l'app dans Applications. Les autorisations sont conservées, car la 1.0.0 et les versions suivantes sont signées avec le même certificat.

Chaque version inclut aussi le code source au format `.tar.gz` et `.zip`, ainsi qu'un fichier `SHA256SUMS.txt`. Pour vérifier les téléchargements, exécutez `shasum -a 256 --ignore-missing -c SHA256SUMS.txt` dans le dossier de téléchargement.

### Compiler depuis les sources

1. À la racine du dépôt, exécutez `scripts/build-app.sh`. Le script compile la configuration release, puis assemble et signe `dist/EVE-O Preview.app`.
2. Faites glisser `dist/EVE-O Preview.app` dans le dossier Applications.
3. Ouvrez l'app.

Le script lit les variables d'environnement suivantes :

| Variable | Rôle | Valeur par défaut |
| --- | --- | --- |
| `VERSION` | Numéro de version écrit dans `Info.plist` | Contenu du fichier `VERSION` |
| `SIGN_IDENTITY` | Identité de signature de code | `EVEO Preview Dev` s'il se trouve dans le trousseau, sinon ad hoc (`-`) |
| `UNIVERSAL` | `1` compile arm64 et x86_64 séparément et les fusionne avec `lipo` en un binaire universel | Non définie : architecture native uniquement |

Si `packaging/AppIcon.png` existe, le script l'utilise pour générer l'icône de l'app.

`scripts/package-release.sh` exécute `build-app.sh`, puis écrit le dmg, les archives des sources et `SHA256SUMS.txt` dans `dist/release/`. La CI utilise ce script.

## Autorisations

L'app utilise les autorisations système ci-dessous, toutes accordées dans Réglages Système > Confidentialité et sécurité. La page « Autorisations » de la fenêtre de réglages affiche leur état, avec des boutons de demande et des liens vers Réglages Système.

| Autorisation | Utilisée pour | Sans elle |
| --- | --- | --- |
| Enregistrement de l'écran | Capturer les fenêtres des clients et lire les titres des fenêtres | Les vignettes affichent un texte d'attente ; si Accessibilité manque aussi, les titres ne peuvent pas être lus et les clients apparaissent comme `EVE (PID)` |
| Accessibilité | Restaurer, mettre au premier plan et réduire les fenêtres des clients, lire les titres des fenêtres, intercepter les raccourcis souris | Seul le processus du client peut être activé, donc les fenêtres réduites ne peuvent pas être restaurées ; « Réduire » et « Tout réduire » sont désactivés ; les raccourcis souris ne fonctionnent pas, les raccourcis clavier si |
| Dossier Documents | Les alertes de combat lisent `~/Documents/EVE/logs/Gamelogs` ; les overlays de renseignement et de traduction lisent `~/Documents/EVE/logs/Chatlogs`, et l'overlay de renseignement lit aussi les journaux de jeu pour connaître votre position | Demandée uniquement quand l'une de ces fonctionnalités est activée ou quand vous choisissez « Ajouter depuis les journaux » ; en cas de refus, la page de la fonctionnalité en indique la raison et les autres fonctionnalités ne sont pas affectées |

Après avoir accordé « Enregistrement de l'écran », il faut généralement relancer l'app pour que l'autorisation prenne effet ; la page « Autorisations » propose un bouton « Relancer ». « Accessibilité » prend effet immédiatement.

### Signer avec un certificat auto-signé

macOS identifie une app par sa signature de code lorsqu'il enregistre les autorisations. Une signature ad hoc n'a pas d'identité stable : après chaque recompilation, macOS considère l'app comme une autre app et les deux autorisations sont perdues. Si vous compilez vous-même l'app, utilisez un certificat auto-signé :

1. Ouvrez Trousseau d'accès et choisissez Trousseau d'accès > Assistant de certification > Créer un certificat.
2. Saisissez le nom `EVEO Preview Dev`, réglez « Type d'identité » sur « Racine auto-signée » et « Type de certificat » sur « Signature de code », puis créez le certificat.
3. Exécutez `scripts/build-app.sh`. Le script utilise automatiquement ce certificat s'il le trouve dans le trousseau ; vous pouvez aussi exécuter `SIGN_IDENTITY="EVEO Preview Dev" scripts/build-app.sh`.
4. Si macOS demande si `codesign` peut utiliser la clé privée du trousseau, choisissez « Toujours autoriser ».

Si les enregistrements d'autorisation se retrouvent dans un mauvais état, exécutez ces deux commandes et accordez de nouveau les autorisations :

```sh
tccutil reset ScreenCapture io.github.deletexiumu.eveopreview-macos
tccutil reset Accessibility io.github.deletexiumu.eveopreview-macos
```

## Utilisation

### Gestes sur les vignettes

Un appui du bouton gauche bascule immédiatement, sans attendre le relâchement ; le déplacement et le redimensionnement se font donc par glissement avec le bouton droit ou avec Option+bouton gauche.

| Action | Geste |
| --- | --- |
| Basculer vers le client | Appui du bouton gauche |
| Réduire le client | Ctrl+appui du bouton gauche |
| Ouvrir le menu | Clic droit (déplacement de moins de 4 points entre l'appui et le relâchement) |
| Déplacer | Glissement avec le bouton droit, ou Option+glissement avec le bouton gauche |
| Redimensionner | Même geste que pour déplacer, en commençant à moins de 12 points du bord de la vignette |
| Désactiver temporairement l'aimantation | Maintenir Shift pendant le glissement ; pendant un redimensionnement, Shift conserve aussi les proportions |

Quand « Verrouiller la disposition » est activé, le déplacement et le redimensionnement sont sans effet ; la bascule, la réduction et le menu fonctionnent toujours.

### Raccourcis

Enregistrez les raccourcis dans la page « Raccourcis » de la fenêtre de réglages : cliquez sur un bouton, puis appuyez sur une combinaison de touches ou sur un bouton de souris. Esc annule et Delete efface. Une action peut avoir plusieurs raccourcis.

- Groupes de cycle : chaque groupe a des raccourcis « suivant » et « précédent » qui basculent, dans l'ordre, entre les personnages du groupe qui sont en ligne et non ignorés, en revenant au début après le dernier.
- Raccourcis par personnage : basculent vers le client de ce personnage.
- Raccourcis généraux : afficher ou masquer toutes les vignettes, réduire tous les clients et parcourir les clients sur l'écran de connexion.

Les raccourcis clavier doivent inclure Ctrl, Option ou Command ; F1–F20 et les chiffres du pavé numérique peuvent être utilisés seuls. Les combinaisons système comme Cmd+Tab, Cmd+Espace et Cmd+Q sont refusées. Quand un raccourci pose problème, la fenêtre de réglages en affiche la raison à côté.

Raccourcis souris :

- Le bouton central et les boutons latéraux peuvent être enregistrés (écrits `Mouse3`–`Mouse32` dans la configuration), éventuellement avec des touches de modification, par exemple `ctrl+Mouse4`. Les boutons gauche et droit ne peuvent pas être attribués.
- Quand un raccourci se déclenche, ce clic (appui, glissement et relâchement) n'est pas transmis à l'app au premier plan ; une action du jeu attribuée au même bouton ne s'exécute donc pas.
- Les raccourcis souris nécessitent l'autorisation « Accessibilité ».

Portée :

- Chaque raccourci peut être « Global » ou « Seulement dans EVE », ce qui s'écrit avec le suffixe `@global` ou `@game` dans la configuration. Un raccourci sans suffixe suit la portée par défaut du profil.
- Un raccourci « Seulement dans EVE » ne fonctionne que lorsqu'un client EVE est au premier plan. Dans les autres apps, l'appui sur la touche leur est transmis normalement.
- Les raccourcis souris nouvellement enregistrés sont par défaut « Seulement dans EVE », afin que les boutons latéraux ne soient pas interceptés dans toutes les apps.
- « Raccourcis seulement dans EVE » dans le menu de la barre des menus bascule la portée par défaut.

### Alertes de combat

Activez-les dans la page « Alertes » de la fenêtre de réglages. L'app lit alors les journaux de jeu que les clients écrivent dans `~/Documents/EVE/logs/Gamelogs`, associe chaque journal à un personnage d'après le champ Listener de l'en-tête du journal, et fait clignoter la bordure et l'image de la vignette d'un personnage pendant 3 secondes quand ce personnage est attaqué.

- L'enregistrement des journaux de jeu doit être activé dans le client EVE (c'est le cas par défaut).
- Les attaques manquées déclenchent aussi une alerte par défaut ; cela peut être désactivé. Les dégâts minimum, la couleur et la durée du clignotement sont réglables.
- Quand « Masquer les vignettes quand EVE n'est pas au premier plan » est activé, la vignette d'un personnage attaqué s'affiche temporairement.
- Quand « Réduire les animations » est activé dans Réglages Système, le clignotement est remplacé par une surbrillance fixe.
- L'app ne fait que lire les journaux. Elle ne les écrit ni ne les modifie jamais, et n'envoie aucune entrée au jeu.
- La première fois, macOS demande l'accès au dossier Documents. Si vos journaux se trouvent ailleurs, choisissez le dossier dans la page « Alertes ».
- Le format des journaux du client chinois a été vérifié sur de vrais journaux. Les lignes de dégâts japonaises et russes ont été vérifiées sur de vrais journaux de client (les échantillons enregistrés par le projet d'origine) ; leurs lignes d'attaques manquées sont seulement déduites des modèles. L'anglais, l'allemand, le français, l'espagnol et le coréen sont déduits des modèles du projet d'origine et n'ont pas été vérifiés sur de vrais journaux.

### Overlay de renseignement

Activez-le avec « Afficher l’overlay de renseignement » dans la page « Renseignement » de la fenêtre de réglages, ou avec « Afficher l’overlay de renseignement » dans le menu de la barre des menus. L'app lit alors les journaux de discussion que les clients écrivent dans `~/Documents/EVE/logs/Chatlogs`, à côté du dossier des journaux de jeu choisi dans la page « Alertes ». Chaque ligne de l'overlay est un message de vos canaux de renseignement : son âge, chaque système avec son statut de sécurité et sa distance en sauts depuis votre position, le nombre d'hostiles, les vaisseaux et les noms des pilotes.

- Le client EVE doit être réglé pour enregistrer le chat dans un fichier.
- Canaux : choisissez « Ajouter depuis les journaux » pour choisir parmi les canaux de vos journaux de discussion récents (chacun indique combien de vos personnages s'y trouvent), ou saisissez un nom de canal puis appuyez sur Retour. « Actualiser » relit les journaux. 16 canaux au maximum. Les conversations privées ne sont jamais lues ni listées.
- À l'activation, l'overlay se remplit avec les messages des 30 dernières minutes (« Conserver les dernières », 5–120 minutes) ; les lignes plus anciennes disparaissent.
- Position : les sauts sont comptés depuis le système où se trouve le personnage actif. L'app la tire des lignes de saut et de désamarrage des journaux de jeu et des messages de changement de système du journal de discussion Local. Si aucune n'est disponible, saisissez un nom de système pour ce personnage sous « Ma position » puis appuyez sur Retour ; un nom inconnu affiche « Système introuvable ». Le saut suivant remplace une position manuelle, et une position manuelle est conservée après un redémarrage. Un personnage sans aucune position compte les sauts depuis le « Système de référence ».
- « Compter jusqu’à » limite le nombre de sauts (1–30, 15 par défaut). « Surligner dans un rayon de » surligne un message quand un système signalé est à ce nombre de sauts ou moins (5 par défaut ; 0 le désactive). « Afficher le texte original » ajoute l'expéditeur et le message en deuxième ligne.
- Les noms de systèmes et de vaisseaux s'affichent dans la langue de l'interface.
- Les noms de pilotes sont ce qui reste d'un message une fois les systèmes, vaisseaux et nombres reconnus ; des noms avec espaces qui se suivent sont donc ambigus. Avec « Vérification des noms en ligne (ESI) » activée (par défaut), l'app demande à l'ESI de CCP lesquels de ces mots sont de vrais noms de personnages et les sépare en conséquence (voir [Confidentialité](#confidentialité)). Une correspondance signifie seulement qu'un personnage porte ce nom, pas que c'est lui qui est désigné. Un nom trouvé reçoit un lien zKillboard sous « Ouvrir dans le navigateur » dans le menu contextuel. « Vider le cache des noms » supprime les noms enregistrés.

### Traduction du chat

Activez-la avec « Afficher la superposition de traduction » dans la page « Traduction », ou avec « Afficher l’overlay de traduction » dans le menu de la barre des menus. Elle traduit les messages des canaux choisis qui ne sont pas déjà dans la langue cible.

1. Choisissez les canaux comme pour l'overlay de renseignement ; « Ajouter depuis les journaux » liste aussi les canaux intégrés Local, Corporation, Alliance et Flotte.
2. Sous « Traduire en », choisissez une langue, ou « Langue de l'interface » (par défaut).
3. Choisissez un « Service » : DeepSeek (par défaut), Claude (Anthropic), OpenAI, Qwen (DashScope), Kimi (Moonshot), Ollama, ou « Autre (compatible OpenAI) ». « Adresse d'API » et « Nom du modèle » affichent les valeurs du préréglage ; saisissez-en d'autres pour les remplacer.
4. Collez votre clé d'API et cliquez sur « Enregistrer ». La clé est stockée dans le trousseau macOS ; « Supprimer la clé » la retire. Ollama n'a pas besoin de clé.
5. Cliquez sur « Tester » pour traduire une phrase d'exemple fixe.

- Seuls les messages reçus par le personnage du client actif sont envoyés au modèle. Une même phrase n'est traduite qu'une fois, puis reprise du cache. Les messages qui ne contiennent que des systèmes et des vaisseaux ne sont pas envoyés. Quand la langue cible est le chinois, le japonais, le coréen ou le russe, les messages déjà dans cette langue ne le sont pas non plus. Les noms de systèmes, de régions et de vaisseaux prennent leur nom officiel dans la langue cible.
- Chaque ligne affiche l'heure EVE, le canal (seulement si vous traduisez plus d'un canal), l'expéditeur et la traduction. « Afficher aussi le texte original » ajoute l'original en dessous ; « N'afficher que les messages traduits » masque les messages ignorés parce qu'ils sont déjà dans la langue cible.
- Si le service refuse la clé ou si le quota est épuisé, la traduction se met en pause et la ligne d'état en donne la raison ; « Réessayer maintenant » relance une tentative.
- Les adresses publiques doivent utiliser `https` ; `http` n'est accepté que pour ce Mac ou le réseau local, par exemple Ollama à `http://127.0.0.1:11434/v1`.
- Les requêtes utilisent votre compte auprès du service choisi et peuvent être payantes.
- Après une recompilation avec une autre signature, macOS peut demander l'autorisation de lire l'élément du trousseau quand vous cliquez sur « Tester » ou « Réessayer maintenant ». Les lectures en arrière-plan n'affichent jamais cette demande ; la ligne d'état vous invite plutôt à enregistrer de nouveau la clé.

### Gestes sur les overlays

Les overlays de renseignement et de traduction sont des panneaux distincts qui se comportent comme les vignettes : ils ne prennent jamais le focus, apparaissent sur tous les Spaces et n'affichent que le personnage de la fenêtre EVE au premier plan, en changeant de contenu dès que vous changez de client. Les clics ne traversent pas jusqu'au jeu. Le message le plus récent est en bas et la liste y reste. Si vous faites défiler vers le haut, la liste cesse de suivre les nouveaux messages et une barre « N nouveaux » apparaît en bas ; cliquez dessus pour revenir au plus récent.

| Action | Geste |
| --- | --- |
| Faire défiler la liste | Molette ou balayage à deux doigts |
| Déplacer | Glissement avec le bouton droit, ou Option+glissement avec le bouton gauche |
| Redimensionner | Même geste que pour déplacer, en commençant à moins de 12 points du bord de l'overlay |
| Désactiver temporairement l'aimantation | Maintenir Shift pendant le glissement |
| Ouvrir le menu | Clic droit (déplacement de moins de 4 points entre l'appui et le relâchement) |
| Revenir au plus récent | Cliquer sur la barre « N nouveaux » |

Le menu contextuel propose « Faire défiler jusqu’au plus récent », « Copier cette ligne », « Ouvrir dans le navigateur » (seulement sur les lignes avec des liens), « Vider la liste », « Verrouiller la disposition », « Rétablir la position et la taille », « Masquer cet overlay » et « Ouvrir les réglages… ». « Opacité du fond » (20–100 %, le fond seulement ; le texte reste opaque) et « Taille du texte » (10–24 points) se trouvent dans la page de chaque fonctionnalité. « Verrouiller la disposition » et « Masquer les vignettes quand EVE n'est pas au premier plan » s'appliquent aussi aux overlays ; « Masquer toutes les vignettes » ne concerne que les vignettes.

### Barre des menus

L'icône de la barre des menus reprend l'icône de l'app : une molécule dans un octogone. Le menu propose : « Afficher toutes les vignettes » ou « Masquer toutes les vignettes », le changement de profil, « Réduire tous les clients », « Raccourcis seulement dans EVE », « Afficher l’overlay de renseignement », « Afficher l’overlay de traduction », « Rechercher les mises à jour… », « Signaler un problème… », « Réglages… » et « Quitter EVE-O Preview ». Quand une mise à jour est disponible ou que la session précédente s'est arrêtée inopinément, un point apparaît sur l'icône et le menu affiche un élément correspondant en haut. Quand une autorisation manque, le menu comporte un élément supplémentaire à ce sujet. Si vous arrêtez la capture d'un client depuis l'indicateur d'enregistrement du système, le menu affiche un élément « Reprendre la capture ».

EVE-O Preview affiche aussi son icône dans le Dock ; un clic dessus ouvre la fenêtre de réglages. Pour ne garder que l'icône de la barre des menus, décochez « Afficher l'icône dans le Dock » dans Réglages > Général.

### Mises à jour

EVE-O Preview recherche une nouvelle version sur GitHub au lancement, puis une fois par jour. Pour désactiver cette recherche, décochez « Rechercher automatiquement les mises à jour » dans Réglages > Général > Mises à jour ; « Rechercher les mises à jour… » dans le menu de la barre des menus permet toujours de lancer une recherche à la demande.

Quand une nouvelle version est disponible, une fenêtre affiche les notes de version dans la langue de votre interface (en anglais s'il n'existe pas de traduction) et propose « Installer la mise à jour », « Ignorer cette version » et « Plus tard ». Tant qu'un client EVE est au premier plan, la fenêtre attend que vous passiez à autre chose, et elle ne prend jamais d'elle-même le focus clavier ; un point sur l'icône de la barre des menus signale qu'une mise à jour est en attente. « Ignorer cette version » n'arrête que les rappels automatiques pour cette version ; « Rechercher les mises à jour… » l'affiche toujours.

« Installer la mise à jour » télécharge le dmg, le vérifie avec `SHA256SUMS.txt`, s'assure que la nouvelle app est signée avec le même certificat que celle en cours d'exécution, remplace l'app et la redémarre. Si une étape échoue, l'app installée reste inchangée. « Installer automatiquement les mises à jour » est activé par défaut : la mise à jour est téléchargée en arrière-plan, puis installée et l'app redémarrée dès qu'aucun client EVE n'a tourné depuis environ une minute et qu'aucune fenêtre d'EVE-O Preview n'est ouverte. Sinon, elle est installée quand vous quittez EVE-O Preview, ou quand vous choisissez « Redémarrer pour passer à la version X.Y.Z » dans le menu de la barre des menus. Tant qu'un client EVE est en cours d'exécution, l'app ne redémarre jamais d'elle-même. Désactivez ce réglage dans Réglages > Général > Mises à jour si vous voulez que la fenêtre vous demande d'abord.

Certaines builds peuvent seulement afficher la raison et un bouton « Ouvrir la page de la version » au lieu d'installer : les builds signées ad hoc ou localement, une app exécutée depuis une image disque ou depuis un emplacement translocalisé, une app placée dans un dossier où vous ne pouvez pas écrire, et une app sur un volume qui n'est pas en APFS, comme un disque externe HFS+, exFAT ou FAT.

### Signaler un problème

Choisissez « Signaler un problème… » dans le menu de la barre des menus ou dans la page « Général », ou répondez à la proposition qui apparaît après un arrêt inopiné d'EVE-O Preview. La fenêtre liste tous les fichiers qui iront dans le rapport et affiche leur contenu après anonymisation : un résumé de l'environnement, un résumé des réglages sans aucun nom, le journal de l'app (jusqu'à 2 Mio) et jusqu'à trois rapports de plantage macOS. Rien n'est créé avant que vous cliquiez sur « Créer le rapport seulement » ou « Créer le rapport et ouvrir GitHub ». Le zip est enregistré dans `~/Library/Application Support/EVE-O Preview/Reports/` (les 3 plus récents sont conservés) et le Finder l'affiche ; « Créer le rapport et ouvrir GitHub » ouvre aussi une issue préremplie dans votre navigateur. Vous joignez le zip vous-même ; l'app n'envoie jamais rien.

Votre nom d'utilisateur macOS, votre nom complet, le chemin de votre dossier de départ et les noms de l'ordinateur sont remplacés par `[user]` et `[host]`. Les noms des personnages EVE deviennent `[character-1]`, `[character-2]` et ainsi de suite, et les identifiants d'appareil des rapports de plantage deviennent `[redacted]`. Seuls les noms connus de l'app sont remplacés : les personnages qui ne sont jamais apparus dans vos réglages ni comme client en cours d'exécution ne le sont pas. Si un nom est un mot courant, ce même mot est aussi remplacé ailleurs dans le journal. Vous pouvez lire chaque fichier avant de créer le rapport et décocher tout fichier que vous ne voulez pas inclure.

L'app conserve jusqu'à 5 fichiers journaux de 1 Mio chacun dans `~/Library/Logs/EVE-O Preview/`. Les noms des personnages et les titres des fenêtres y sont écrits sous la forme `<private>`. Activez « Journalisation détaillée » dans « Général » pour enregistrer aussi les lignes de débogage ; « Afficher les journaux dans le Finder » ouvre le dossier. Si aucune proposition n'apparaît après un plantage, joignez à la main `~/Library/Logs/DiagnosticReports/EVEOPreview-<date>.ips` à l'issue.

## Confidentialité

La version 1.0.0 n'effectuait aucune requête réseau. Depuis la 1.1.0, l'app se connecte à GitHub pour les mises à jour et n'établit aucune autre connexion, sauf si vous activez l'une des fonctionnalités facultatives décrites après cette liste :

- La recherche de mises à jour interroge `api.github.com/repos/deletexiumu/eve-o-preview-macos/releases/latest` au lancement et une fois par jour tant que « Rechercher automatiquement les mises à jour » est activé, ainsi qu'à chaque fois que vous choisissez « Rechercher les mises à jour… ».
- Lorsqu'une nouvelle version est proposée, l'app interroge aussi une fois la liste des versions `api.github.com/repos/deletexiumu/eve-o-preview-macos/releases`, avec les mêmes en-têtes, pour afficher les notes des versions que vous avez sautées.
- L'installation d'une mise à jour télécharge `SHA256SUMS.txt` et le dmg de la version.

Les requêtes ne transmettent que la version de l'app dans l'en-tête `User-Agent`, un `Accept-Language: en` fixe et une étiquette de cache ; aucun nom de personnage, réglage, journal, détail matériel, version du système ni identifiant n'est envoyé, et aucun cookie n'est utilisé. GitHub voit votre adresse IP et l'heure de la requête. Il n'y a ni télémétrie ni envoi automatique des plantages : « Signaler un problème… » crée seulement un zip sur votre Mac et ouvre une page web que vous choisissez d'envoyer ou non.

Les overlays de renseignement et de traduction ne font que lire les journaux de discussion et de jeu ; ils n'y écrivent jamais, et les conversations privées ne sont jamais lues. Deux fonctionnalités facultatives se connectent à d'autres services :

- Vérification des noms de pilotes : « Vérification des noms en ligne (ESI) » est activée par défaut dès que vous activez l'overlay de renseignement. Quand un message de renseignement reçu par le personnage actif contient des noms de pilotes de deux mots ou plus qui se suivent, l'app envoie ces mots, seuls et en combinaisons de trois au plus, à l'ESI de CCP à `esi.evetech.net/universe/ids`. Elle n'envoie ni l'expéditeur, ni le canal, ni le reste du message ; les noms de vos propres personnages n'y figurent que si quelqu'un les a écrits dans un message de renseignement. Un nom isolé d'un seul mot n'est jamais vérifié. CCP voit votre adresse IP et l'en-tête `User-Agent`, qui contient la version de l'app et l'URL du projet. Désactivez le réglage dans la page « Renseignement » pour arrêter ces requêtes. L'app elle-même ne contacte jamais zKillboard : « Ouvrir dans le navigateur » ouvre la page zKillboard d'un personnage dans votre navigateur, avec seulement l'ID du personnage dans l'adresse.
- Traduction du chat (désactivée par défaut) : le texte des messages reçus par le personnage du client actif dans vos canaux de traduction est envoyé au service de modèle choisi dans la page « Traduction », avec les noms officiels des systèmes et vaisseaux qu'ils mentionnent. Les noms des expéditeurs et des canaux ne sont pas envoyés ; « Tester » envoie une phrase d'exemple fixe. La clé d'API est stockée uniquement dans le trousseau macOS, sous le service `io.github.deletexiumu.eveopreview-macos.translation`, avec un élément par service de modèle, et n'est envoyée qu'à ce service. Elle n'apparaît jamais dans le fichier de configuration, les journaux ni les rapports de problème. Les adresses publiques doivent utiliser `https` ; `http` n'est accepté que pour ce Mac ou le réseau local, par exemple Ollama. Ce que le service fait du texte relève de ses propres conditions.

Les rapports de problème contiennent les réglages de ces fonctionnalités sous forme de nombres et d'interrupteurs (comme le nombre de canaux et le service choisi), mais aucun nom de canal ou de système, adresse d'API, nom de modèle, nom de pilote, texte de chat ni clé.

L'app stocke des données aux emplacements suivants. Pour la désinstaller complètement, supprimez-les avec l'app et `~/Library/Application Support/EVE-O Preview/config.json` :

| Emplacement | Contenu |
| --- | --- |
| `~/Library/Logs/EVE-O Preview/` | Journaux de l'app, environ 5 Mio au maximum |
| `~/Library/Application Support/EVE-O Preview/session.json`, `state.json` | Marqueur de session ; historique des mises à jour et du diagnostic ; positions manuelles du renseignement |
| `~/Library/Application Support/EVE-O Preview/Reports/` | Zips des rapports de problème que vous avez créés, anonymisés (les 3 plus récents) |
| `~/Library/Caches/io.github.deletexiumu.eveopreview-macos/Updates/` | Fichiers de mise à jour téléchargés, supprimés après l'installation |
| `~/Library/Application Support/EVE-O Preview/pilot-names.json` | Noms de pilotes et ID de personnages trouvés par l'ESI (données publiques du jeu), conservés 30 jours. Lisible par vous seul (0600) et jamais inclus dans les rapports de problème ; « Vider le cache des noms » dans la page « Renseignement » le vide. Les noms sans correspondance ne restent en mémoire que 6 heures |
| `~/Library/Application Support/EVE-O Preview/translation-cache.json` | Texte original et traduit des messages, sans noms d'expéditeur ni de canal. Lisible par vous seul (0600) et jamais inclus dans les rapports de problème ; « Vider le cache » dans la page « Traduction » le vide |
| Éléments du trousseau dont le service est `io.github.deletexiumu.eveopreview-macos.translation` | Vos clés d'API de traduction, une par service de modèle ; « Supprimer la clé » dans la page « Traduction » retire celle du service actuel |

## Fichier de configuration

La configuration est enregistrée dans `~/Library/Application Support/EVE-O Preview/config.json`. Un seul fichier contient tous les profils.

- Les modifications sont enregistrées automatiquement 0,5 seconde après avoir été faites, puis une dernière fois en quittant.
- Si le fichier est corrompu, il est renommé en `config.corrupt-<date-time>.json` et l'app utilise la configuration par défaut.
- Si le fichier provient d'une version plus récente, l'app fonctionne avec la configuration par défaut, n'écrit rien sur le disque pendant cette session et n'écrase pas le fichier.

La page « Profils » comporte un bouton « Afficher dans le Finder ».

## Développement

| Commande | Rôle |
| --- | --- |
| `swift build` | Compiler toutes les cibles |
| `swift test` | Exécuter les tests unitaires de Core (swift-testing) |
| `EVEO_FAKE=1 swift run EVEOPreview` | Mode démo : 3 clients fictifs avec des images animées générées, sans EVE ni aucune autorisation |
| `python3 scripts/check_quality.py` | Vérifier le taux de commentaires, la longueur des fichiers et la longueur des fonctions |
| `scripts/build-app.sh` | Assembler et signer le `.app` |
| `scripts/package-release.sh` | Produire le dmg, les archives des sources et les sommes de contrôle dans `dist/release/` |
| `swift run EVEOProbe gamelog [dir] [--follow seconds]` | Compter chaque type de ligne de combat dans les journaux de jeu, pour diagnostiquer les alertes de combat |
| `swift run EVEOProbe mousetap <seconds> [--swallow <button>]` | Afficher les numéros des boutons de souris, pour diagnostiquer les raccourcis souris |
| `swift run EVEOProbe update feed [url]` | Récupérer et analyser le flux des versions |
| `swift run EVEOProbe update verify <new app> <base app>` | Vérifier si une nouvelle app satisfait l'exigence désignée de l'app de base |
| `swift run EVEOProbe update prepare <url> [--cache dir]` | Télécharger et vérifier une mise à jour sans l'installer |
| `scripts/make-update-test-feed.sh [version]` | Écrire un `feed.json` pour un test de mise à jour local à partir de `dist/release/` |
| `swift run EVEOProbe staticdata` | Afficher où le fichier de données de carte a été trouvé, sa version de SDE, le nombre d'enregistrements et le temps de calcul d'une table de distances sur 15 sauts |
| `swift run EVEOProbe chatlog [dir] [--follow seconds]` | Afficher le dossier des journaux de discussion, les types de canaux, le nombre de messages et de lignes de position, sans noms ni texte de message |
| `swift run EVEOProbe intel [dir] [--resolve-sample] [--resolve]` | Compter les messages de renseignement, systèmes, vaisseaux et noms de pilotes des journaux de discussion récents ; `--resolve-sample` envoie trois noms inventés à l'ESI, `--resolve` envoie à l'ESI les noms de pilotes de vos journaux |
| `swift run EVEOProbe translate [--provider id] [--model name] [--base-url url] [--target language] [--dry-run]` | Envoyer un exemple fixe à un service de modèle, avec la clé lue uniquement dans `EVEO_TRANSLATION_API_KEY`. Sans `--dry-run`, c'est une vraie requête qui peut être payante |
| `python3 scripts/build-sde-data.py [--check]` | Télécharger le SDE de CCP et régénérer `packaging/eve-static.json` ; `--check` compare seulement la version du SDE |

Le mode démo écrit sa configuration dans `config-fake.json` dans le même dossier, sans toucher à la vraie configuration. Il fournit aussi deux canaux de discussion fictifs, `intel.Demo` et `chat.Demo`, traduit avec un service fictif qui préfixe chaque ligne par 〔译〕, et vérifie les noms de pilotes sans connexion réseau. Ces variables d'environnement aident au débogage :

| Variable | Rôle |
| --- | --- |
| `EVEO_CONFIG_PATH` | Utiliser le fichier de configuration indiqué |
| `EVEO_LANG` | `en`, `zh`, `ru`, `ja`, `ko`, `fr`, `de` ou `es` ; remplace la langue de l'interface définie dans la configuration |
| `EVEO_FAKE_DENY` | En mode démo, simuler l'absence d'une autorisation : `screen`, `ax` ou `screen,ax` |
| `EVEO_FAKE_STOP_AFTER` | En mode démo, simuler l'arrêt par l'utilisateur de la capture du deuxième client après ce nombre de secondes |
| `EVEO_SETTINGS_PAGE` | Ouvrir directement une page de réglages au lancement, par exemple `previews` |
| `EVEO_LOG_DIR` | Écrire les fichiers journaux dans un autre dossier (par défaut `~/Library/Logs/EVE-O Preview/`) |
| `EVEO_STATE_DIR` | Conserver `state.json` et `session.json` dans un autre dossier |
| `EVEO_LOG_PRIVATE` | `1` affiche les valeurs privées dans le journal système (Console) uniquement ; les fichiers journaux contiennent toujours `<private>` |
| `EVEO_UPDATE_FEED_URL` | Rechercher les mises à jour à cette adresse au lieu de GitHub ; uniquement `https`, ou `http` sur un hôte de bouclage. Les builds signées avec un certificat local peuvent installer depuis cette adresse ; la vérification de signature n'est pas assouplie |
| `EVEO_UPDATE_UI_STATE` | En mode démo, afficher l'interface de mise à jour dans un état d'exemple : `available`, `notifyonly`, `downloading`, `ready`, `failed` ou `uptodate` |
| `EVEO_FAKE_CRASH` | `1` en mode démo simule un plantage de la session précédente, pour afficher la proposition de rapport de plantage |
| `EVEO_STATIC_DATA` | Utiliser ce fichier de données de carte au lieu de celui fourni dans l'app |
| `EVEO_TRANSLATION_API_KEY` | Clé d'API pour `EVEOProbe translate` uniquement ; l'app ne la lit jamais |

Les données de carte et de vaisseaux des overlays de renseignement et de traduction (systèmes, régions, portails stellaires, groupes de vaisseaux et vaisseaux, avec leurs noms dans les 8 langues de l'interface) sont générées à partir de l'export de données statiques de CCP (SDE) par `scripts/build-sde-data.py` et livrées dans l'app sous la forme de `packaging/eve-static.json` ; `scripts/build-app.sh` copie ce fichier dans l'app. L'app ne télécharge pas ces données à l'exécution. Pour essayer un fichier plus récent sans recompiler, placez-le dans `~/Library/Application Support/EVE-O Preview/eve-static.json`.

Le code source comporte 3 modules : `EVEOPreviewCore` est la couche de logique pure, `EVEOPreviewPlatform` encapsule AppKit, ScreenCaptureKit, l'Accessibilité et les raccourcis Carbon, et `EVEOPreview` est l'app elle-même. L'architecture est décrite dans [docs/architecture.md](docs/architecture.md) (en chinois).

**Remarque :** quand vous exécutez directement l'exécutable avec `swift run`, macOS enregistre les autorisations au nom de votre app de terminal, et non de `EVE-O Preview.app`.

### CI et publication des versions

`.github/workflows/build.yml` s'exécute sur des runners macOS hébergés par GitHub :

- Chaque pull request vers `main`, et chaque push sur `main`, exécute le contrôle de qualité et les tests unitaires, puis produit un dmg universel et les archives des sources. Ils sont téléversés comme artefact de workflow nommé `EVE-O-Preview-<version>-pr.<number>.<commit>` (ou `-dev.<commit>` pour les push) et conservés 30 jours.
- Pousser un tag `v*` produit les mêmes fichiers et les publie comme GitHub Release. Le tag doit correspondre au fichier `VERSION`. Si `docs/release-notes/<tag>.md` existe, il devient les notes de version.

Pour publier une nouvelle version, modifiez le fichier `VERSION` et ajoutez `docs/release-notes/v<version>.md` dans une pull request, fusionnez-la, puis posez un tag sur `main` : `git tag v<version> && git push origin v<version>`.

Les noms des fichiers publiés (`EVE-O-Preview-<version>.dmg`, `SHA256SUMS.txt`), la disposition du dmg, le certificat de signature et le format des notes de version constituent un contrat avec le système de mise à jour intégré ; la CI les vérifie à chaque build. Les notes de version placent d'abord l'anglais entre `<!-- lang:en -->` et `<!-- /lang:en -->`, suivi de blocs repliables zh, ja, ko et ru balisés de la même façon ; `scripts/check_release_notes.py` vérifie les balises. Les détails figurent dans les sections 9.5 à 9.7 de [docs/architecture.md](docs/architecture.md).

## Avertissement

Cet outil ne fait que changer le focus des fenêtres. Il ne diffuse pas d'entrées vers plusieurs clients et ne lit ni ne modifie la mémoire du jeu, soit la même limite que le projet d'origine. Les overlays de renseignement et de traduction ne font que lire les fichiers journaux écrits par le client. Lisez le contrat de licence utilisateur final (CLUF) d'EVE Online avant de l'utiliser.

L'app se connecte à GitHub pour rechercher et télécharger les mises à jour. Elle ne se connecte à l'ESI de CCP et à un service de traduction que si vous activez ces fonctionnalités facultatives, et n'envoie que ce que décrit [Confidentialité](#confidentialité).

EVE Online et les logos associés sont des marques de CCP ehf. Ce projet n'est ni affilié à CCP ni approuvé par CCP.

L'icône de l'app reprend l'icône de molécule du projet d'origine EveOPlus/eve-o-preview (GPL-3.0). L'arrière-plan est dessiné par `scripts/make-app-icon.py` et ne contient aucune marque de CCP ni aucun visuel du jeu.
