# Spec : go2rtc dans PTZBot pour Mac (sous-projet B3)

Embarque go2rtc dans PTZBot.app. PTZBot lance go2rtc, le surveille, génère sa configuration et en montre l'état. Fait
suite à la [spec ptzd dans l'app](2026-10-07-ptzd-dans-app-design.md) (B1) et à la
[spec distribution](2026-10-08-distribution-design.md) (B2), qui restent valables pour tout ce qui n'est pas repris ici.
Conçue avec Majid le 12/10/2026, section par section. Elle tient compte de la passation de la session go2rtc
(`~/Dev/go2rtc mac/PASSATION-go2rtc-dans-PTZBot.md`, hors dépôt).

## 1. Objectif

- **PTZBot devient le seul propriétaire de la caméra.** go2rtc ne tourne que pendant que PTZBot est ouvert, comme ptzd.
  La règle « aucun accès à la caméra sans l'app » vaut alors partout.
- **Une fonction de PTZBot pour tout utilisateur**, et pas seulement pour l'installation de Majid. L'app génère la
  configuration, détecte la caméra et ffmpeg, et dit clairement ce qui manque.
- **Les autorisations caméra et micro au nom de PTZBot**, identité stable et signée Developer ID, au lieu du binaire ad
  hoc `a.out` d'aujourd'hui.
- **Aucune régression** sur ce que la session go2rtc a établi du 4 au 8 octobre (§ 9).

## 2. Choix de Majid (12/10/2026)

| Question | Réponse |
|---|---|
| Cycle de vie | **Processus enfant de PTZBot**, comme ptzd. Quitter PTZBot arrête go2rtc, et donc la caméra HomeKit. Renverse le choix du 07/10, où go2rtc devait tourner app fermée. |
| Public | **Tout utilisateur** du dépôt public : configuration générée, README bilingue. |
| ffmpeg | **Celui de Homebrew, détecté**, jamais embarqué : la version Homebrew est GPL. Message clair s'il manque. |
| Configuration | **Générée par PTZBot**, avec un **fichier personnalisé** possible (mode expert) et l'**import** d'une configuration existante. |
| Panneau | Un interrupteur, une ligne d'état avec le nombre de clients, le détail au survol, l'alerte coreaudiod seulement en cas de besoin. |
| Réglages | Un onglet « Caméra », avec les boutons « Ouvrir le journal » et « Ouvrir l'interface web ». |
| Allègement du panneau | **Pastilles vertes** : l'état normal de chaque service est une pastille verte. Une ligne d'état n'apparaît que hors de l'état normal. |
| Ordre | Après le passage au Developer ID (1.0.7, fait). B3 sort en **1.1.0**. |

Hors périmètre : embarquer ffmpeg, réparer coreaudiod automatiquement (il faudrait les droits root, ce qui demande une
conception à part), monter la version de go2rtc, et modifier la configuration de Homebridge.

## 3. Architecture

### 3.1 Le binaire go2rtc

- **Emplacement** : `Contents/Helpers/go2rtc`, à côté de ptzd et talkd.
- **Version figée** : 1.9.14, celle qui tourne aujourd'hui chez Majid. Une montée de version est un changement à part.
- **Provenance** : à la compilation, `build-helpers.sh` télécharge l'archive macOS de la même architecture que l'app
  (arm64) depuis les versions officielles de `AlexxIT/go2rtc` sur GitHub.
  - Il vérifie son **empreinte SHA-256**, écrite dans le dépôt (`mac/app/go2rtc.sha256`), et refuse tout écart.
  - Il garde l'archive en cache dans le dossier de compilation : pas de téléchargement à chaque fois.
- **Licence** : MIT. Le texte va dans `Contents/Resources/go2rtc-LICENSE.txt`.
- **Signature** : la publication le signe comme ptzd et talkd, avec le Developer ID, le runtime renforcé, aucun droit,
  puis l'horodatage. `check-bundle.sh` et la publication le comptent parmi les utilitaires.

### 3.2 Le gardien : go2rtc meurt avec PTZBot

ptzd surveille son parent (`--parent`) et s'arrête si PTZBot disparaît, même en cas de plantage. go2rtc ne sait pas le
faire : après un plantage de PTZBot, il resterait orphelin, la caméra ouverte.

**Choix proposé** : un petit utilitaire `gardien`, en Swift, dans `Contents/Helpers`.
- **Usage** : `gardien --parent <pid> --arret <secondes> -- <programme> <arguments…>`. Il lance le programme en
  processus enfant, transmet SIGTERM et SIGINT, et rend son code de sortie.
- **Si le parent disparaît**, il envoie SIGTERM au programme, attend `--arret` secondes, puis SIGKILL.
- **Surveillance** par `kqueue` (`EVFILT_PROC`, `NOTE_EXIT`) sur le pid du parent. Pas de sondage.
- PTZBot lance donc `gardien --parent <pid de PTZBot> --arret 10 --rtsp <port> [--capture <md5>]… -- go2rtc -config <yaml>`.
- **Ménage des ffmpeg décrochés (30/10).** Après une veille qui coupe la caméra, go2rtc 1.9.14 relance ses ffmpeg et
  laisse les anciens en vie, figés sur l'appareil disparu ; un ffmpeg figé dans une capture AVFoundation ignore les
  3 premiers SIGTERM et ne sort qu'au-delà. Avec `--rtsp <port>` (le port RTSP réglé), le gardien passe toutes les 60 s
  (`EVFILT_TIMER` de sa boucle kqueue, sans fil) sur les ffmpeg de capture (nom `ffmpeg`, `avfoundation` dans les
  arguments, même utilisateur) dont la sortie est `rtsp://127.0.0.1:<port>/…` : membres du groupe de go2rtc ou enfants
  directs, et orphelins (PPID 1) dont la sortie est exactement `rtsp://127.0.0.1:<port>/<md5>` avec un `<md5>` donné par
  `--capture`. Un ffmpeg de plus de 180 s sans socket TCP `ESTABLISHED` vers ce port (lue par libproc ; une socket
  illisible : rien n'est conclu), vu ainsi à deux passages de suite, reçoit 4 SIGTERM à 1 s d'intervalle, portés par une
  minuterie kqueue, chacun revérifié (même pid et même heure de démarrage, toujours décroché). Jamais de SIGKILL, jamais
  un ffmpeg connecté. Une ligne au journal par ffmpeg visé et par fin constatée. Le gardien relève aussi les enfants de
  go2rtc à chaque passage.
- **Empreintes (`--capture`).** go2rtc nomme la sortie d'une source `exec:` par le MD5 (hexadécimal minuscule) de la
  source coupée au premier `#` (`internal/exec`, `execHandle`) ; PTZBot les calcule à partir des deux sources du yaml
  qu'il génère. Fichier personnalisé : `--rtsp` seul, pas de ménage des orphelins (la parenté de go2rtc suffit pour ses
  enfants, et le gardien ne juge que ceux dont la sortie vise ce port).
- **À l'arrêt de go2rtc**, ses ffmpeg restants reçoivent aussi 4 SIGTERM, à t = 0, 1, 2 et 3 s, dans l'attente de 5 s.

L'alternative, rejetée : à son lancement, PTZBot tue un go2rtc orphelin de la session précédente, connu par un fichier
de pid. Elle laisse la caméra ouverte entre le plantage et la relance de l'app.

### 3.3 Le superviseur de go2rtc

`Go2RTCSupervisor` (PTZBotKit), sur le modèle de `ServiceSupervisor` (ptzd), avec les mêmes doublures de processus et
d'horloge pour les tests.
- **États** : désactivé, démarrage, actif, relance (n), échec (raison).
- **Relance** : délais 1, 2, 4, 8, 16 puis 30 s. Au-delà de 5 arrêts inattendus en 120 s, l'état passe à « échec :
  ouvrez le journal ».
- **Arrêt en douceur** : SIGTERM, puis SIGKILL seulement après **10 s** au moins. go2rtc a ainsi le temps d'arrêter ses
  ffmpeg par SIGTERM (`#killsignal=15`). C'est le délai d'arrêt de l'ancienne plist (`ExitTimeOut` ≥ 10 s).
- **Journal** : `go2rtc.log`, dans le dossier des journaux de PTZBot, à côté de `ptzd.log`. Sortie et erreurs y sont
  ajoutées.
- **Interrupteur** : réglage `go2rtcEnabled`, retenu d'un lancement à l'autre, **éteint par défaut**. Il ne doit pas
  prendre la caméra de quelqu'un qui a déjà son go2rtc.
- **Quitter PTZBot** attend la fin de ptzd et de go2rtc. Quand go2rtc est allumé, la confirmation de « Quitter » dit :
  « Quitter PTZBot arrête aussi la caméra HomeKit. »
- **Environnement** : le `PATH` de go2rtc commence par le dossier de ffmpeg, puis `/usr/bin:/bin`. C'est nécessaire à
  la source `ffmpeg:obsbot#audio=opus`.
- **Veille du Mac (31/10)** : le superviseur peut être mis en pause (`pauseForSleep`, `resumeAfterSleep`). go2rtc est
  arrêté avant la veille du Mac et ne repart qu'au vrai réveil, écrans allumés. Voir le § 15.

### 3.4 Autorisations caméra et micro

- go2rtc et ses ffmpeg descendent de PTZBot : macOS attribue leurs accès à **PTZBot**, le processus responsable.
- `Info.plist` reçoit `NSCameraUsageDescription` et `NSMicrophoneUsageDescription`, au vouvoiement, traduits
  (`InfoPlist.xcstrings`) :
  - « PTZBot diffuse l'image de votre caméra OBSBOT vers HomeKit et l'app iPhone. »
  - « PTZBot diffuse le son du micro de votre caméra OBSBOT vers HomeKit et l'app iPhone. »
- **Droits du runtime renforcé, sur l'app seulement** : `com.apple.security.device.camera` et
  `com.apple.security.device.audio-input`.
  - La publication contrôle aujourd'hui que les utilitaires n'ont aucun droit : on garde ce contrôle.
  - Elle accepte désormais ces deux droits sur l'app, et seulement eux, en plus de ceux qu'elle autorise déjà.
- **Effet attendu** : à la première ouverture de la caméra, « PTZBot souhaite accéder à la caméra », puis la même
  demande pour le micro. Un refus est repéré dans le journal (§ 5).

### 3.5 ffmpeg

- **Recherche**, dans l'ordre : le chemin réglé dans l'onglet « Caméra », `/opt/homebrew/bin/ffmpeg`, puis
  `/usr/local/bin/ffmpeg`. Il faut un exécutable, qui répond à `-version`.
- **Absent** : go2rtc n'est pas lancé, et l'état dit « ffmpeg introuvable ». L'onglet « Caméra » donne la commande
  `brew install ffmpeg`.
- **Chemin absolu** écrit dans le yaml (`ffmpeg: bin:` et les sources `exec:`).

### 3.6 Les appareils

- **Détection** par `AVCaptureDevice.DiscoverySession`, qui liste caméras et micros sans demander d'autorisation.
- **Choix par défaut** : la première caméra et le premier micro dont le nom contient « OBSBOT ». Sinon, l'état dit
  « Caméra OBSBOT absente ».
- L'onglet « Caméra » permet un autre choix. Le nom retenu est écrit tel quel dans l'entrée `-i` d'ffmpeg, avec les
  guillemets échappés.

## 4. Configuration générée

- **Fichier** : `~/Library/Application Support/ObsbotNacelle/go2rtc.yaml`, en mode 600, écrit de façon atomique. Il
  contient le mot de passe RTSP : jamais dans le dépôt, jamais dans un journal.
- **Réglages** (`Go2RTCSettings`, hors du yaml) :
  - identifiant et mot de passe RTSP ;
  - ports RTSP (8554) et WebRTC (8555) ;
  - résolution et cadence (1920x1080 à 30 i/s) ;
  - débit (4 Mb/s, plafond 6 Mb/s, tampon 2 Mb) ;
  - noms de la caméra et du micro, chemin de ffmpeg.

  Le mot de passe n'est rangé que dans le yaml (mode 600), puisque go2rtc doit le lire en clair. L'onglet le relit de
  là.
- **Modèle** : le pipeline en service chez Majid, paramétré. Points obligatoires :
  - `api.listen: "127.0.0.1:1984"`, fixe : ptzd relaie la vidéo de l'app iOS par cette API ;
  - `rtsp.listen: ":<port>"`, avec `username` et `password` ; `webrtc.listen: ":<port>"` ;
  - `ffmpeg.bin: <chemin absolu>` ;
  - `preload: obsbot:` : les deux ffmpeg restent ouverts en permanence ;
  - un stream **`obsbot`**, nom dont dépendent ptzd (`streamName`) et Homebridge, en trois entrées :
    1. la vidéo : `exec:` ffmpeg, avfoundation, `-pixel_format nv12`, `h264_videotoolbox -realtime 1 -g <cadence>
       -bf 0`, débit, `-bsf:v dump_extra=freq=keyframe`, `-an`, `-rtsp_transport tcp -f rtsp {output}`, puis
       `#timeout=30s#killsignal=15` ;
    2. le son : `exec:` ffmpeg, avfoundation `":<micro>"`, `aresample=async=1000:first_pts=0`, AAC 48 kHz stéréo
       128 kb/s, `-vn`, puis les mêmes suffixes ;
    3. `ffmpeg:obsbot#audio=opus`, pour le WebRTC de l'app iOS ;
  - les entrées `exec:` en **`- >-`** (bloc replié **sans** saut de ligne final), jamais `- >`. Sinon go2rtc lit le
    signal `15\n`, envoie le signal 0, et le ffmpeg vidéo fuit (correctif du 04/10) ;
  - `log.level: info`.
- **Régénération** : à chaque changement de réglage appliqué, et au lancement si le modèle a changé avec une nouvelle
  version de PTZBot. Un yaml identique n'est pas réécrit.
- **Fichier personnalisé** (mode expert) : un interrupteur et un chemin. PTZBot lance alors go2rtc sur ce fichier, sans
  jamais l'écrire. Les vérifications de ports et d'appareils sont sautées, et l'état le dit : « fichier personnalisé ».
- **Import d'une configuration existante** : PTZBot lit un yaml choisi par l'utilisateur et en reprend l'identifiant, le
  mot de passe RTSP, les ports, et, s'ils sont reconnus, les noms des appareils et le chemin de ffmpeg. Il montre ce
  qu'il a repris avant d'appliquer. Le fichier importé n'est pas modifié.

## 5. Pannes et états

| Situation | Détection | Ligne d'état (hors état normal) |
|---|---|---|
| ffmpeg absent | § 3.5, avant le lancement | « ffmpeg introuvable » |
| Port pris (8554, 8555 ou 1984) | essai d'ouverture du port juste avant le lancement | « Port 8554 déjà utilisé : un autre go2rtc tourne-t-il ? » |
| Caméra OBSBOT absente | § 3.6 ; puis l'API (`/api/streams`) : le stream n'a pas de producteur actif | « Caméra OBSBOT absente » |
| Accès refusé | journal de go2rtc (erreur d'autorisation d'avfoundation) | « Accès à la caméra refusé », avec un bouton qui ouvre Réglages › Confidentialité |
| Arrêts répétés | § 3.3 | « go2rtc s'arrête sans cesse : ouvrez le journal » |
| coreaudiod bloqué | plus d'un ffmpeg vidéo enfant à deux contrôles de suite, ou `exec: timeout` dans le journal depuis moins de 2 min, **confirmé par deux sondes de suite** de coreaudiod qui ne répondent pas (28/10, 30/10) | ligne **orange** « coreaudiod ne répond pas : la caméra est bloquée », avec un bouton « Copier la commande de réparation » (`sudo killall -9 coreaudiod`) |
| Captures ffmpeg bloquées | plus d'un ffmpeg vidéo enfant à deux contrôles de suite, coreaudiod qui répond à la sonde (ou pas encore sondé) (30/10) | ligne **orange** « Des captures ffmpeg sont bloquées », sans commande ni promesse : le gardien les nettoie quand il le peut (§ 3.2) ; si le signal fort dure plus de 5 min (le gardien n'y arrive pas), « Des captures ffmpeg sont bloquées : ouvrez le journal » |

