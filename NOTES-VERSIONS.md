# Release notes · Notes de version

PTZBot for Mac. Each section has an **English** block, then a **Français** block; the same notes go to the GitHub
release and to the update window.

PTZBot pour Mac. Chaque section a un bloc **English**, puis un bloc **Français** ; les mêmes notes servent à la
version GitHub et à la fenêtre de mise à jour.

## 1.1.1

**English**

- **Privacy now turns off the camera's image and microphone.** Until now, privacy only turned the lens down; the picture and the sound kept going to HomeKit and to the iPhone app. With the OBSBOT SDK, the camera now goes straight into its own privacy mode, in one movement and in under a second: the picture is black and the sound is silent, everywhere, while the stream stays connected. When that cannot start right away (SDK not ready, camera just plugged in), the lens turns down at once first, as before.
- PTZBot reads the camera's real state: it only says "Image and microphone off" once the camera confirms it, and "Protection in progress" until then, or "Lens turned away" once the lens has been seen turned down. If the camera does not switch after a second try, privacy turns the lens down and says so.
- While privacy is on, PTZBot reads the camera's state again every 30 seconds, when an iPhone or the Mac app connects, and when the Mac wakes up: if the camera was woken another way (button, remote, OBSBOT app), privacy is applied again.
- If the camera's state cannot be read twice in a row while privacy is on, PTZBot stops saying "Image and microphone off": it shows "Protection in progress" and tries again with a fresh connection to the camera, until it can read the state.
- If the camera loses power while privacy is on, it comes back awake: the lens turns down at once, then the camera's privacy mode follows.
- When you turn privacy off, the camera wakes up and moves back by itself to where it was, in about two seconds. PTZBot then reads its position and zoom, and only sends them again if they differ (for example if the lens had been turned down first).
- PTZBot now keeps its OBSBOT helper loaded as long as it runs, so turning privacy on is always instant, even after hours without touching the app.
- Without the OBSBOT SDK, privacy only turns the lens down, as before. A note under the switch in PTZBot says why the picture and the sound are not turned off (no SDK, SDK update in progress, or the camera did not switch), and so does the status banner of the updated iPhone app.
- After updating from 1.1.0, PTZBot recompiles its OBSBOT helper at first launch and then tells the service, which uses the new helper right away. If Apple's developer tools are missing, the note under **Privacy** asks you to install them, with a link.
- Quitting PTZBot does not wake the camera: privacy stays on, and at the next launch PTZBot reads the camera's state instead of moving it again.
- If the camera cannot leave privacy after two tries, privacy stays on and PTZBot tells you why; turning privacy off again tries again.
- Before going back to 1.1.0, turn privacy off: 1.1.0 does not know the camera's privacy mode.

**Français**

