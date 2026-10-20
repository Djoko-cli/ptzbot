# Spec : OBSBOT Nacelle v1

Date : 2026-10-05. Statut : **validée par Majid**, puis amendée (A1 à A5, validés : voir § 12).

## 1. Objectif

Piloter depuis l'iPhone, de n'importe où, la nacelle d'une OBSBOT Tiny 2. La caméra est branchée en USB sur un Mac qui la diffuse avec go2rtc vers HomeKit, via Homebridge. L'app montre la vidéo en direct, avec un joystick pour le pan et le tilt, un réglage de zoom et un mode vie privée.

HomeKit ne sait pas commander un pan, un tilt ou un zoom. Le pilotage passe donc par un service sur le Mac. La vidéo, elle, vient directement de go2rtc.

## 2. Périmètre

**Dans la v1**

- Vidéo en direct dans l'app, par WebRTC depuis go2rtc.
- Joystick pan/tilt en vitesse, avec arrêt automatique.
- Zoom absolu, de 0 à 100.
- Mode vie privée : l'objectif est tourné vers le bas (tilt à -70°, amendement A2). La position précédente est mémorisée puis rétablie à la sortie.
- Prise en main : le suivi IA de la caméra est coupé à l'ouverture de l'écran de pilotage.
- Accès uniquement par Tailscale, à la maison comme dehors.

**Hors v1**

- Le son dans l'app. Le flux est en AAC, que WebRTC ne transporte pas. *(Intégré à la v1 par l'amendement A5.)*
- La coupure du micro en mode vie privée. **HomeKit continue de recevoir le son.**
- Les presets, le rallumage du suivi IA, les widgets, Siri et la gestion de plusieurs caméras.
- Toute modification de go2rtc ou de sa configuration.

## 3. Contraintes

| Contrainte | Conséquence |
|---|---|
| Compte Apple Developer gratuit | L'app expire après 7 jours et doit être réinstallée depuis Xcode. Choix assumé par Majid. |
| Dépôt public (MIT) | Aucune adresse IP, aucun nom d'hôte ni aucune image de la caméra dans le dépôt. Les valeurs propres à l'installation sont des réglages. |
| SDK OBSBOT propriétaire, sans licence de redistribution | Il reste dans `vendor/obsbot-sdk/`, ignoré par git. Le code qui l'utilise ne se compile qu'en local. |
| coreaudiod s'est déjà bloqué sur ce Mac | `ptzd` n'utilise ni AVFoundation ni CoreAudio. Le SDK, qui utilise les deux, ne tourne que dans un processus court et séparé. |
| OBSBOT Center ouvert fausse la relecture UVC du tilt | OBSBOT Center doit rester **fermé** pendant l'utilisation. `ptzd` journalise un avertissement s'il le détecte. |
| go2rtc est fragile (voir les outils de surveillance) | `ptzd` ne touche jamais au flux vidéo, ni au processus go2rtc, ni à sa configuration. |

## 4. Architecture

```
iPhone : app SwiftUI                         Mac (celui de go2rtc)
┌───────────────────────────┐            ┌──────────────────────────────────┐
│ VideoSession (WebRTC) ────┼─ offre ───▶│ go2rtc (inchangé)                │
│                           │◀─ images ──│   └─ ffmpeg ◀── Tiny 2 (USB)     │
│ PTZClient ────────────────┼─ WebSocket▶│ ptzd                             │
│                           │◀─ état ────│   ├─ UVC (IOKit) ──▶ Tiny 2      │
│                           │            │   └─ lance obsbot-ai-off (SDK)   │
└───────────────────────────┘            └──────────────────────────────────┘
                     tout passe par Tailscale
```

Organisation du dépôt :

| Chemin | Contenu |
|---|---|
| `Packages/NacelleProtocol/` | Paquet Swift partagé par l'app et `ptzd` : les messages du protocole, en `Codable`, avec leurs tests |
| `mac/ptzd/` | Paquet Swift du service : cibles `UVCCamera`, `PTZCore`, l'exécutable `ptzd` et les tests de `PTZCore` |
| `mac/ai-off/` | Utilitaire `obsbot-ai-off` en C++ et son script de compilation, qui demande le SDK en local |
| `mac/launchd/` | Modèle du plist de l'agent launchd |
| `scripts/install-mac.sh` | Installation sur le Mac, voir § 6.8 |
| `ios/` | Projet Xcode de l'app `Nacelle` et ses tests |

## 5. Protocole (`NacelleProtocol`)

Le protocole utilise des messages JSON, un par trame WebSocket texte, avec un champ `type`.

**De l'app vers `ptzd`**

| Message | Champs | Effet |
|---|---|---|
| `takeControl` | aucun | Lance la coupure du suivi IA (§ 6.4) |
| `move` | `pan`, `tilt` : réels de -1 à 1, bornés si hors limites | Consigne de vitesse. `0,0` arrête le mouvement. |
| `zoom` | `value` : entier de 0 à 100, borné | Zoom absolu |
| `privacy` | `on` : booléen | Entre en mode vie privée ou en sort |

**De `ptzd` vers l'app**

| Message | Champs |
|---|---|
| `state` | `camera` : `connected` ou `absent` · `control` : `idle`, `taking`, `ready` ou `failed` · `privacy` : booléen · `privacyMode` : `native` ou `tilt`, absent hors vie privée et chez un ptzd ancien (§ 6.5 bis) · `privacyReason` : en mode `tilt`, `pending` (objectif pas encore vu à −70°), `noSDK`, `updating` ou `failed`, absente pendant que le mode natif est en cours, l'objectif vu à −70° (§ 6.5 bis) · `pan`, `tilt` : degrés, ou null si inconnus · `zoom` : entier ou null · `moving` : booléen |
| `error` | `code` : `privacyActive`, `cameraAbsent`, `uvcFailed` ou `badMessage` · `message` : texte lisible |

`ptzd` envoie un `state` complet à chaque nouvelle connexion, puis à chaque changement. Un message inconnu ou mal formé reçoit une réponse `error`/`badMessage` et n'a aucun autre effet.

## 6. `ptzd`, le service sur le Mac

### 6.1 Modules