- **État normal** : la pastille verte, et « · N clients » au survol, avec le détail par protocole (par exemple
  « RTSP ×1, WebRTC ×1 »).
- **Clients** : PTZBot lit `GET http://127.0.0.1:1984/api/streams` toutes les 2 s, **seulement pendant que le panneau
  est ouvert**. Il compte les consommateurs du stream `obsbot` par type.
- **coreaudiod** : PTZBot ne le répare jamais lui-même, puisqu'il faudrait les droits root.
- **Détecteur (28/10)** : un `exec: timeout` seul n'alerte plus (la caméra qui quitte le bus USB pendant une veille du Mac en donne un aussi, constaté le 24/10) ; il ouvre une suspicion de 2 min, pendant laquelle PTZBot lance `system_profiler SPAudioDataType` (énumération des appareils audio par coreaudiod) dans un processus enfant limité à 5 s, hors du fil de l'interface, au plus toutes les 30 s et jamais deux à la fois : réponse à temps, la suspicion est levée ; expirée ou en échec, elle ne suffit pas (une sonde lente juste après un réveil, pendant que les appareils se réénumèrent, n'est pas un blocage) : l'alerte demande deux sondes ratées de suite, à 30 s d'écart, pendant la même suspicion (une suspicion neuve repart de zéro). Une sonde sans résultat au bout de 10 s (enfant impossible à tuer) compte pour ratée, et la suivante peut partir. Plus d'un ffmpeg vidéo doit être vu à deux contrôles de suite, espacés de 4 s au plus (un chevauchement passager pendant un redémarrage d'ffmpeg, au réveil, n'alerte pas ; la fermeture du panneau remet le compte à zéro).
- **Deux états (30/10).** Ce signal fort ne suffit plus à accuser coreaudiod : après une veille qui a coupé la caméra, les ffmpeg figés de go2rtc le donnent aussi, coreaudiod répondant en moins d'une seconde. Il ouvre une suspicion et lance la sonde, aux mêmes règles. Sonde qui répond, ou pas encore de verdict : « Des captures ffmpeg sont bloquées » (puis « … : ouvrez le journal » au-delà de 5 min de signal fort continu, car le gardien épargne pour toujours un ffmpeg qui ne sort pas au 4e SIGTERM, ou dont les sockets sont illisibles), jamais la commande `killall` sur le seul signal fort ; deux sondes ratées de suite : l'alerte coreaudiod, avec sa commande.

## 6. Interface

### 6.1 Panneau

- **Une rangée « go2rtc »** dans la section « Service », juste après ptzd : interrupteur, pastille, et ligne d'état
  hors état normal (§ 5).
- **Pastilles vertes pour tous les services** : ptzd, go2rtc, Talkback, SDK OBSBOT. L'état normal (actif, prêt,
  installé) est une pastille verte, sans ligne. Toute autre situation garde sa ligne d'état actuelle, et l'orange pour
  ce qui demande l'attention.