- **La vie privée coupe désormais l'image et le micro de la caméra.** Jusqu'ici, elle ne faisait que baisser l'objectif : l'image et le son continuaient d'arriver dans HomeKit et dans l'app iPhone. Avec le SDK OBSBOT, la caméra passe désormais directement dans son propre mode vie privée, d'un seul mouvement et en moins d'une seconde : l'image est noire et le son muet, partout, alors que le flux reste connecté. Quand ce n'est pas possible tout de suite (SDK pas prêt, caméra tout juste branchée), l'objectif se baisse d'abord, comme avant.
- PTZBot lit l'état réel de la caméra : il n'affiche « Image et micro coupés » qu'une fois que la caméra le confirme, et « Protection en cours » jusque-là, ou « Objectif détourné » une fois l'objectif vu baissé. Si la caméra ne bascule pas après un second essai, la vie privée baisse l'objectif et le dit.
- Pendant la vie privée, PTZBot relit l'état de la caméra toutes les 30 secondes, quand un iPhone ou l'app Mac se connecte, et quand le Mac sort de veille : si la caméra a été réveillée par un autre moyen (bouton, télécommande, app OBSBOT), la vie privée est réappliquée.
- Si l'état de la caméra ne peut pas être lu deux fois de suite pendant la vie privée, PTZBot cesse d'afficher « Image et micro coupés » : il affiche « Protection en cours » et réessaie avec une connexion neuve à la caméra, jusqu'à pouvoir lire l'état.
- Si la caméra perd son alimentation pendant la vie privée, elle revient éveillée : l'objectif se baisse tout de suite, puis le mode vie privée de la caméra suit.
- Quand vous éteignez la vie privée, la caméra se réveille et revient d'elle-même où elle était, en deux secondes environ. PTZBot relit alors sa position et son zoom, et ne les renvoie que s'ils diffèrent (par exemple si l'objectif avait d'abord été baissé).
- PTZBot garde désormais son utilitaire OBSBOT chargé tant qu'il tourne : allumer la vie privée est toujours instantané, même après des heures sans toucher à l'app.
- Sans le SDK OBSBOT, la vie privée ne fait que baisser l'objectif, comme avant. Une note sous l'interrupteur dans PTZBot dit pourquoi l'image et le son ne sont pas coupés (pas de SDK, mise à jour du SDK en cours, ou caméra qui n'a pas basculé), de même que le bandeau d'état de l'app iPhone mise à jour.
- Après la mise à jour depuis la 1.1.0, PTZBot recompile son utilitaire OBSBOT au premier lancement, puis le signale au service, qui utilise aussitôt le nouvel utilitaire. Si les outils de développement d'Apple manquent, la note sous **Vie privée** vous invite à les installer, avec un lien.
- Quitter PTZBot ne réveille pas la caméra : la vie privée reste active, et au prochain lancement PTZBot lit l'état de la caméra au lieu de la faire bouger à nouveau.
- Si la caméra n'arrive pas à quitter la vie privée après deux essais, la vie privée reste active et PTZBot vous dit pourquoi ; éteindre de nouveau la vie privée fait un nouvel essai.
- Avant de revenir à la 1.1.0, éteignez la vie privée : la 1.1.0 ne connaît pas le mode vie privée de la caméra.

## 1.1.0

**English**

- go2rtc is now part of PTZBot: turn on **go2rtc** in the panel (off by default) and PTZBot streams the camera to
  HomeKit and to the iPhone app while it is open. Its settings are in the new **Settings › Camera** tab, where an
  existing go2rtc configuration can be imported.
- go2rtc needs ffmpeg, which PTZBot does not include: install it with Homebrew (`brew install ffmpeg`).
- The first time, macOS may ask for camera access in the name of PTZBot (when PTZBot looks for the cameras listed in
  **Settings › Camera**), then for camera and microphone access in the name of "ffmpeg" (when go2rtc films): choose
  "Allow" every time, both are needed. The request in the name of "ffmpeg" comes back after Homebrew updates ffmpeg.
- When go2rtc is on, quitting PTZBot also stops the HomeKit camera; PTZBot asks for confirmation first.
- In the panel, each service shows a green dot when everything is normal; a status line appears only when something
  needs attention.
- Settings is now a window with tabs in its toolbar, with icons, like the settings of macOS: **General**, **Camera** and
  **OBSBOT SDK**. The window title follows the tab, its height adjusts smoothly, and the last tab you used is remembered.
- The OBSBOT SDK moves into **Settings › OBSBOT SDK**, which shows its state and holds everything the former **OBSBOT
  SDK** window did (choosing the archive, checks, authorization). The SDK line in the panel and the separate window are
  gone; when AI tracking is waiting for the SDK, an **Install SDK…** link under its switch opens that tab.
- go2rtc is now started by macOS (launchd) instead of as part of PTZBot: macOS no longer shows the green **Video
  Effects** button (portrait, backgrounds) in the menu bar while go2rtc is filming, and these effects cannot alter the
  HomeKit stream. go2rtc still stops with PTZBot, even if PTZBot crashes, and nothing is added to Login Items or to
  `~/Library/LaunchAgents`.