| Module | Rôle | Dépendances |
|---|---|---|
| `UVCCamera` | Trouve la Tiny 2 (VID `0x3564`, PID `0xFEF8`). Envoie les requêtes UVC par `DeviceRequestTO`, **sans ouvrir la caméra en exclusivité**. Borne les ordres absolus à la course réellement acceptée (amendement A2). Signale les branchements et débranchements (notifications IOKit). | IOKit |
| `PTZController` | Toute la logique : vitesse, arrêt automatique, zoom, vie privée, prise en main, persistance. Il ne voit la caméra, l'horloge, le lanceur d'utilitaire et le stockage qu'à travers des protocoles. | `NacelleProtocol` |
| `Server` | Le serveur WebSocket, sur `NWListener`, à l'écoute sur l'adresse Tailscale et sur 127.0.0.1 (amendement A1). Il décode les messages, appelle le contrôleur et diffuse l'état. Il accepte 4 clients au plus ; s'il y en a plusieurs, la dernière commande l'emporte. Une place morte est libérée : connexion pas prête 10 s après l'acceptation, connexion en attente (réseau perdu), échec d'envoi, ou pas de pong 25 s durant (le serveur envoie un ping toutes les 10 s) ; chaque cas est journalisé. | Network.framework |
| `Config` | Lit le fichier `config.json` décrit en § 6.7 | Foundation |

### 6.2 Mouvement

- **Commande UVC** : PanTilt en vitesse (sélecteur `0x0E` du Camera Terminal 1, interface 0).
- **Courbe de vitesse** : `vitesse = round(|x|² × max)`. La valeur `max` vient de la config (pan 40 et tilt 60 par défaut). Si le résultat est 0 alors que `x ≠ 0`, la vitesse passe à 1.
- **Sens** : `signe(x) × config.panDirection` (ou `tiltDirection`), chacun valant +1 ou -1, à étalonner une fois.
- **Pas de doublons** : une commande UVC n'est envoyée que si le sens ou la vitesse calculés changent.
- **Arrêt automatique** : sans message `move` depuis 300 ms, `ptzd` envoie l'arrêt (sens 0). Même chose à la fermeture d'une connexion, si c'était elle qui pilotait en dernier.
- **Position** : relue (`GET_CUR` PanTilt absolu) toutes les secondes pendant un mouvement et juste après chaque arrêt. Elle est publiée dans `state`.

### 6.3 Zoom

- **Commande UVC** : Zoom absolu (sélecteur `0x0B`), valeur bornée de 0 à 100.
- **Débit** : si les messages arrivent plus vite que 10 par seconde, seule la dernière valeur est envoyée.

### 6.4 Prise en main (`takeControl`)

1. `control` passe à `taking`, puis `ptzd` lance `obsbot-ai-off`. Si l'utilitaire tourne déjà, le nouveau `takeControl` attend le même résultat au lieu d'en lancer un second.
2. **Code de sortie 0** : `control` passe à `ready`. Tout autre code, ou plus de 15 s d'exécution, qui entraîne un SIGTERM : un seul nouvel essai 3 s plus tard (amendement A3), `control` restant `taking` ; après un second échec, `control` passe à `failed`, et l'erreur est journalisée.
3. Les commandes `move` et `zoom` sont acceptées dans tous les états de `control`. Tant que le suivi n'est pas coupé, il peut les contrer, et l'app l'indique.

L'état réel du suivi IA ne se lit pas : le SDK renvoie toujours 0. La coupure est donc systématique, et rien n'essaie de « remettre comme avant ».

### 6.5 Vie privée

- **Entrée** :
  1. arrêt du mouvement ;
  2. lecture du pan, du tilt et du zoom ;
  3. enregistrement atomique dans `state.json` : `{privacy: true, saved: {pan, tilt, zoom}}` ;
  4. PanTilt absolu `(pan, -70°)` (amendement A2 : la caméra ignore un ordre à -90°).
- **Pendant** : `move` et `zoom` reçoivent `error`/`privacyActive`.
- **Sortie** :
  1. PanTilt absolu vers la position mémorisée ;
  2. zoom mémorisé ;
  3. `state.json` repasse à `privacy: false`.
- **Au démarrage de `ptzd` et à chaque rebranchement de la caméra**, si `state.json` indique `privacy: true` :
  1. le tilt est renvoyé à -70° ;
  2. `obsbot-ai-off` est lancé, car un redémarrage de la caméra peut avoir rallumé le suivi.
- **Relecture** : après l'entrée, la sortie ou une réapplication, la position n'est relue qu'au bout de 2 s ; relue plus tôt, la caméra renvoie une valeur fausse.

#### 6.5 bis Vie privée V2 : le mode natif de l'OBSBOT (19/10/2026)

Amendement du § 6.5, demandé par Djoko : la vie privée doit aussi couper le **micro** de la caméra, que go2rtc diffuse vers HomeKit et l'app iOS.

- **Essais du 19/10**, son mesuré à la sortie de go2rtc :
  - le muet et le volume d'entrée de macOS (CoreAudio) sont acceptés et relus, mais le micro les ignore : le niveau ne bouge pas (environ −31 dB) ;
  - le **mode vie privée natif de l'OBSBOT** (SDK : `cameraSetMicrophoneDuringSleepU(0)`, puis `cameraSetDevRunStatusR(DevStatusPrivacy)`) retourne l'objectif à 90°, rend une **image noire** et un **silence total** (−91 dB). Le flux continue à 25 images par seconde : go2rtc ne voit ni erreur ni relance, sur 20 minutes d'essai. L'état tient sans programme du SDK actif ;
  - le réveil (`cameraSetDevRunStatusR(DevStatusRun)`) rend l'image et le son, et la caméra reprend **d'elle-même** sa dernière position.