- Le détail des clients est au survol de la rangée (`help`).

### 6.2 Réglages

La fenêtre passe à deux onglets :
1. **« Général »** : le contenu actuel (mises à jour, ouverture à la connexion, langue).
2. **« Caméra »** :
   - **Diffusion** : identifiant, mot de passe (champ masqué), résolution et cadence, débit ;
   - **Appareils** : caméra et micro, avec les OBSBOT détectés par défaut ;
   - **ffmpeg** : chemin détecté, bouton « Choisir… », et la commande `brew install ffmpeg` s'il manque ;
   - **Avancé** : ports RTSP et WebRTC ; « Utiliser un fichier de configuration personnalisé » et son chemin ;
     « Importer une configuration existante… » ;
   - **Boutons** : « Ouvrir le journal » (Console, sur `go2rtc.log`) et « Ouvrir l'interface web » (le navigateur, sur
     `http://127.0.0.1:1984`).
   - **« Appliquer »** régénère le yaml et relance go2rtc, après l'avertissement « Le flux HomeKit sera coupé quelques
     secondes. » Un réglage qui ne change rien ne relance rien.

Tous les textes sont au vouvoiement et traduits en anglais (catalogues `Localizable.xcstrings`).

## 7. Mise en service chez Majid (migration)

À faire ensemble, Majid présent. La règle « jamais deux go2rtc en même temps » vaut à chaque étape.
1. Installer la 1.1.0. go2rtc est éteint par défaut, et l'ancien agent `com.majid.go2rtc` tourne toujours.
2. Dans l'onglet « Caméra », **importer** `/opt/homebrew/etc/go2rtc.yaml`, vérifier ce qui est repris, puis appliquer.
   Rien n'est lancé tant que l'interrupteur est éteint.