**Français**

- go2rtc fait désormais partie de PTZBot : allumez **go2rtc** dans le panneau (éteint par défaut), et PTZBot diffuse
  la caméra vers HomeKit et vers l'app iPhone tant qu'il est ouvert. Ses réglages sont dans le nouvel onglet
  **Réglages › Caméra**, où une configuration go2rtc existante peut être importée.
- go2rtc a besoin de ffmpeg, que PTZBot ne fournit pas : installez-le avec Homebrew (`brew install ffmpeg`).
- La première fois, macOS peut demander l'accès à la caméra au nom de PTZBot (quand PTZBot cherche les caméras listées
  dans **Réglages › Caméra**), puis l'accès à la caméra et au micro au nom de « ffmpeg » (quand go2rtc filme) :
  choisissez « Autoriser » à chaque fois, les deux sont nécessaires. La demande au nom de « ffmpeg » revient après une
  mise à jour de ffmpeg par Homebrew.
- Quand go2rtc est allumé, quitter PTZBot arrête aussi la caméra HomeKit ; PTZBot demande d'abord confirmation.
- Dans le panneau, chaque service montre une pastille verte quand tout est normal ; une ligne d'état n'apparaît que
  quand il faut y prêter attention.
- Les Réglages sont désormais une fenêtre à onglets dans sa barre d'outils, avec des icônes, comme les réglages de
  macOS : **Général**, **Caméra** et **SDK OBSBOT**. Le titre de la fenêtre suit l'onglet, sa hauteur s'ajuste en
  douceur, et le dernier onglet utilisé est retenu.