- **Mesures sur la vraie caméra (19/10, après la seconde relecture)**, par le SDK, sans ptzd :
  - **en mode vie privée natif, la Tiny 2 rend l'état brut 3 (`DevStatusSleep`)**, jamais 4, bien que l'ordre soit `DevStatusPrivacy`. ptzd compte donc **3 comme protégé** (et 4 aussi, par prudence) ; seul 1 (`DevStatusRun`) est « éveillée ». L'état se lit en 1 à 5 ms ;
  - les ordres rendent la main tout de suite (0 ms) : la caméra exécute ensuite. Entrée : état 3 en moins de 0,6 s, nacelle de 70° à **85°** en 1,1 s environ. Réveil : nacelle revenue à sa position d'avant l'entrée en **moins de 0,6 s**, puis état 1 vers 1,7 s ; quand l'état « marche » est lu, la remontée est finie ;
  - deux entrées ou deux réveils de suite ne font rien de plus (pas de mouvement, code 0) ;
  - une **session neuve du SDK met environ 4 s** à trouver la caméra ; ensuite, des lectures d'état et de position (deux par seconde, 15 s) **ne réveillent pas** la caméra. Une relecture lente et périodique de l'état réel est permise ;
  - la position de la nacelle se lit aussi par le SDK pendant le mode natif (`gimbalGetAttitudeInfoR`, inclinaison positive vers le bas), sans la réveiller : c'est le second témoin, à la place d'une lecture UVC ;
  - **coupure d'alimentation** (câble USB débranché puis rebranché) pendant le mode natif : la caméra revient **éveillée (état 1) et droite (0°)**. Elle filmerait aussitôt : au rebranchement, la protection à −70° part tout de suite, puis le mode natif.