3. **Majid** : `launchctl bootout gui/$(id -u)/com.majid.go2rtc`, puis la plist renommée en `.bak`. C'est un réglage
   système, il le fait lui-même.
4. **Aussitôt**, allumer go2rtc dans PTZBot. Accepter les demandes d'accès à la caméra et au micro pour PTZBot.
5. Vérifier :
   - HomeKit (image et son) ;
   - l'app iOS (vidéo WebRTC et son) ;
   - l'absence de redémarrage en boucle des ffmpeg ;
   - un seul ffmpeg vidéo ;
   - coreaudiod sain.
6. **Prévenir la session go2rtc** :
   - ses scripts de collecte trouvaient go2rtc par le label launchd (`G2W_LABEL`). Ils devront chercher le processus
     `…/PTZBot.app/Contents/Helpers/go2rtc` ;
   - le script `cam` devient obsolète.

Aucun label personnel n'entre dans le code public : la migration est un geste de Majid, guidé par cette procédure.

## 8. Publication et compilation

- **`build-helpers.sh`** : téléchargement et vérification de go2rtc (§ 3.1), compilation du `gardien`, copie dans
  `Contents/Helpers`.
- **`check-bundle.sh`** : go2rtc, `gardien` et la licence de go2rtc sont présents ; le SDK OBSBOT reste absent.
- **Publication** (`outils/publication.py`) :
  - `go2rtc` et `gardien` sont signés comme les autres utilitaires ;
  - les droits caméra et micro sont autorisés sur l'app (§ 3.4) ;
  - le contrôle de fuite et la notarisation s'appliquent au tout.
- **Notes de version 1.1.0**, en anglais puis en français : go2rtc dans PTZBot, ffmpeg à installer avec Homebrew,
  demande d'accès à la caméra et au micro au nom de PTZBot, et « Quitter arrête la caméra HomeKit ».