- Le SDK OBSBOT passe dans **Réglages › SDK OBSBOT**, qui montre son état et reprend tout ce que faisait l'ancienne
  fenêtre **SDK OBSBOT** (choix de l'archive, vérifications, autorisation). La ligne SDK du panneau et la fenêtre
  séparée disparaissent ; quand le suivi IA attend le SDK, un lien **Installer le SDK…** sous son interrupteur ouvre cet
  onglet.
- go2rtc est désormais lancé par macOS (launchd) et non plus comme une partie de PTZBot : macOS n'affiche plus le bouton
  vert « Effets vidéo » (portrait, arrière-plans) dans la barre des menus quand go2rtc filme, et ces effets ne peuvent
  pas altérer le flux HomeKit. go2rtc s'arrête toujours avec PTZBot, même si PTZBot plante, et rien n'est ajouté à
  « Ouverture » ni à `~/Library/LaunchAgents`.

## 1.0.7

**English**

- PTZBot is now signed with an Apple Developer ID and notarized by Apple: a freshly downloaded PTZBot opens without
  "Open Anyway". When updating from an earlier version, macOS says once that the app differs from the versions opened
  before and asks whether to open it: choose "Open Anyway". It may also ask again for access to the local network, and
  you may need to turn "Open at login" on again.
- The project moves to github.com/Djoko-cli/ptzbot; old links redirect there.
- Talkback: an update no longer turns Talkback on by itself when you had turned it off.

**Français**

- PTZBot est désormais signé avec un Developer ID d'Apple et notarisé par Apple : un PTZBot fraîchement téléchargé
  s'ouvre sans « Ouvrir quand même ». Depuis une version précédente, macOS dit une seule fois que l'app diffère des
  versions ouvertes jusque-là et demande s'il faut l'ouvrir : choisissez « Ouvrir quand même ». Il peut aussi
  redemander l'accès au réseau local, et il faudra peut-être réactiver « Ouvrir à la connexion ».
- Le projet passe à github.com/Djoko-cli/ptzbot ; les anciens liens y redirigent.
- Talkback : une mise à jour ne rallume plus Talkback de lui-même quand vous l'aviez éteint.

## 1.0.6

**English**

- Fixes an error that could appear in red under Talkback at each launch after updating from 1.0.4 ("Requestor lacks
  required entitlement"). Talkback itself kept working; the message no longer appears.

**Français**

- Corrige une erreur qui pouvait s'afficher en rouge sous Talkback à chaque lancement après une mise à jour depuis
  la 1.0.4 (« Requestor lacks required entitlement »). Talkback fonctionnait malgré tout ; le message n'apparaît plus.

## 1.0.5

**English**

- Talkback is now installed as a classic background agent (`~/Library/LaunchAgents`) instead of a login item
  registered with macOS. Updates no longer stop Talkback: after an update, PTZBot restarts `talkd` with the new
  version by itself. If Talkback was on, it stays on; nothing to do on your side.
- Talkback can no longer be turned on while PTZBot runs from a temporary location (Downloads or the disk image): move
  PTZBot to the Applications folder first.
- If you delete PTZBot while Talkback is on, see the README to remove the agent.

**Français**

- Talkback est désormais installé comme agent d'arrière-plan classique (`~/Library/LaunchAgents`) au lieu d'un
  élément d'ouverture inscrit auprès de macOS. Les mises à jour n'arrêtent plus Talkback : après une mise à jour,
  PTZBot relance de lui-même `talkd` dans sa nouvelle version. Si Talkback était allumé, il le reste ; rien à faire
  de votre côté.
- Talkback ne peut plus être allumé quand PTZBot tourne depuis un emplacement temporaire (Téléchargements ou image
  disque) : déplacez d'abord PTZBot dans le dossier Applications.
- Si vous supprimez PTZBot avec Talkback allumé, voyez le README pour retirer l'agent.

## 1.0.4

**English**

- The Talkback switch reacts at once: "Starting…" or "Stopping…" shows immediately while macOS registers the agent,
  and the panel no longer freezes.
- In the panel, "Playing" appears and disappears as soon as someone speaks. The talk button of the PTZBot iOS app
  follows Talkback being turned on or off within a fraction of a second.
- If macOS refuses to start Talkback right after it is turned on or after an update, PTZBot now registers it again by
  itself after a few seconds: no need to turn it off and on again.

**Français**

- L'interrupteur Talkback réagit tout de suite : « Démarrage… » ou « Arrêt… » s'affiche aussitôt pendant que macOS
  inscrit l'agent, et le panneau ne se fige plus.
- Dans le panneau, « En lecture » apparaît et disparaît dès qu'on parle. Le bouton pour parler de l'app PTZBot iOS
  suit l'allumage ou l'extinction de Talkback en une fraction de seconde.
- Si macOS refuse de lancer Talkback juste après son allumage ou après une mise à jour, PTZBot le réinscrit de
  lui-même au bout de quelques secondes : plus besoin de l'éteindre puis de le rallumer.

## 1.0.3

**English**

- Talk from the iPhone: with the updated PTZBot iOS app, hold the microphone button to speak through the Mac's
  built-in speakers, at home or away. PTZBot passes the voice to Talkback, which must be on.
- After this update, PTZBot re-registers the Talkback agent by itself at first launch: macOS no longer refuses the
  new version of `talkd`. Nothing to do on your side.

**Français**

- Parler depuis l'iPhone : avec l'app PTZBot iOS à jour, maintenez le bouton micro pour parler par les haut-parleurs
  intégrés du Mac, à la maison ou à distance. PTZBot transmet la voix à Talkback, qui doit être allumé.
- Après cette mise à jour, PTZBot réinscrit de lui-même l'agent Talkback au premier lancement : macOS ne refuse plus
  la nouvelle version de `talkd`. Rien à faire de votre côté.

## 1.0.2

**English**

- Talkback: the microphone button of the camera in the Home app now plays your voice on the Mac's built-in
  speakers, even when PTZBot is closed. Turn on "Talkback" in the panel, give your Homebridge host's address in
  `~/Library/Application Support/ObsbotNacelle/talkd.json` (see the README), then add the Homebridge line given
  there. While someone speaks, the speakers are raised to at least 30 % (or unmuted), then put back. Only your
  Homebridge host and the Mac itself are accepted; no microphone is opened and no sound is recorded.

**Français**

- Talkback : le bouton micro de la caméra dans l'app Maison fait désormais sortir votre voix par les haut-parleurs
  intégrés du Mac, même PTZBot fermé. Allumez « Talkback » dans le panneau, indiquez l'adresse de votre hôte Homebridge
  dans `~/Library/Application Support/ObsbotNacelle/talkd.json` (voir le README), puis ajoutez la ligne Homebridge
  donnée dans le README. Pendant la parole, les haut-parleurs sont remontés à 30 % au moins (ou sortis de la sourdine),
  puis remis comme avant. Seuls votre hôte Homebridge et le Mac lui-même sont acceptés ; aucun micro n'est ouvert
  et aucun son n'est enregistré.

## 1.0.1

**English**

- Instant AI tracking: once the OBSBOT SDK is loaded, turning tracking on or off takes effect within a few
  milliseconds instead of about four seconds. PTZBot keeps `obsbot-ai` running while an iPhone or the Mac is
  controlling the camera, and stops it after ten minutes without activity. The first order after opening the app
  can still take a few seconds, the time for the SDK to load; after that, it is immediate. PTZBot recompiles
  `obsbot-ai` by itself after this update, if the SDK is installed.
- The app now has an icon: the photo of the camera.

**Français**

- Suivi IA instantané : une fois le SDK OBSBOT chargé, allumer ou couper le suivi prend effet en quelques
  millisecondes, au lieu d'environ quatre secondes. PTZBot garde `obsbot-ai` en marche tant qu'un iPhone ou le Mac
  pilote la caméra, et l'arrête après dix minutes sans activité. Le premier ordre après l'ouverture de l'app peut
  encore prendre quelques secondes, le temps que le SDK se charge ; ensuite, c'est immédiat. PTZBot recompile
  `obsbot-ai` seul après cette mise à jour, si le SDK est installé.
- L'app a désormais une icône : la photo de la caméra.

## 1.0.0

**English**

- PTZBot for Mac now comes as a disk image: drag it into Applications. The first time, macOS asks you to confirm
  with "Open Anyway" in System Settings › Privacy & Security.
- Automatic updates with Sparkle, signed with an Ed25519 key: PTZBot checks at launch and every 24 hours, and
  installs when you quit or with "Install and Relaunch". "Check for Updates…" and "Settings…" are in the panel.
- The app speaks English and French, including the errors reported by ptzd. By default it follows macOS; the
  "Language" setting in Settings (Automatic, Français, English) lets you choose.
- obsbot-ai is no longer shipped: PTZBot compiles it on your Mac from the OBSBOT SDK you provide, with Apple's
  developer tools. If you installed the SDK with an earlier build, reinstall it from its archive or folder.

**Français**

- PTZBot pour Mac s'installe désormais depuis une image disque : glissez-le dans Applications. La première fois,
  macOS demande de confirmer par « Ouvrir quand même » dans Réglages Système › Confidentialité et sécurité.
- Mises à jour automatiques par Sparkle, signées par une clé Ed25519 : PTZBot cherche au lancement puis toutes les
  24 heures, et installe à la fermeture ou par « Installer et relancer ». « Rechercher les mises à jour… » et
  « Réglages… » sont dans le panneau.
- L'app parle français et anglais, erreurs de ptzd comprises. Par défaut, elle suit macOS ; le réglage « Langue »
  des Réglages (Automatique, Français, English) permet de choisir.
- obsbot-ai n'est plus livré : PTZBot le compile sur votre Mac à partir du SDK OBSBOT que vous fournissez, avec les
  outils de développement d'Apple. Si vous aviez installé le SDK avec une version précédente, réinstallez-le depuis
  son archive ou son dossier.