- **Accélération (19/10, demandée par Djoko après le banc : « tout se fait en plusieurs temps qui se sentent »)**. Essai du même jour, par le SDK, depuis une position quelconque (pan −7°, inclinaison −2°, zoom 1,19) : `privacy on` **directement** donne l'état 3 en 0,24 s et la descente jusqu'à 85° en 1,1 s, d'un seul mouvement, pan et zoom inchangés ; `privacy off` ramène la caméra **d'elle-même** à −1,9°, pan −7,0°, zoom 1,19 (sa position d'entrée) en 1,1 s, état 1 à 1,5 s. D'où, **à la place des séquences d'entrée et de sortie ci-dessous** (qui restent valables pour le repli) :
  - **entrée rapide** : SDK prêt et caméra lue éveillée → `privacy on` directement, sans −70°. L'inclinaison à −70° ne sert plus que de **repli** : deux échecs du mode natif, pas de SDK, utilitaire en mise à jour, état illisible, ou **rebranchement** (caméra revenue éveillée et droite : −70° tout de suite, comme au point « rebranchement ») ;
  - **sortie rapide** : `privacy off`, relecture jusqu'à l'état `run`, puis relecture de la position (SDK ou UVC une fois éveillée) : si elle est à moins de 2° de `saved` (et le zoom à `saved`), rien d'autre ; sinon (entrée faite par repli, caméra bougée entre-temps), position mémorisée renvoyée comme au point « sortie » ;
  - **relectures serrées** pendant une bascule : toutes les 0,15 s (l'état se lit en 1 à 5 ms, la position en 50 à 100 ms), avec les mêmes délais maximaux ;
  - **journal** : ptzd écrit chaque étape de la vie privée (ordre, état lu, repli, position finale, durée), lisible pour un diagnostic. Au démarrage et au branchement, l'état réel lu est écrit avant d'agir (« état lu : privacy, rien à faire », « état lu : run, reprotection »).
  - **précisions de la réalisation** : « SDK prêt » veut dire que l'utilitaire en service a dit `ready` ; sinon un ordre attendrait une session neuve (environ 4 s) et l'inclinaison protège d'abord. Le second essai d'une entrée rapide est direct lui aussi ; le repli vient après le second échec. À la sortie, la position et le zoom sont relus par UVC, et l'inclinaison lue par le SDK doit aussi être à moins de 2° de `saved` (une relecture UVC périmée ne suffit pas à conclure) ; si le SDK ne la donne pas, rien n'est conclu et la position mémorisée est renvoyée et vérifiée ; une position d'entrée très basse, dans la zone de la pose native, n'empêche pas de constater le réveil.
- **Relecture du premier prototype (19/10, Opus)** : un ptzd qui *suppose* l'état de la caméra peut afficher « image et micro coupés » pendant que la caméra filme (ordre croisé entrée/sortie sur un utilitaire qui ne traite qu'un ordre à la fois, réponse perdue, ancien obsbot-ai pendant la recompilation, repli suivi d'un passage au natif). La mécanique ci-dessous remplace celle du prototype ; le comportement voulu ne change pas.
- **Deux couches.** La **protection immédiate** est l'inclinaison à −70° (commande UVC directe, rapide, sans SDK). Le **mode natif** de l'OBSBOT (image noire, micro coupé) vient **par-dessus**, par `obsbot-ai`, quand le SDK est là. `state.json` retient `privacy` (voulu), `saved` (position d'avant la vie privée) et `native` (dernier état natif constaté).
- **Un seul pilote de la position à la fois.** Pendant que la caméra est en mode natif (ou y entre, ou en sort), ptzd n'envoie **aucun** ordre de position : ni renvoi des −70°, ni vérification, ni réapplication. La caméra mémorise sa position à l'entrée en mode natif et la reprend d'elle-même au réveil : un ordre UVC pendant ces mouvements se battrait avec elle. **Seule exception : le rebranchement** (débranchement vu par ptzd, puis branchement), d'où la caméra revient éveillée et droite : elle ne peut pas être en mode natif.
- **État voulu, état constaté.** ptzd garde un seul état voulu (vie privée oui ou non). Un réconciliateur l'applique, un ordre à la fois, sur l'utilitaire résident ; un nouvel ordre de l'utilisateur pendant une étape change l'état voulu, et la séquence en cours s'arrête à la prochaine étape pour repartir vers le nouvel état (le dernier choix gagne, aucun ordre croisé). `obsbot-ai` gagne un ordre de **lecture de l'état réel** (`privacy status`, par `cameraGetCameraStatusU`) : `privacy` pour l'état brut 3 ou 4, `run` pour 1, toute autre valeur est une erreur (valeur brute au journal). La réponse porte aussi le **second témoin**, l'inclinaison lue par le SDK (`gimbalGetAttitudeInfoR`, positive vers le bas) : `ok privacy 84.9`, `ok run 69.8`, ou `err 2 84.9` si l'état ne se lit pas. Après chaque ordre natif, et quand une réponse manque ou échoue, ptzd relit l'état réel au lieu de supposer. Un état illisible se lit par le témoin : 80° ou plus, pose du mode natif ; 75° ou moins, hors de cette pose ; entre les deux, rien. Une lecture ratée n'arrête pas l'utilitaire ; **deux de suite, pendant le mode natif constaté, si** : « image et micro coupés » n'est alors plus affirmé (l'état réel redevient inconnu, « protection en cours »), la lecture suivante part sur une **session neuve** du SDK, puis, si elle rate encore, `privacy on` (sans effet si la caméra y est déjà, mesuré) et des relectures espacées. Aucun ordre de position pendant ce temps.
- **La bascule.** Les ordres natifs rendent la main tout de suite (0 ms) ; la caméra bascule ensuite. L'état est lu 0,15 s après la réponse (`switchDelay`), puis toutes les 0,15 s (`pollInterval`) jusqu'à 4 s (`switchLimit`) : l'état se lit en 1 à 5 ms, et une lecture avant la bascule rend simplement l'état d'avant, relu à la suivante. Rien d'autre ne part pendant ce temps. Lue éveillée alors qu'elle pouvait être en mode natif, la caméra a fini sa remontée (mesuré pour 85° vers 70°) à condition que deux inclinaisons lues de suite soient à moins d'1° l'une de l'autre, ce qui vaut aussi pour une remontée plus longue depuis une autre pose : une marge de 0,5 s encore, puis la suite. Un réveil dit par le seul témoin n'est retenu que 2,5 s après la réponse (l'état ne passe à 1 que vers 1,7 s).
- **Relecture de l'état réel pendant le mode natif** : toutes les 30 s, et tout de suite à la connexion d'un client (iPhone ou Mac), au réveil du Mac et à une demande d'entrée répétée. Une relecture qui confirme ne change rien à l'état publié ; une caméra lue éveillée (bouton, télécommande, app OBSBOT) est reprotégée : −70°, puis le mode natif. L'utilitaire reste donc chargé tant que le mode natif est en vigueur, et en fait tant que `ptzd` tourne (§ 6.9, « toujours chaud »).
- **Entrée** (et réapplication au démarrage, au rebranchement, après la coupure du suivi IA, si l'état voulu est « oui ») ; au rebranchement, l'inclinaison part tout de suite et le mode natif ensuite, sans lecture d'abord ; au démarrage de ptzd avec le mode natif retenu, l'état réel d'abord. Une caméra **absente au démarrage de ptzd**, puis branchée, sort d'une mise sous tension : c'est un rebranchement. Un branchement vu dans les **30 s qui suivent la sortie de veille du Mac** n'en est pas un : le Mac a pu renuméroter le bus USB sans couper l'alimentation, la caméra dormait peut-être encore en mode natif ; il est traité comme un démarrage (l'état réel d'abord, pas de −70° immédiat) :
  1. arrêt du mouvement, prise de la main sur le suivi IA (différée jusqu'à ce que la caméra soit lue éveillée, si elle peut être en mode natif : aucun ordre à une caméra endormie). `saved` n'est écrit qu'à une **entrée** demandée par l'utilisateur, jamais à une réapplication, un repli ou un passage au natif ;
  2. si l'état réel est déjà `privacy` (réapplication) : rien d'autre, la caméra est protégée ;
  3. sinon, **inclinaison à −70°**, puis **attente que la caméra y soit** (relecture de la position, jusqu'à stabilité près de la cible, 8 s au plus) ; refusée par la caméra, le mode natif part tout de suite ;
  4. avec le SDK : `privacy on`, puis lectures de l'état réel pendant la bascule. Échec (ou état réel différent au bout de 4 s) : **second essai automatique, dans les 10 s** (vers 4,5 s ; −70° renvoyé d'abord si le témoin ne la voit pas à 70°). Second échec : l'objectif reste à −70° et l'**avertissement** s'affiche : « La vie privée n'a pas pu couper l'image ni le micro de la caméra : l'objectif est seulement détourné. » La vérification et les renvois des −70° (§ 6.5) reprennent **toujours, dès qu'il est établi** que la caméra n'est pas en mode natif (état lu `run`, « ordre inconnu », pas de SDK, inclinaison refusée) ; l'objectif n'est « en place » que s'il a été vu à −70°.
- **Sortie** :
  1. avec le SDK : `privacy off` **quel que soit le mode noté**, puis lectures jusqu'à l'état réel `run` (vers 1,7 s ; second essai 1 s après un échec). Si la sortie ne peut pas être confirmée après les deux essais (caméra restée en `privacy`, état et témoin illisibles, utilitaire ancien) : la vie privée reste active, avec une erreur exacte. Un nouvel ordre de sortie la retente toujours ;
  2. **fin de la remontée propre de la caméra** : elle est finie quand `run` se lit, la nacelle immobile (deux inclinaisons de suite à moins d'1° ; remontée en moins de 0,6 s pour 85° vers 70°, mesuré) ; une marge de 0,5 s ;
  3. seulement alors, zoom puis **position mémorisée** (`saved`, ou 0°/0° si elle est inconnue), avec la vérification et les renvois du § 6.5 ;
  4. sans le SDK : directement l'étape 3.
- **Utilitaire ancien ou absent.** Une réponse « ordre inconnu » (code 3) d'un obsbot-ai d'avant la V2 n'est pas un échec de la caméra : ptzd reste sur la protection à −70° et publie « mise à jour du SDK en cours ». Quand PTZBot a recompilé obsbot-ai, il le dit à ptzd (message d'administration `aiUpdated`, par 127.0.0.1), qui redémarre son utilitaire et réconcilie. Si la recompilation est impossible (outils de développement absents, échec), la note le dit, avec l'action à faire.
- **État publié** (`privacyMode`, champ optionnel) : `native` seulement quand l'état réel `privacy` a été lu ; `tilt` sinon (protection à −70° seule), avec la raison (`pending`, `noSDK`, `updating`, `failed`). L'interface dit « protection en cours » tant que l'objectif n'a pas été vu à −70° (rebranchement, démarrage, réveil par un autre moyen, inclinaison refusée), « objectif détourné » ensuite tant que le mode natif n'est pas confirmé, puis « image et micro coupés ». Pendant une sortie, ni `pending` ni `failed`.
- **Cas limites assumés** : sans obsbot-ai (SDK retiré) alors que la caméra peut être en mode natif, ptzd ne peut ni lire ni réveiller : il incline. Un retour à la 1.1.0 pendant le mode natif laisse la caméra noire (l'ancien ptzd ignore `native`) : sortir de la vie privée avant de revenir en arrière.
- **Pendant** : `move`, `zoom` et le suivi IA restent refusés (`privacyActive`).
- **Interfaces** (Mac et iOS, textes au vouvoiement ; en anglais et en français sur Mac) : les notes ci-dessus, selon la raison.
- **Quitter PTZBot** ne réveille pas la caméra : la vie privée native tient sans l'app ; au prochain lancement, la relecture de l'état réel évite de rejouer l'inclinaison.

### 6.6 Erreurs

| Situation | Comportement |
|---|---|
| Caméra absente | `camera: absent`. `move`, `zoom` et `privacy` reçoivent `error`/`cameraAbsent`. Reprise automatique au rebranchement. |
| Requête UVC en échec | Journalisée avec le code IOKit. Le client à l'origine de la commande reçoit `error`/`uvcFailed`. |
| Adresse d'écoute absente au démarrage (Tailscale pas encore actif) | Nouvel essai toutes les 5 s, journalisé. |
| OBSBOT Center détecté | Avertissement dans le journal, à chaque `takeControl`. |

### 6.7 Configuration et fichiers

Les chemins de travail se trouvent sous `~/Library/Application Support/ObsbotNacelle/` :

| Chemin | Contenu |
|---|---|
| `bin/` | `ptzd` et `obsbot-ai-off` |
| `lib/` | `libdev.dylib` |
| `config.json` | Les réglages, jamais versionnés |
| `state.json` | L'état de la vie privée |

Les journaux vont dans `~/Library/Logs/obsbot-nacelle/` : `ptzd.log` (sorties de launchd, en plus du journal système `os.Logger`) et `obsbot-ai-off.log` (sortie très bavarde du SDK, tenue à part).

Contenu de `config.json` :

| Clé | Rôle | Défaut |
|---|---|---|
| `listenAddress` | Adresse IPv4 Tailscale du Mac | obligatoire, pas de défaut |
| `port` | Port WebSocket | 1985 |
| `panMaxSpeed`, `tiltMaxSpeed` | Plafonds de vitesse UVC | 40, 60 |
| `panDirection`, `tiltDirection` | Sens, +1 ou -1 | +1, +1 |
| `aiOffPath` | Chemin de `obsbot-ai-off` | `bin/obsbot-ai-off` |

### 6.8 Déploiement

- **Agent launchd** : `io.github.djoko-cli.obsbot-nacelle.ptzd`, dans la session de l'utilisateur comme go2rtc, avec `RunAtLoad` et `KeepAlive`.
- **`scripts/install-mac.sh`** :
  1. compile `ptzd` et `obsbot-ai-off` ;
  2. copie les binaires et `libdev.dylib`, dont l'`rpath` est `@executable_path/../lib` ;
  3. crée `config.json` s'il n'existe pas ;
  4. installe le plist et le charge.

  **Le script refuse de continuer si `libdev.dylib` porte l'attribut `com.apple.quarantine`.** Il affiche alors la commande `xattr` à lancer, sans la lancer lui-même.

### 6.9 `obsbot-ai-off`

C'est un petit programme C++ lié à `libdev`, qui :
1. ouvre `Devices::get()` en désactivant la recherche mDNS ;
2. attend la Tiny 2 pendant 10 s au plus (amendement A3) ; s'il ne la trouve pas, quitte sans refermer le SDK ;
3. appelle `cameraSetAiModeU(AiWorkModeNone, 0)` ;
4. appelle `Devices::get().close()`.

| Code de sortie | Signification |
|---|---|
| 0 | Le suivi est coupé |
| 1 | Caméra introuvable |
| 2 | Le SDK a renvoyé une erreur |
| 3 | Argument manquant ou ordre inconnu (utilitaire plus ancien que l'ordre) |

Devenu `obsbot-ai` (vie privée V2, § 6.5 bis), il accepte aussi `on`, `privacy-on`, `privacy-off` et `privacy-status` à un coup (ce dernier écrit `privacy 84.9` : l'état et l'inclinaison), et `serve` : ordres `on`, `off`, `privacy on`, `privacy off`, `privacy status` sur l'entrée, un par ligne ; réponses `obsbot-ai: ready`, puis `ok`, `ok <état> [<inclinaison>]` ou `err <code> [<inclinaison>]`, avec les codes ci-dessus.

**Toujours chaud (19/10/2026, décision de Djoko).** Lancé avec le SDK (`--ai`), `ptzd` démarre l'utilitaire dès que la caméra est là et le garde chargé tant qu'il tourne (plus d'arrêt pour inactivité, relance après une mise à jour, un rebranchement, une sortie de veille du Mac hors vie privée ou une lecture qui demande une session neuve), pour que toute entrée en vie privée prenne le chemin rapide ; rien ne libère la session du SDK quand OBSBOT Center veut la caméra, `ptzd` n'avertit que dans le journal. **Veille de 60 s** : toutes les 60 s, `ptzd` relance un utilitaire mort seul (sans caméra, rien n'est lancé) ; après un utilitaire mort sans avoir servi, la relance attend la minute de pause du lanceur, soit 60 à 120 s. **Sortie de veille du Mac** (hors vie privée) : la session du SDK a pu devenir périmée sans qu'aucun branchement soit vu ; l'utilitaire est réinitialisé et relancé, si bien qu'une entrée dans les 4 s qui suivent passe par le repli (−70° tout de suite) et jamais par une session invalide ; en vie privée, la relecture du réveil le couvre (deux lectures ratées, session neuve).

Durée attendue : environ 4 s, davantage quand la vidéo démarre au même moment.

### 6.10 Sécurité

> Remplacé par l'amendement A4 : voir [2026-10-06-acces-local-design.md](2026-10-06-acces-local-design.md). Le texte ci-dessous décrit la v1.

- `ptzd` n'écoute que sur l'adresse Tailscale et sur 127.0.0.1 (amendement A1), jamais sur `0.0.0.0` ni sur l'adresse du réseau local : un appareil du Wi-Fi qui n'est pas dans le réseau Tailscale ne peut pas piloter.
- Il n'y a pas d'authentification en plus dans la v1 : le réseau Tailscale de Majid sert de frontière.
- L'API go2rtc (port 1984) est déjà ouverte sans authentification sur le réseau local. C'est un état antérieur à ce projet, qui reste hors périmètre.

### 6.11 Exposition automatique (20/10/2026)

Un interrupteur « Exposition auto » dans l'app iOS, à côté du bouton d'enregistrement, et dans le panneau du Mac. Conception validée par Djoko le 20/10, après un essai sur la vraie caméra.

- **Essai du 20/10**, par le SDK, sans ptzd :
  - pour la Tiny 2, seules `cameraGetExposureAbsolute(int32_t &shutter_time, bool &auto_enabled)` et `cameraSetExposureAbsolute(int32_t shutter_time, bool auto_enabled)` s'appliquent ; les autres fonctions d'exposition du SDK (`cameraSetExposureModeR`, `cameraSetFaceAER`, `cameraSetAELockR`, `cameraSetPAEEvBiasR`) sont réservées à la Tail Air ;
  - départ : manuel, obturation 31, luminosité de l'image 80,4/255 ;
  - `cameraSetExposureAbsolute(31, true)` : l'image s'éclaircit progressivement, jusqu'à 91,7 en 10 s ;
  - `cameraSetExposureAbsolute(31, false)` : un creux d'une seconde, puis 81,0. **Le gain fixé dans OBSBOT Center est conservé par la caméra** : le retour au réglage manuel se fait en remettant l'obturation et le mode lus avant.
- **Comportement.**
  - **Activé** : la caméra passe en exposition automatique continue.
  - **Désactivé** : retour **exact** au réglage lu juste avant l'activation (l'« ancien » réglage : obturation et mode). À la désactivation, ptzd **ne relit pas** OBSBOT Center : si le réglage a été changé là-bas entre-temps, l'ancien est quand même remis, et une ligne du journal le dit.
  - **Tout passe par l'utilitaire du SDK** (`obsbot-ai`, toujours chargé depuis la 1.1.1, § 6.9), un ordre à la fois, par la **même file** que la vie privée et le suivi IA : les ordres ne se croisent jamais. Pas de commande UVC : l'exposition de la Tiny 2 se règle par le SDK.
  - **Pendant la vie privée**, l'interrupteur reste utilisable et l'ordre part normalement.
- **`obsbot-ai`** : deux ordres, avec les conventions de la vie privée.
  - `exposure status` lit le réglage : `obsbot-ai: ok 31 manual` (obturation, puis `auto` ou `manual`). Lecture refusée par le SDK : `err 2`. Comme `privacy status`, une lecture ratée ne rend pas la session douteuse : l'utilitaire reste.
  - `exposure set <obturation> <auto|manual>` applique le réglage : `ok`, ou `err 2` (l'utilitaire repart alors d'une session neuve, comme pour tout ordre raté). En mode `auto`, l'obturation envoyée est celle d'origine : la caméra l'ignore tant qu'elle reste automatique.
  - `err 3` (« ordre inconnu ») : obsbot-ai d'avant l'exposition ; même traitement que pour la vie privée (raison `updating`).
  - Mode à un coup : `obsbot-ai exposure-status` (écrit `31 manual`) et `obsbot-ai exposure-set 31 auto`. Les mêmes codes de sortie (0, 1, 2, 3).
- **`ptzd`.**
  - **Message client** `autoExposure(on:)`, accepté d'un client authentifié, caméra présente. Rend `cameraAbsent` sans caméra, et `uvcFailed` (texte `ExposureFailureText`) sans SDK, ou si l'utilitaire n'est pas à jour.
  - **Activation** : lecture du réglage en place (`exposure status`), qui devient le **réglage d'origine** ; il est écrit dans `state.json` **avant** de passer en automatique (`exposure set <obturation d'origine> auto`). Ainsi un arrêt de ptzd au milieu ne perd jamais l'origine. Si le réglage d'origine est déjà automatique (réglé dans OBSBOT Center), il est retenu tel quel et remis tel quel à la désactivation : la caméra ne change pas, et le journal le dit.
  - **Désactivation** : `exposure set <obturation d'origine> <mode d'origine>`, puis l'origine est effacée.
  - **Réglage d'origine illisible** à l'activation (lecture refusée, délai dépassé) : l'activation est **abandonnée**, rien n'a changé sur la caméra, le client reçoit `uvcFailed`. On ne passe jamais en automatique sans pouvoir revenir.
  - **Réglage d'origine inconnu** à la désactivation (`state.json` avec l'exposition automatique voulue mais sans origine, par exemple un fichier abîmé) : ptzd lit l'obturation en place et la remet en **manuel** ; une ligne du journal le dit.
  - **Échec de l'ordre** (après une lecture réussie) : à l'activation, l'état revient à « désactivé », l'origine est effacée, le client reçoit `uvcFailed` ; à la désactivation, l'état reste « activé » (la caméra est restée en automatique), l'origine est gardée, le client reçoit `uvcFailed`, et un nouvel ordre retente.
  - **Plusieurs demandes de suite** : l'état voulu change tout de suite, la séquence en cours finit son étape, puis repart vers le dernier choix (comme la vie privée, § 6.5 bis). Une réponse donnée à une session de l'utilitaire qui n'existe plus (branchement, mise à jour) est écartée.
  - **Réapplication** quand l'exposition automatique est voulue : au **démarrage** de ptzd (caméra présente), à chaque **branchement** de la caméra (elle a pu oublier le mode automatique, ou revenir à son réglage propre) et après `aiUpdated`. L'origine n'est pas relue : elle reste celle de l'activation. Un échec de réapplication est journalisé, l'état voulu reste « activé », et la réapplication suivante réessaie. Sans SDK, rien n'est tenté : l'état voulu est gardé, et appliqué dès qu'un SDK arrive (`aiUpdated`).
  - **`state.json`** gagne `autoExposure` (voulu) et `exposureOrigin` (`shutter`, `auto`), écrits seulement s'ils servent ; un fichier d'une version sans ces champs se lit « désactivé », sans origine. Les deux réconciliateurs (vie privée, exposition) réécrivent le fichier en relisant d'abord l'autre moitié, pour ne jamais effacer ses champs.
  - **Journal** : une ligne par étape, préfixée « Exposition auto : » (demande, origine lue, ordre envoyé, résultat, réapplication, abandon).
- **État publié** : `autoExposure`, champ optionnel du `state` (`on`, `off`, `unavailable`). `unavailable` quand ptzd ne peut pas tenir l'ordre : pas d'`obsbot-ai`, ou `obsbot-ai` d'avant l'exposition. Un ptzd d'avant ce champ ne l'envoie pas : l'app le lit `nil` et grise l'interrupteur. Une valeur inconnue (un futur ptzd) se lit `nil` aussi. L'état publié suit l'état **voulu** dès la demande (pas d'attente de la caméra) et revient en arrière si l'ordre échoue.
- **Protocole** (`NacelleProtocol`) : message `{"type":"autoExposure","on":true}` ; compatible dans les deux sens (un ptzd ancien le refuse en `badMessage`, un état sans le champ se lit `nil`).
- **Interfaces.**
  - **iOS** : un bouton **de la même famille que celui de l'enregistrement** (même forme, même taille, même style d'état actif et inactif), juste à côté ; icône SF Symbol `sun.max` (pleine quand activé), libellé VoiceOver « Exposition auto », valeur « activée » ou « désactivée », et indication quand il est grisé. Grisé sans SDK, sans connexion ou sans caméra ; utilisable pendant la vie privée.
  - **Mac** : un interrupteur dans le panneau, au vouvoiement, **avec la même icône SF Symbol que sur iOS** pour que la fonction se reconnaisse d'une app à l'autre ; traduit en anglais (catalogue). Grisé sans SDK, avec une note qui le dit (« Il faut le SDK OBSBOT. »).
- **Limites assumées.**
  - L'exposition automatique ne vaut que pour la Tiny 2 : les fonctions du SDK utilisées sont celles qui s'appliquent à elle.
  - Un ordre d'exposition d'une réapplication, donné à une session neuve (environ 4 s), précède dans la file un ordre de vie privée donné pendant ce temps : la protection par l'inclinaison joue son rôle d'abord (§ 6.5 bis).
  - Le gain n'est ni lu ni écrit : la caméra le garde d'elle-même (essai du 20/10).

## 7. L'app iOS (`Nacelle`)

### 7.1 Socle

- SwiftUI, Swift 6 en mode concurrence stricte, iOS 26 minimum, iPhone.
- **Une seule dépendance externe** : WebRTC, en paquet Swift précompilé. La version exacte sera épinglée dans le plan.

### 7.2 Modules

| Module | Rôle |
|---|---|
| `Settings` | Nom d'hôte Tailscale du Mac, port go2rtc (1984), nom du flux (`obsbot`), port de `ptzd` (1985). Enregistrés dans `UserDefaults`, saisis au premier lancement, modifiables ensuite. |
| `VideoSession` | Une `RTCPeerConnection` avec un récepteur vidéo seul, sans serveur ICE. Elle attend la fin de la collecte des candidats (2 s au plus), puis envoie `POST http://<hôte>:<port>/api/webrtc?src=<flux>` avec `Content-Type: application/sdp`. Elle attend une réponse `201` contenant le SDP. Ses états : `connecting`, `playing`, `lost`. Les nouveaux essais sont espacés de 1, 2, 4, puis 8 s au plus. L'image s'affiche dans `RTCMTLVideoView`, sans être rognée. |
| `PTZClient` | `URLSessionWebSocketTask` vers `ws://<hôte>:<port ptzd>`. Il envoie `takeControl` à chaque connexion. Tant que le joystick est hors du centre, il renvoie le dernier `move` 10 fois par seconde. Il publie le dernier `state` reçu et se reconnecte en espaçant les essais. |
| `Joystick` | Transforme le geste en vecteur de -1 à 1, borné au cercle, avec une zone morte de 0,1. Au relâchement, le joystick revient au centre et envoie `0,0` une fois. |
| `ControlScreen` | La vidéo en plein écran, avec le joystick en bas à gauche, le curseur de zoom vertical à droite, le bouton vie privée en haut à droite, le bouton son à sa gauche (amendement A5) et le bandeau d'état en haut. Fonctionne en portrait comme en paysage. |

### 7.3 Bandeau d'état

| Condition | Texte |
|---|---|
| WebSocket ou vidéo en cours de connexion | « Connexion… » |
| `control = taking` | « Prise en main… » *(bandeau supprimé le 07/10/2026 : voir les amendements de la [spec de l'app Mac](2026-10-06-app-mac-design.md))* |
| `control = failed` | « Suivi IA non coupé : les mouvements peuvent être contrés » |
| `camera = absent` | « Caméra débranchée » |
| Mac injoignable | « Mac injoignable : Tailscale est-il actif ? » |
| `privacy = true` | « Vie privée » (joystick et zoom grisés) |

Si plusieurs conditions sont vraies, elles sont classées dans cet ordre : Mac injoignable, puis caméra débranchée, puis vie privée, puis suivi IA non coupé, puis prise en main, puis connexion.

### 7.4 Cycle de vie et retour haptique

- **Passage en arrière-plan** : l'app envoie `move 0,0`, ferme le WebSocket et ferme la connexion vidéo.
- **Retour au premier plan** : elle reconnecte les deux, puis envoie `takeControl`.
- **Retour haptique** : un léger impact quand le doigt se pose sur le joystick, et un retour de notification à l'entrée et à la sortie du mode vie privée.

### 7.5 Réseau

- La vidéo et le contrôle passent en clair (`http` et `ws`), à l'intérieur du tunnel Tailscale, qui est lui-même chiffré.
- `Info.plist` déclare une exception ATS limitée au domaine `ts.net` et à ses sous-domaines (`NSExceptionAllowsInsecureHTTPLoads`). Rien d'autre n'est ouvert.

## 8. Tests

**Automatiques**, avec `swift test` et les tests Xcode :

- **`NacelleProtocol`** :
  - un aller-retour encodage puis décodage pour chaque message ;
  - le rejet d'un `type` inconnu ;
  - les bornes des valeurs.
- **`PTZController`**, avec une fausse caméra, une fausse horloge, un faux lanceur et un faux stockage :
  - la courbe et les sens de la vitesse, et le minimum de 1 ;
  - l'absence de commandes en double ;
  - l'arrêt automatique à 300 ms ;
  - l'arrêt à la déconnexion ;
  - le zoom borné et regroupé ;
  - l'entrée en vie privée, le refus des commandes, la sortie avec rétablissement ;
  - la reprise après redémarrage et après rebranchement ;
  - `takeControl` : un seul lancement pour plusieurs demandes, codes de sortie, dépassement de 15 s ;
  - la caméra absente.
- **App** :
  - les maths du joystick (zone morte, cercle) ;
  - la machine d'états de `PTZClient`, avec un faux transport ;
  - la construction de la requête de signalisation de `VideoSession`.

**Manuels** :

- **Intégration sur le Mac**, avec la vraie caméra et une checklist dans le plan :
  - l'étalonnage des sens ;
  - mouvement, arrêt automatique, zoom ;
  - vie privée, y compris après un redémarrage de `ptzd` et un débranchement de la caméra ;
  - la santé du système (PID de go2rtc et de coreaudiod, journal d'arkaudiod).
- **De bout en bout sur l'iPhone en 4G**, avec le Wi-Fi coupé :
  - la vidéo ;
  - joystick, zoom, vie privée ;
  - le passage en arrière-plan puis le retour ;
  - le Mac rendu injoignable.

## 9. Limites connues

- Réinstallation de l'app tous les 7 jours.
- Le micro reste actif en mode vie privée, y compris pour HomeKit ; l'app, elle, coupe le son en vie privée (amendement A5).
- L'état du suivi IA ne se lit pas, et un geste de la main peut le rallumer pendant une session.
- OBSBOT Center doit rester fermé.
- Le SDK doit être présent en local pour compiler et installer `obsbot-ai-off`.

## 10. Questions ouvertes, à trancher pendant l'implémentation

1. Après la coupure du suivi, un pan à 30° s'est arrêté deux fois à 22°. Faut-il un délai entre `obsbot-ai-off` et la première commande UVC ?
2. Le réglage « suivi coupé » survit-il à un débranchement de la caméra ?
3. Quelle est la latence de bout en bout, de l'iPhone en 4G à la nacelle ?

## 11. Décisions et leurs raisons

| Décision | Raison |
|---|---|
| App native plutôt que web app | Choix de Majid, malgré l'expiration tous les 7 jours |
| WebRTC natif plutôt qu'une vue web ou HLS | Latence d'environ 200 ms et vraie gestion des états. HLS a 2 à 5 s de retard. |
| UVC pour le mouvement, le SDK seulement pour couper le suivi | UVC est prouvé pendant la capture. Le SDK touche AVFoundation et CoreAudio. |
| Le SDK dans un processus court, pas chargé en permanence | Le risque coreaudiod n'est pas prouvé pour un usage permanent |
| Vie privée par le tilt, pas par la veille | En veille, la caméra n'envoie plus de flux, ce qui peut bloquer ffmpeg |
| Pas de modification de go2rtc | Il propose déjà l'adresse Tailscale en WebRTC, et sa stabilité est fragile |

Résultats des tests de faisabilité : [docs/spike/2026-10-05-faisabilite.md](../../spike/2026-10-05-faisabilite.md).

## 12. Amendements

Validés par Majid le 2026-10-05, après les vérifications faites en écrivant le plan côté Mac.

| Amendement | Changement | Raison |
|---|---|---|
| **A1** | `ptzd` écoute aussi sur 127.0.0.1 (§ 6.1, § 6.10) | Le Mac ne peut pas joindre un `NWListener` par sa propre adresse Tailscale (l'iPhone, lui, y arrive) : sans 127.0.0.1, le service installé ne se vérifierait que depuis l'iPhone. Aucune exposition nouvelle. |
| **A2** | Vie privée à -70° au lieu de -90° ; ordres absolus bornés à pan ±130°, tilt de -80° à +70° (§ 2, § 6.1, § 6.5) | La caméra ignore en silence un ordre à -90° ou à +89°, pan compris, en renvoyant un succès : le mode vie privée tel que spécifié ne faisait rien. -70° est obéi exactement, et vérifié à l'image. Détails : section « Correctif » de [docs/spike/2026-10-05-faisabilite.md](../../spike/2026-10-05-faisabilite.md). |
| **A3** | `obsbot-ai-off` attend 10 s et quitte sans refermer le SDK s'il ne trouve pas la caméra ; un seul nouvel essai de prise en main 3 s après un échec (§ 6.4, § 6.9) | L'app ouvre la vidéo et la prise en main ensemble : une fois sur trois, l'initialisation du SDK a dépassé 5 s, puis `obsbot-ai-off` a planté en refermant le SDK encore occupé (constaté dans le simulateur le 2026-10-05). |
| **A4** | Accès par le réseau local, appairage obligatoire, vidéo de l'app négociée par `ptzd`, go2rtc fermé au réseau local sauf RTSP avec mot de passe (§ 2, § 6.10, § 7) | Majid veut se passer de Tailscale à la maison (2026-10-06). La frontière n'est plus le réseau Tailscale mais l'appairage de l'iPhone. Détails : [2026-10-06-acces-local-design.md](2026-10-06-acces-local-design.md). |
| **A5** | Son dans l'app : piste Opus reçue (go2rtc convertit l'AAC du micro à la demande, `ffmpeg: bin:` en chemin complet), périphérique audio en sortie seule, bouton son coupé au premier lancement puis retenu, joué en mode silencieux, coupé en vie privée et tant que l'état de `ptzd` est inconnu (§ 2, § 7.2, § 9) | Demandé par Majid le 2026-10-06. Le micro de l'iPhone n'est jamais demandé ; HomeKit garde son AAC. La vie privée ne coupe que la lecture dans l'app : la capture continue pour HomeKit. |