- **README**, en anglais puis en français : la section go2rtc est réécrite (go2rtc fourni par PTZBot, onglet
  « Caméra », import d'une configuration, ffmpeg). La configuration externe garde un paragraphe, puisque
  l'interrupteur éteint laisse fonctionner un go2rtc à soi.

## 9. Ce qui ne doit pas régresser

| Point | Où c'est tenu |
|---|---|
| go2rtc est le **seul** processus qui ouvre la caméra et le micro | refus si un port est pris (§ 5), interrupteur éteint par défaut |
| `preload: obsbot:` conservé | modèle (§ 4) |
| Entrées en `- >-`, jamais `- >` | modèle, et un test qui compare le yaml généré à un modèle exact |
| Pas de SIGKILL sur un ffmpeg qui capture | arrêt en douceur sur 10 s (§ 3.3), `killsignal=15` |
| Stream `obsbot`, port 8554, mêmes identifiants | modèle et import (§ 4) |
| Mot de passe hors du dépôt | yaml en mode 600 dans Application Support ; aucune valeur réelle dans les tests |
| Priorité de go2rtc | processus enfant d'une app au premier plan. La passation demandait `ProcessType: Interactive` sous launchd : à vérifier au banc (son et vidéo sans saccade) |

## 10. Tests

- **Unitaires** (Swift Testing, attentes bornées, données fictives) :
  - **yaml généré** : comparé à un modèle exact, entrées `- >-`, échappement des noms et du mot de passe ;
  - **import** : yaml complet, partiel, illisible ;
  - **recherche de ffmpeg** : ordre, exécutable absent, chemin réglé ;
  - **détection des appareils** : doublure de la liste AVFoundation ;
  - **superviseur** : lancement, relance, échec, arrêt en douceur (10 s avant SIGKILL), quitter, interrupteur ;
  - **gardien** : parent disparu, puis SIGTERM puis SIGKILL après le délai ; SIGTERM transmis ; code de sortie rendu ;
  - **lecture de l'API** : clients par type, stream sans producteur ;
  - **détecteur coreaudiod** et **ports pris** ;
  - **pastilles** : état normal sans ligne, les autres avec.
- **Banc avec Majid** (§ 7, puis) :
  - quitter et relancer PTZBot : go2rtc et ses ffmpeg s'arrêtent sans SIGKILL ;
  - tuer PTZBot (`kill -9`) : le gardien arrête go2rtc ;
  - débrancher puis rebrancher la caméra ;
  - refuser puis accorder l'accès à la caméra ;
  - fichier personnalisé ;
  - nouvelle demande d'accès après une mise à jour (il ne doit pas y en avoir : identité Developer ID stable).

## 11. Risques

- **Autorisations** : que macOS attribue bien les accès des ffmpeg à PTZBot à travers le gardien et go2rtc. On le
  vérifie en tout premier, par un essai jetable avant le prototype : PTZBot de développement signé Developer ID,
  gardien, go2rtc et ffmpeg sur un autre port, puis la caméra.
- **Priorité** : sans `ProcessType: Interactive`, le son ou l'image pourraient se dégrader. À mesurer au banc. Si c'est
  le cas, le gardien peut demander une priorité plus haute (`setpriority`, QoS) pour go2rtc.
- **coreaudiod** : le va-et-vient de clients CoreAudio reste le déclencheur suspecté. `preload` et l'arrêt en douceur
  le limitent ; le détecteur le signale.

## 12. Résultat de l'essai des autorisations (12/10/2026)

- **Fait.** Le ffmpeg de capture avait bien l'app pour processus responsable, mais **macOS a attribué l'accès à la caméra au programme qui l'ouvre, ffmpeg**, et non à l'app (essai de la tâche 0 du plan). Le § 3.4 ne se vérifie donc pas : la demande porte le nom « ffmpeg », et l'autorisation suit le binaire de Homebrew. Elle est redemandée après chaque `brew upgrade ffmpeg`.
- **Décision de Majid : B3 tel quel.** Les droits caméra et micro de l'app et ses textes d'explication restent : ils préparent l'évolution suivante.
- **Évolution au backlog : un utilitaire de capture signé de PTZBot** (AVFoundation, VideoToolbox et AudioToolbox, flux vers go2rtc par `exec:`). Il remplacerait ffmpeg pour la capture, pour que l'accès soit attribué à PTZBot et survive aux mises à jour. ffmpeg ne servirait plus qu'à l'Opus.

## 13. Précisions du plan (12/10/2026)

Le [plan](../plans/2026-10-12-go2rtc-dans-ptzbot.md) précise la spec sur ces points, sans en changer les choix.

- **Délais d'arrêt (§ 3.3).** Le gardien reçoit `--arret 10` : il laisse 10 s à go2rtc entre SIGTERM et SIGKILL. Le
  superviseur n'envoie SIGKILL au gardien lui-même qu'à 16 s (30/10 : le pire cas du gardien, 10 s pour go2rtc puis
  5 s pour ses ffmpeg, atteignait les 15 s d'avant), et « Quitter » attend 17 s au plus (6 s sans go2rtc).
  Le gardien rend la fin de go2rtc : son code de sortie, ou le même signal.
- **Ffmpeg à la sortie de go2rtc (§ 3.2, § 3.3).** Rien ne garantit que go2rtc arrête ses ffmpeg en sortant : le gardien lance
  go2rtc dans son propre groupe de processus ; une fois go2rtc sorti, le groupe et les enfants que go2rtc avait juste avant
  son premier signal d'arrêt (relevés par libproc, reconnus par leur heure de démarrage) reçoivent SIGTERM, jamais SIGKILL,
  et le gardien les attend 5 s au plus avant de rendre le code de go2rtc. Depuis le 30/10 : 4 SIGTERM à 1 s
  d'intervalle, et les enfants relevés aussi à chaque passage du ménage (§ 3.2).
- **Noms des appareils (§ 3.6).** go2rtc découpe la commande d'ffmpeg sans échappement (`shell.QuoteSplit`) et coupe
  la source au premier `#`. Un nom est donc écrit entre guillemets doubles, ou simples s'il contient un guillemet
  double ; un nom avec les deux sortes de guillemets, un `#` ou un caractère de contrôle est refusé, avec un message.
  Le choix par défaut préfère une OBSBOT réelle à une caméra virtuelle (l'extension d'OBSBOT Center porte aussi le
  nom « OBSBOT »).
- **Réglages (§ 4 et § 6.2).** Un seul réglage de débit : le plafond vaut 1,5 fois le débit, le tampon la moitié
  (4 Mb/s donne 6 et 2, comme le pipeline en service). Résolutions proposées : 1920 × 1080 et 1280 × 720 ; cadences :
  30, 25 et 15 i/s. Sans yaml, PTZBot tire un mot de passe RTSP de 20 caractères ; un identifiant ou un mot de passe
  vide est refusé (le flux serait ouvert à tout le réseau local). Les ports vont de 1024 à 65535, tous différents.
- **Modèle (§ 4).** `#timeout=30s` est gardé tel quel, comme dans le pipeline en service, bien que go2rtc 1.9.14 lise
  `starttimeout` (30 s par défaut) : aucun changement de comportement.
- **Pannes (§ 5).** Les ports vérifiés : RTSP en TCP, WebRTC en TCP et en UDP, l'API sur 127.0.0.1:1984. La sonde ouvre ses
  sockets avec `SO_REUSEADDR` (comme go2rtc : les connexions en TIME_WAIT, 30 s après sa sortie, ne comptent pas) et essaie
  aussi 127.0.0.1 ; un port vu pris au lancement est réessayé toutes les secondes pendant 5 s avant l'échec « port déjà
  utilisé ». Le refus
  d'accès est repéré dans `go2rtc.log` (lignes d'erreur de go2rtc qui citent avfoundation ou exec avec « not
  authorized », « denied » ou « Failed to create AV capture input device ») ; l'essai de la tâche 0 n'a produit aucun
  refus réel (§ 12), donc aucune ligne réelle : elle se relève au banc, et sans ligne reconnaissable l'état retombe sur
  « Caméra OBSBOT absente ». Le journal est relu toutes les 10 s tant que go2rtc tourne, l'API et les processus seulement panneau
  ouvert. Talkback « En lecture » compte comme état normal (pastille verte).
- **Publication (§ 8).** `outils/publication.py` gagne `--droit-requis` (les droits caméra et micro sont exigés sur
  l'app, et, sans bac à sable, aucun autre n'est admis) et `--empreintes-go2rtc` : `Contents/Helpers/go2rtc` doit
  être le binaire officiel, vérifié par son empreinte avant toute signature ; seul ce binaire peut porter des adresses
  au contrôle de fuite du .dmg. `mac/app/go2rtc.sha256` donne l'empreinte de l'archive et celle du binaire.
- **Autorisations (§ 3.4, § 12).** La demande d'accès à la caméra et au micro porte le nom « ffmpeg » et non PTZBot, et
  elle revient après chaque mise à jour de ffmpeg par Homebrew. Le README et les notes 1.1.0 le disent. Les droits
  caméra et micro de l'app et ses textes d'explication restent : ils préparent l'utilitaire de capture signé du
  backlog.

## 14. Le gardien est lancé par launchd (13/10/2026)

Ce paragraphe précise le § 2 (cycle de vie) et le § 3.4 (autorisations), sans changer le résultat attendu : go2rtc ne tourne
que pendant que PTZBot est ouvert.

- **Le défaut constaté au banc.** Quand go2rtc, et donc ses ffmpeg, descendent de PTZBot, macOS affiche dans la barre des
  menus le bouton vert « Effets vidéo » (portrait, arrière-plans), au nom de PTZBot. Cause : les ffmpeg que go2rtc lance
  filment dans la **coalition de l'app**.
- **Les quatre essais du 13/10**, tous avec un ffmpeg qui filme la caméra :
  - lancé par une app : le bouton apparaît ;
  - lancé par une app avec `responsibility_spawnattrs_setdisclaim` : le bouton apparaît toujours ;
  - lancé par launchd (`launchctl bootstrap gui/<uid>` d'une plist rangée hors de `~/Library/LaunchAgents`) : pas de bouton ;
  - lancé par launchd, par le vrai `gardien --parent <PID de PTZBot>`, qui lance ffmpeg : pas de bouton, pas de demande
    d'accès, 331 images en 15 s.

  Un travail launchd forme sa propre coalition : c'est la seule voie qui fait disparaître le bouton.
- **Décision (Majid).** PTZBot lance le **gardien** par launchd, et non plus comme son enfant. Un nouveau lanceur,
  `LaunchdProcessLauncher`, remplace `FoundationProcessLauncher` pour go2rtc seulement ; ptzd ne change pas, et le superviseur
  non plus (relances, sonde des ports, SIGTERM puis SIGKILL du gardien après 15 s).
  - **Une plist de travail** (`go2rtc-launchd.plist`, en 0600) est écrite à côté du yaml, dans le dossier de support de
    l'app, **hors de `~/Library/LaunchAgents`**, puis chargée par `launchctl bootstrap gui/<uid>`. Label
    `io.github.djoko-cli.obsbot-nacelle.go2rtc` ; `RunAtLoad` ; `ProcessType` `Interactive` (comme talkd : Standard
    dégradait le son des enfants de go2rtc, Background faisait saccader la vidéo) ; `ExitTimeOut` 20 ;
    `AbandonProcessGroup` vrai ; le PATH qui mène à ffmpeg en `EnvironmentVariables` ; la sortie du gardien ajoutée à
    `go2rtc.log`.
  - **launchd ne doit jamais signaler les processus restants.** Le gardien laisse volontairement en vie un ffmpeg qui
    capture et ne répond pas à SIGTERM (jamais de SIGKILL, risque de bloquer CMIO) : `AbandonProcessGroup` le demande à
    launchd, si bien que ces processus ne reçoivent que le SIGTERM du gardien, comme avant le passage à launchd. L'effet sur
    un ffmpeg qui survit à la sortie du gardien et au `bootout` reste à confirmer au banc.
  - **Pas de `KeepAlive`** : le travail ne redémarre jamais tout seul, c'est le superviseur qui relance. Un travail resté
    chargé (app tuée) est déchargé avant le lancement suivant (20 s d'attente au plus, même si le `bootout` rend une erreur
    pendant que launchd démonte le travail), et au lancement de l'app quand go2rtc est éteint. Le `bootstrap` est précédé
    d'un `launchctl enable` du label, au cas où l'utilisateur aurait coupé le travail dans « Ouverture ».
  - **L'exigence B est tenue par `--parent`** : si PTZBot disparaît, même par un plantage, le gardien arrête go2rtc et ses
    ffmpeg (§ 3.2, § 13), puis sort. launchd ne remplace pas ce lien ; il ne fait que changer de coalition.
- **Réalisation.**
  - Le PID du gardien est lu dans `launchctl print gui/<uid>/<label>` (ligne `pid = N` du service, à une tabulation de
    retrait) : un sondage toutes les 50 ms, 2 s au plus, sur le MainActor et seulement au démarrage de go2rtc. Sans PID dans
    ce délai : `bootout`, puis une erreur de lancement, que le superviseur montre déjà (`failed(.launch)`).
  - La fin du gardien est suivie par une source `DispatchSource` sur son PID, qui marche sur un processus qui n'est pas
    notre enfant. Course fermée : si le gardien est sorti avant que la source soit armée, `kill(pid, 0)` échoue avec `ESRCH`
    et la sortie est traitée aussitôt. Un gardien déjà sorti avant le premier sondage (go2rtc manquant, code 127) est
    signalé comme une sortie ordinaire, juste après le retour du lancement.
  - À la sortie, le code vient de `launchctl print` : `last exit code = N` donne la sortie N, `last terminating signal =
    <nom>: N` donne un arrêt par le signal N, un code illisible donne un arrêt par signal inconnu (`-1`). Le code 127,
    rendu quand go2rtc manque, reste reconnu. Puis `bootout` du travail et suppression de la plist, hors du fil principal,
    avant que `onExit` revienne sur le MainActor.
- **Conséquence probable pour l'accès à la caméra.** Le travail launchd n'a pas PTZBot pour processus responsable : chez un
  nouvel utilisateur, la demande d'accès sera faite **au nom de ffmpeg**, comme avec un go2rtc lancé par un agent launchd.
  Le § 12 l'avait déjà établi pour le ffmpeg de Homebrew : le § 3.4 (accès attribué à PTZBot) ne se vérifie pas non plus ici.
  Le README et les notes 1.1.0 le disent (§ 13).
- **Résultat du banc (13/10, build 261).**
  - Avec le go2rtc de l'app, aucun bouton « Effets vidéo » et aucune notification « élément d'arrière-plan ajouté ». HomeKit
    et l'app iOS ont l'image et le son.
  - « Quitter » : le gardien, go2rtc et les deux ffmpeg s'arrêtent en une seconde, et le travail launchd est retiré. La
    relance crée un travail neuf, sans « port déjà utilisé ».
  - PTZBot tué (`kill -9`), puis relancé 3 s plus tard : le gardien a tout arrêté en une seconde, et le travail resté chargé
    a été remplacé sans attente.
  - La demande d'accès à la caméra au nom de PTZBot, vue le 13/10 à l'allumage de go2rtc, vient de la recherche des
    appareils de PTZBot lui-même (liste des caméras de l'onglet « Caméra »), pas de ffmpeg.
  - L'essai d'un ffmpeg qui ignore SIGTERM sous `AbandonProcessGroup` n'a pas été fait : il est au backlog.

## 15. La veille du Mac (31/10/2026)

Ce paragraphe ajoute un cas au § 3.3 : go2rtc est arrêté avant la veille du Mac et ne repart qu'au vrai réveil. Conçu avec
Djoko le 31/10/2026, à partir d'un diagnostic fait en lecture seule.

- **Le problème.** Les deux producteurs `exec:` de go2rtc (la capture vidéo et la capture du micro, deux ffmpeg
  avfoundation) tournent en permanence, car Scrypted reste branché.
  - **Chaque veille du Mac est retardée de 30 s.** `pmset -g log` montre, dans « Delays to Sleep notifications », le plus
    souvent exactement deux `ffmpeg timed out(30000 ms)` : ffmpeg n'acquitte jamais l'annonce de veille, et macOS attend
    30 s avant de passer outre.
  - **Des ffmpeg s'accumulent.** À la veille, la capture se fige (la caméra quitte le bus USB). go2rtc relance une paire de
    ffmpeg toutes les 30 s (`[exec] timeout`), qui restent bloqués sur l'appareil absent pendant les réveils sombres.
    go2rtc ne leur envoie que SIGTERM (`killsignal=15`), qu'un ffmpeg figé ignore ; le ménage du gardien (§ 3.2) les
    retire après 180 s et deux passages. On en a vu jusqu'à 12 pendant une veille, et l'alerte « Des captures ffmpeg sont
    bloquées » apparaît.
  - **`killtimeout` (SIGKILL) est exclu** : jamais de SIGKILL sur un ffmpeg qui capture (règle du § 3.2, risque de
    bloquer coreaudiod).
- **La conception (validée par Djoko).**
  - **Avant la veille**, l'app arrête go2rtc par son superviseur : le gardien reçoit SIGTERM, go2rtc arrête ses ffmpeg,
    puis le gardien envoie 4 SIGTERM à 1 s d'intervalle aux ffmpeg restants (§ 3.2, § 13). Elle n'acquitte la veille
    qu'une fois le gardien sorti, **au plus tard 20 s** après l'annonce.
  - **Au vrai réveil seulement**, c'est-à-dire écrans allumés depuis **5 s**, l'app relance go2rtc. Pendant les réveils
    sombres (écrans éteints), aucune capture : tant que la pause dure et que les écrans restent éteints, une nouvelle
    vérification a lieu toutes les **30 s**.
  - **Les délais.** 20 s : macOS attend 30 s chaque client de l'annonce, et PTZBot ne doit pas devenir celui qui retarde la
    veille ; le gardien sort en 15 s au pire (10 s pour go2rtc, 5 s pour ses ffmpeg, § 13), donc 20 s lui laisse sa marge.
    5 s : un réveil complet d'une seconde, capot fermé, suivi d'un retour en réveil sombre, ne relance rien (un nouvel
    événement de réveil reporte la vérification, des écrans éteints la reportent à 30 s). 30 s : le rythme des
    vérifications d'un réveil sombre.
  - **La caméra au réveil.** La caméra USB met quelques secondes à revenir sur le bus. Une caméra ou un micro OBSBOT
    absent au lancement de go2rtc n'est plus un échec immédiat : le superviseur réessaie la préparation toutes les **2 s**,
    **15 fois** (30 s), avec son propre compte, à côté de celui du port pris (§ 5). Cela vaut aussi à l'ouverture de
    session (backlog, « caméra absente au démarrage de session »).
- **Réalisation.**
  - **`Go2RTCSupervisor`** (§ 3.3). `pauseForSleep(completion:)` arrête go2rtc comme `stop` (qui annule déjà une relance,
    un nouvel essai de port et une préparation en cours), puis `isPausedForSleep` reste vrai. `completion` est appelé à la
    sortie du gardien. S'il n'y a rien à arrêter (arrêté ou en échec, interrupteur éteint compris, ou l'app se termine),
    `completion` part tout de suite, sans pause, et l'état ne change pas : un échec reste un échec.
    `resumeAfterSleep()` lève la pause, puis lance go2rtc s'il est allumé ; si le gardien n'est pas encore sorti, go2rtc est
    relancé à sa sortie, comme avec `setEnabled`. Sans pause, elle ne fait rien. Une préparation qui rend
    `cameraMissing` ou `microphoneMissing` est refaite toutes les `deviceRetryDelay` (2 s), `deviceRetries` fois (15),
    comme `portBusy` (`retryPreparation`) ; l'état reste `.starting` pendant ces essais.
  - **Garde.** Tant que la pause dure, `start()` et `restart()` ne lancent rien (« Appliquer » met les réglages de côté : la
    reprise les utilise) et `setEnabled(true)` retient l'interrupteur sans rien lancer. `setEnabled(false)` arrête comme
    avant, et la reprise ne lance alors rien. `stop(forQuit: true)` empêche toute reprise.
  - **`Go2RTCSleepPause`** (PTZBotKit) : la logique entre les événements d'alimentation et le superviseur. Le temps vient du
    `Scheduler` injecté, les écrans d'un prédicat injecté : les tests (`FakeScheduler`) maîtrisent les deux.
    `systemWillSleep(acknowledge:)` appelle `acknowledge` **exactement une fois**, à la fin de l'arrêt ou à 20 s, le premier
    des deux, et annule toute vérification en attente. `systemDidPowerOn()` (IOKit), `systemDidWake()` et
    `screensDidWake()` (`NSWorkspace`) programment, pendant une pause, une vérification dans 5 s (une seule à la fois, un
    nouvel événement la reporte) ; `screensDidSleep()` la reporte à 30 s, pour qu'une vérification reste toujours en
    attente pendant la pause. La vérification relance go2rtc si les écrans sont allumés, sinon elle en programme une
    autre dans 30 s.
  - **`SystemSleepWatcher`** (PTZBotKit) : la colle d'IOKit et de `NSWorkspace`, sans logique, sur le modèle de
    `SystemWakeWatcher` de ptzd. `IORegisterForSystemPower` sur la file principale : une demande de mise en veille
    (`kIOMessageCanSystemSleep`) est acceptée tout de suite, car PTZBot ne refuse jamais une veille ; l'annonce de veille
    (`kIOMessageSystemWillSleep`) n'est acquittée (`IOAllowPowerChange`) que par la pause ; la sortie de veille
    (`kIOMessageSystemHasPoweredOn`) lui est signalée. Les écrans sont allumés quand `CGDisplayIsAsleep(CGMainDisplayID())`
    vaut 0. L'objet est créé par `AppDelegate`, qui le garde aussi longtemps que l'app (le port IOKit garde un pointeur
    non retenu), et armé avant le lancement de go2rtc.
  - **Journal.** Pour le banc, la pause écrit ses étapes dans `go2rtc.log`, à la suite du gardien et de go2rtc (fichier
    ouvert en ajout, une écriture par ligne, erreurs ignorées), sous la forme `HH:mm:ss PTZBot : …` (heure locale) :
    « veille annoncée : go2rtc s'arrête avant la veille » ; « go2rtc arrêté en 2,4 s : la veille peut partir » ;
    « go2rtc toujours en cours d'arrêt après 20 s : la veille part quand même » ; « veille annoncée : go2rtc ne tournait
    pas » ; « sortie de veille : reprise de go2rtc si les écrans restent allumés 5 s » (seulement pendant une pause) ;
    « écrans toujours éteints (réveil sombre) : go2rtc reste arrêté » ; « réveil complet : go2rtc relancé » (ou « réveil
    complet : go2rtc éteint, rien à relancer » si l'interrupteur a été éteint pendant la pause). Aucune ne contient un motif
    que `Go2RTCLogPatterns` reconnaît (§ 5) : un test le vérifie.
- **Ce que ça change.**
  - La veille du Mac n'est plus retardée de 30 s par les captures, et plus aucun ffmpeg ne reste bloqué après une veille :
    plus de `[exec] timeout` ni d'alerte « Des captures ffmpeg sont bloquées » au réveil.
  - La Webcam est absente de Maison pendant la veille, comme avant (l'image se figeait déjà quand la caméra quittait le
    bus USB). Scrypted se reconnecte au réveil, quand go2rtc est relancé (à confirmer au banc).
  - Pendant les réveils sombres, aucune capture. Le panneau montre « Arrêté » pendant la pause : la pause ne change pas
    l'interrupteur.
  - Une caméra encore absente à la reprise ne laisse plus go2rtc en échec : il part dès qu'elle revient, dans les 30 s.
    Une caméra vraiment débranchée n'est annoncée « absente » qu'après ces 30 s.
- **Au banc** (à faire par Djoko) : dans `pmset -g log`, plus de `ffmpeg timed out(30000 ms)` sous « Delays to Sleep
  notifications » ; les lignes `PTZBot : …` dans `go2rtc.log` autour d'une veille, d'un réveil sombre et d'un vrai réveil ;
  la reconnexion de Scrypted ; un capot fermé puis rouvert (réveil complet d'une seconde, puis réveil sombre) ; le gardien
  qui sort en moins de 20 s dans les conditions réelles.
