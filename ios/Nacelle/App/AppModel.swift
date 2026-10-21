import Foundation
import NacelleProtocol
import Observation

/// Où en est l'enregistrement (spec enregistrement § 4.4).
enum RecordingState: Equatable {
    case idle
    case recording(since: Date)
    /// Fin de l'écriture du MP4 et ajout à Photos.
    case saving
}

/// Pourquoi un enregistrement s'arrête : le bouton, ou l'un des arrêts automatiques (avec sauvegarde).
enum RecordingStop {
    case user
    case privacy
    case connection
    case background
    case lowSpace
    /// Une erreur d'écriture : l'enregistreur ne peut plus rien écrire.
    case failure
}

/// L'état de l'app : réglages, contrôle de la nacelle et vidéo.
@MainActor
@Observable
final class AppModel {
    var settings: ConnectionSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            // Au premier plan, de nouveaux réglages reconnectent tout de suite, sauf l'adresse retenue
            // à l'appairage : la connexion en cours la vaut déjà.
            if isForeground, !rememberingAddress {
                disconnect()
                activate()
            }
        }
    }

    /// Son voulu (bouton haut-parleur), retenu d'un lancement à l'autre.
    var soundWanted: Bool {
        didSet {
            guard soundWanted != oldValue else { return }
            store.soundOn = soundWanted
            syncSound()
        }
    }

    let ptz: PTZClient
    let video: VideoSession
    /// « Maintenir pour parler » : la voix de l'iPhone vers les haut-parleurs du Mac (spec parler).
    let speaker: Speaker
    /// Connecté (ou en train de se connecter) au contrôle et à la vidéo.
    private(set) var isActive = false
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var rememberingAddress = false
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let scheduler: any Scheduler
    /// Avis bref affiché à la place du bandeau (QR refusé sur un iPhone déjà appairé).
    private(set) var notice: String?
    @ObservationIgnored private var noticeTimer: (any Cancellable)?
    static let noticeDuration: TimeInterval = 5

    // Enregistrement (spec enregistrement § 3 et § 4.4).
    private(set) var recording = RecordingState.idle
    /// L'accès « Ajouter à Photos » est refusé : le bouton rec est atténué mais reste touchable (il explique).
    private(set) var photoAccessDenied = false
    /// Vidéo qui n'est pas dans Photos (ajout échoué, restée après une coupure) : « Réessayer ».
    private(set) var unsavedClip: URL? {
        didSet {
            // Une autre vidéo en attente mérite de nouveau son bandeau.
            if unsavedClip != oldValue { unsavedClipBannerDismissed = false }
        }
    }
    /// Le bandeau d'échec d'ajout a été fermé (✕) : le fichier est gardé, mais plus proposé à l'écran.
    private(set) var unsavedClipBannerDismissed = false
    /// Nombre de vidéos rangées dans Photos : déclenche la vibration de succès.
    private(set) var savedCount = 0
    /// L'ajout en cours, pour que les tests l'attendent.
    @ObservationIgnored private(set) var savingTask: Task<Void, Never>?
    @ObservationIgnored private let services: RecordingServices
    @ObservationIgnored private var clipRecorder: (any ClipRecording)?
    @ObservationIgnored private var clipURL: URL?
    @ObservationIgnored private var unsavedDuration: TimeInterval?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var spaceCheck: (any Cancellable)?
    @ObservationIgnored private var backgroundTask: Int?
    /// Au moins 500 Mo libres pour commencer ; sous 200 Mo en cours de route, arrêt (vérifié toutes les 10 s).
    static let minimumFreeSpaceToStart: Int64 = 500_000_000
    static let minimumFreeSpaceWhileRecording: Int64 = 200_000_000
    static let spaceCheckInterval: TimeInterval = 10

    init(
        store: SettingsStore,
        ptz: PTZClient,
        video: VideoSession,
        scheduler: any Scheduler,
        recording services: RecordingServices,
        speech: SpeechServices
    ) {
        self.store = store
        self.ptz = ptz
        self.video = video
        speaker = Speaker(audio: speech.audio, link: ptz, permission: speech.permission)
        self.scheduler = scheduler
        self.services = services
        settings = store.load()
        soundWanted = store.soundOn
        ptz.onAddressLearned = { [weak self] address, port in
            self?.remember(address, port: port)
        }
        ptz.onPairingRefused = { [weak self] in
            self?.show(StatusBanner.qrRefused)
        }
        // La vie privée coupe le son, sa sortie le rétablit, et un état perdu le coupe aussi.
        // La vie privée, ou un état de ptzd perdu, arrête aussi l'enregistrement en cours.
        ptz.onStateChange = { [weak self] in
            self?.syncSound()
            self?.stopRecordingIfUnsafe()
            self?.stopSpeakingIfUnavailable()
        }
        speaker.onStopped = { [weak self] reason in
            switch reason {
            case .micDenied: self?.show(StatusBanner.micDenied)
            case .failure: self?.show(StatusBanner.micFailed)
            case .release, .connection, .talkbackOff, .background, .interruption: break
            }
        }
        video.onEnded = { [weak self] in
            self?.stopRecording(.connection)
            self?.stopSpeakingIfUnavailable()
        }
        services.files.purgeOldFiles(now: services.now())
        photoAccessDenied = services.photos.access == .denied
    }

    static func live() -> AppModel {
        let scheduler = MainScheduler()
        return AppModel(
            store: SettingsStore(),
            ptz: PTZClient(
                makeTransport: { endpoint in
                    switch endpoint {
                    case .url:
                        URLSessionWebSocketTransport(scheduler: scheduler)
                    case .tls:
                        NWWebSocketTransport(scheduler: scheduler)
                    }
                },
                browser: BonjourServiceBrowser(),
                keys: KeychainDeviceKeyStore(),
                pairingRecord: PairingRecord(),
                scheduler: scheduler
            ),
            video: VideoSession(scheduler: scheduler),
            scheduler: scheduler,
            recording: .live(),
            speech: .live()
        )
    }

    /// Premier plan : connexion au contrôle et à la vidéo (le contrôle envoie takeControl à l'ouverture).
    /// Sans effet si déjà actif : un retour .inactive → .active ne relance rien.
    func activate() {
        isForeground = true
        guard !isActive else { return }
        isActive = true
        syncSound()
        refreshPhotoAccess()
        speaker.refreshAccess()
        recoverLeftoverClip()
        ptz.start(settings: settings)
        // Offre vidéo relayée par ptzd (spec accès local § 8.4).
        video.start { [ptz] offer in
            try await ptz.negotiate(offer: offer)
        }
    }

    /// Inactif (Centre de contrôle, appel, alerte, sélecteur d'apps) : arrêt de la nacelle, sans
    /// déconnecter. Le système peut annuler le glissé du joystick sans qu'aucun relâchement n'arrive.
    func pause() {
        ptz.setJoystick(.zero)
        // Même cause pour la parole : le système peut annuler l'appui sans qu'aucun relâchement n'arrive.
        speaker.release()
    }

    /// Appairage avec le QR code affiché par `ptzd pair` sur le Mac.
    func pair(with link: PairingLink) {
        ptz.pair(with: link)
    }

    /// L'adresse et le port du Mac qui vient d'appairer l'iPhone vont dans le champ s'il est vide
    /// (spec découverte et QR § 8.3, spec app Mac § 9).
    private func remember(_ address: String, port: Int) {
        guard settings.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rememberingAddress = true
        settings.host = address
        settings.ptzdPort = port
        rememberingAddress = false
        ptz.update(settings)
    }

    /// Avis affiché `noticeDuration` à la place du bandeau.
    private func show(_ text: String) {
        notice = text
        noticeTimer?.cancel()
        noticeTimer = scheduler.schedule(after: Self.noticeDuration) { [weak self] in
            self?.notice = nil
        }
    }

    /// Oublie la clé de cet iPhone.
    func forgetPairing() {
        ptz.forgetPairing()
    }

    /// Arrière-plan : arrêt de la nacelle, fermeture du WebSocket et de la vidéo.
    func deactivate() {
        isForeground = false
        speaker.stop(.background)
        // D'abord la sauvegarde : elle démarre sous une tâche de fond avant que l'app ne soit suspendue.
        stopRecording(.background)
        disconnect()
    }

    private func disconnect() {
        isActive = false
        ptz.stop()
        video.stop()
    }

    /// Rien tant que l'app n'est pas au premier plan.
    var bannerText: String? {
        guard isActive else { return nil }
        if let text = cleanFeedBannerText {
            return text
        }
        return StatusBanner.text(for: BannerInputs(
            macUnreachable: ptz.isUnreachable,
            authIssue: ptz.authIssue,
            connecting: ptz.link != .connected || video.phase != .playing,
            state: ptz.state
        ))
    }

    /// Le seul bandeau gardé en mode épuré : un avis (vidéo rangée dans Photos, échec d'enregistrement) ou la
    /// vidéo restée hors de Photos. L'état de la connexion, lui, n'y figure pas.
    var cleanFeedBannerText: String? {
        guard isActive else { return nil }
        if let notice {
            return notice
        }
        if unsavedClip != nil, !unsavedClipBannerDismissed, recording == .idle {
            return StatusBanner.photosFailed
        }
        return nil
    }

    /// Mode épuré voulu (tap sur la vidéo) ; jamais retenu d'un lancement à l'autre.
    private(set) var cleanFeedWanted = false

    /// Mode épuré en vigueur : l'interface est masquée, sauf le bouton rec et le badge pendant un enregistrement.
    /// Seulement connecté, la vidéo jouant et la caméra branchée : dès que l'un manque, l'interface revient avec son
    /// bandeau (une caméra débranchée laisse la connexion ouverte, sur une image figée).
    var cleanFeed: Bool {
        cleanFeedWanted && ptz.link == .connected && video.phase == .playing && ptz.state?.camera == .connected
    }

    /// Un tap sur la vidéo masque l'interface, un autre la fait revenir.
    func toggleCleanFeed() {
        cleanFeedWanted.toggle()
    }

    /// L'écran d'appairage remplace les commandes tant que l'iPhone n'est pas appairé (spec découverte et QR § 8.1).
    var needsPairing: Bool {
        !ptz.isPaired
    }

    /// Où en est l'appairage, sur l'écran d'appairage.
    var pairingStatus: String? {
        if ptz.isPairing {
            return "Appairage…"
        }
        return ptz.authIssue == .badCode ? StatusBanner.qrRefused : nil
    }

    /// Joystick et zoom utilisables : connecté, caméra présente, hors vie privée.
    var controlsEnabled: Bool {
        guard ptz.link == .connected, let state = ptz.state else { return false }
        return state.camera == .connected && !state.privacy
    }

    /// Son joué : voulu, et seulement si ptzd dit que la vie privée est inactive (le micro de la caméra
    /// capte la pièce). État inconnu (connexion en cours ou perdue) : coupé, car la vidéo, elle, continue.
    var soundPlaying: Bool {
        soundWanted && ptz.state?.privacy == false
    }

    /// Bouton son utilisable : hors vie privée, état connu.
    var soundToggleEnabled: Bool {
        ptz.state?.privacy == false
    }

    /// Applique `soundPlaying` à la vidéo : au départ, au bouton et à chaque changement d'état de ptzd.
    func syncSound() {
        video.setPlaysAudio(soundPlaying)
    }

    /// Le dernier ordre de suivi IA est « allumé ».
    var aiTrackingOn: Bool {
        ptz.state?.aiTracking == .on
    }

    /// Un ordre de suivi IA est en cours : obsbot-ai démarre ou travaille (`control == .taking`).
    var aiTrackingBusy: Bool {
        ptz.state?.control == .taking
    }

    /// Bouton du suivi IA utilisable : connecté, caméra présente, hors vie privée, aucun ordre en cours.
    var aiToggleEnabled: Bool {
        ptz.link == .connected && ptz.state?.camera == .connected && ptz.state?.privacy == false && !aiTrackingBusy
    }

    /// Allume le suivi s'il n'est pas allumé (coupé ou inconnu), le coupe sinon.
    func toggleAITracking() {
        ptz.setAITracking(!aiTrackingOn)
    }

    /// L'exposition automatique est voulue (spec § 6.11).
    var autoExposureOn: Bool {
        ptz.state?.autoExposure == .on
    }

    /// Bouton d'exposition automatique utilisable : connecté, caméra présente, et ptzd tient l'ordre (SDK là, obsbot-ai à
    /// jour). Un ptzd d'avant l'exposition automatique ne publie rien : grisé. Utilisable pendant la vie privée.
    var autoExposureToggleEnabled: Bool {
        guard ptz.link == .connected, let state = ptz.state, state.camera == .connected else { return false }
        return state.autoExposure == .on || state.autoExposure == .off
    }

    /// Active l'exposition automatique si elle ne l'est pas, la désactive sinon (retour au réglage d'avant).
    func toggleAutoExposure() {
        ptz.setAutoExposure(!autoExposureOn)
    }

    /// Bouton vie privée utilisable : connecté et caméra présente.
    var privacyToggleEnabled: Bool {
        ptz.link == .connected && ptz.state?.camera == .connected
    }

    // MARK: Parole

    /// Ce qui permet, ou non, de parler (spec parler § 6.1).
    enum SpeakAvailability: Equatable {
        case ready
        /// Pas de connexion à ptzd, ou son état n'est pas encore connu.
        case noConnection
        /// Talkback est éteint (ou absent) sur le Mac.
        case talkbackOff
        /// La vidéo n'est pas en lecture : le périphérique audio de WebRTC ne tourne pas, et la parole en dépend.
        case noVideo
    }

    var speakAvailability: SpeakAvailability {
        guard ptz.link == .connected, let state = ptz.state else { return .noConnection }
        guard state.talkback == .ready else { return .talkbackOff }
        return video.phase == .playing ? .ready : .noVideo
    }

    /// Bouton atténué : parler est impossible, ou le micro est refusé (il reste touchable : il explique).
    /// La vie privée n'empêche pas de parler : parler ne montre rien et n'écoute rien de la pièce.
    var speakDimmed: Bool {
        speakAvailability != .ready || speaker.micDenied
    }

    /// Le doigt est sur le bouton et le micro est ouvert ou en train de l'être.
    var isSpeaking: Bool {
        speaker.isActive
    }

    /// Appui pris en compte, micro pas encore en direct : bouton rouge avec un anneau, jauge muette.
    /// VoiceOver annonce « Préparation du micro ».
    var isPreparingSpeak: Bool {
        speaker.isPreparing
    }

    /// Niveau du micro pour la jauge ; nul tant que le micro n'est pas en direct.
    var micLevel: Float {
        speaker.isMicLive ? speaker.level : 0
    }

    /// Le doigt se pose sur le bouton : parle, ou dit pourquoi c'est impossible.
    func pressSpeak() {
        switch speakAvailability {
        case .noConnection:
            show(StatusBanner.speakNoConnection)
        case .talkbackOff:
            show(StatusBanner.speakTalkbackOff)
        case .noVideo:
            show(StatusBanner.speakNoVideo)
        case .ready:
            // Démarrage immédiat : `press` pose le doigt (`desired`) et la phase `.starting` avant de rendre la main. Avec
            // une `Task` ordinaire, un relâchement traité avant que la tâche ne démarre serait perdu, et le micro
            // s'ouvrirait ensuite sans aucun doigt posé.
            Task.immediate { await speaker.press() }
        }
    }

    /// Le doigt se lève.
    func releaseSpeak() {
        speaker.release()
    }

    /// Connexion perdue, Talkback devenu indisponible ou vidéo perdue : la parole s'arrête.
    private func stopSpeakingIfUnavailable() {
        guard speaker.isActive else { return }
        switch speakAvailability {
        case .ready: break
        case .noConnection: speaker.stop(.connection)
        case .talkbackOff: speaker.stop(.talkbackOff)
        case .noVideo: speaker.stop(.connection)
        }
    }

    // MARK: Enregistrement

    /// Bouton rec utilisable : au repos, état de ptzd connu, hors vie privée, vidéo en lecture et une image reçue ; pendant
    /// l'enregistrement, toujours (c'est le bouton d'arrêt) ; pendant la sauvegarde, jamais.
    var recordToggleEnabled: Bool {
        switch recording {
        case .recording: true
        case .saving: false
        case .idle: ptz.state?.privacy == false && video.phase == .playing && video.hasFrame
        }
    }

    /// « Réessayer » est proposé : une vidéo attend son ajout à Photos et aucun avis ne couvre le bandeau.
    var showsRetry: Bool {
        unsavedClip != nil && !unsavedClipBannerDismissed && recording == .idle && notice == nil && isActive
    }

    /// Relit l'autorisation Photos (l'utilisateur a pu la changer dans Réglages).
    func refreshPhotoAccess() {
        photoAccessDenied = services.photos.access == .denied
    }

    /// Bouton rec : démarre au repos, arrête pendant l'enregistrement, ne fait rien pendant la sauvegarde.
    func toggleRecording() async {
        switch recording {
        case .idle:
            await startRecording()
        case .recording:
            stopRecording(.user)
        case .saving:
            break
        }
    }

    private func startRecording() async {
        guard !starting, recording == .idle, recordToggleEnabled else { return }
        starting = true
        defer { starting = false }
        var access = services.photos.access
        if access == .notDetermined {
            access = await services.photos.requestAccess()
        }
        photoAccessDenied = access == .denied
        guard access != .denied else {
            show(StatusBanner.photosDenied)
            return
        }
        // Pendant la demande d'accès, la vie privée ou une coupure ont pu changer la donne.
        guard isActive, recording == .idle, recordToggleEnabled else { return }
        guard services.freeSpace() >= Self.minimumFreeSpaceToStart else {
            show(StatusBanner.lowSpaceAtStart)
            return
        }
        let recorder = services.makeRecorder()
        let url = services.files.newFileURL(now: services.now())
        do {
            try recorder.start(url: url, audioSource: video.audioRing)
        } catch {
            show(StatusBanner.recordingFailed)
            return
        }
        // Une erreur d'écriture arrête l'enregistrement tout de suite (sinon l'écran afficherait « ● 12:34 »
        // jusqu'à l'appui). Le rappel vient d'un autre fil ; on ignore celui d'un enregistreur déjà remplacé.
        recorder.onFailure = { [weak self, weak recorder] in
            Task { @MainActor in
                guard let self, let recorder, self.clipRecorder === recorder else { return }
                self.stopRecording(.failure)
            }
        }
        clipRecorder = recorder
        clipURL = url
        video.beginRecording(with: recorder)
        recording = .recording(since: services.now())
        scheduleSpaceCheck()
    }

    /// Arrête l'enregistrement et sauve ce qui a été filmé. Sans effet hors enregistrement.
    func stopRecording(_ reason: RecordingStop) {
        guard case .recording = recording, let recorder = clipRecorder, let url = clipURL else { return }
        recording = .saving
        spaceCheck?.cancel()
        spaceCheck = nil
        video.endRecording()
        clipRecorder = nil
        clipURL = nil
        // Du temps de plus si l'app passe en arrière-plan en pleine sauvegarde.
        backgroundTask = services.background.begin(name: "Sauvegarde de la vidéo") { [weak self] in
            // iOS reprend la main : le fichier reste et sera proposé au retour.
            self?.endBackgroundTask()
        }
        let stopNotice = switch reason {
        case .lowSpace: StatusBanner.lowSpaceStopped
        case .failure: StatusBanner.recordingFailed
        case .user, .privacy, .connection, .background: nil as String?
        }
        if let stopNotice {
            show(stopNotice)
        }
        savingTask = Task {
            await finishAndSave(recorder, at: url, stopNotice: stopNotice)
        }
    }

    private func finishAndSave(_ recorder: any ClipRecording, at url: URL, stopNotice: String?) async {
        defer {
            recording = .idle
            endBackgroundTask()
        }
        let result: RecordingResult
        do {
            result = try await recorder.finish()
        } catch {
            // Fichier lisible (MP4 fragmenté) : on l'ajoute à Photos comme une réussite, sans durée connue.
            // Illisible : effacé, avec l'avis d'échec. Si Photos refuse, `save` le garde avec « Réessayer ».
            if await services.files.isPlayable(url) {
                await save(url, duration: nil, stopNotice: stopNotice)
            } else {
                services.files.remove(url)
                show(StatusBanner.recordingFailed)
            }
            return
        }
        await save(result.url, duration: result.duration, stopNotice: stopNotice)
    }

    /// Ajoute la vidéo à Photos, puis efface le fichier. En cas d'échec, il reste et « Réessayer » est proposé.
    private func save(_ url: URL, duration: TimeInterval?, stopNotice: String?) async {
        do {
            try await services.photos.save(videoAt: url)
        } catch {
            unsavedClip = url
            unsavedDuration = duration
            notice = nil
            noticeTimer?.cancel()
            return
        }
        services.files.remove(url)
        if unsavedClip == url {
            unsavedClip = nil
            unsavedDuration = nil
        }
        savedCount += 1
        let saved = StatusBanner.saved(duration: duration)
        show(stopNotice.map { "\($0) \(saved)" } ?? saved)
    }

    /// ✕ du bandeau « La vidéo n'a pas pu être ajoutée à Photos. » : le bandeau et « Réessayer » disparaissent,
    /// l'état de connexion reprend sa place. Le fichier reste dans le dossier temporaire (effacé au bout de 7 jours).
    func dismissUnsavedClipBanner() {
        unsavedClipBannerDismissed = true
    }

    /// « Réessayer » : un nouvel ajout de la vidéo restée dans le dossier temporaire.
    func retrySave() async {
        guard let url = unsavedClip, recording == .idle else { return }
        recording = .saving
        // Comme à l'arrêt : du temps de plus si l'app passe en arrière-plan pendant le réessai.
        backgroundTask = services.background.begin(name: "Sauvegarde de la vidéo") { [weak self] in
            self?.endBackgroundTask()
        }
        defer {
            recording = .idle
            endBackgroundTask()
        }
        var access = services.photos.access
        if access == .notDetermined {
            access = await services.photos.requestAccess()
        }
        photoAccessDenied = access == .denied
        guard access != .denied else {
            show(StatusBanner.photosDenied)
            return
        }
        await save(url, duration: unsavedDuration, stopNotice: nil)
    }

    private func endBackgroundTask() {
        guard let id = backgroundTask else { return }
        backgroundTask = nil
        services.background.end(id)
    }

    /// Vie privée ou état de ptzd perdu : arrêt avec sauvegarde.
    private func stopRecordingIfUnsafe() {
        guard case .recording = recording else { return }
        guard let state = ptz.state else {
            stopRecording(.connection)
            return
        }
        if state.privacy {
            stopRecording(.privacy)
        }
    }

    private func scheduleSpaceCheck() {
        spaceCheck = scheduler.schedule(after: Self.spaceCheckInterval) { [weak self] in
            self?.checkFreeSpace()
        }
    }

    private func checkFreeSpace() {
        guard case .recording = recording else { return }
        if services.freeSpace() < Self.minimumFreeSpaceWhileRecording {
            stopRecording(.lowSpace)
        } else {
            scheduleSpaceCheck()
        }
    }

    /// Une vidéo restée dans le dossier temporaire (iOS a repris la main en pleine sauvegarde, ou l'app a été
    /// fermée) est proposée au retour si elle se lit ; illisible, elle est effacée.
    private func recoverLeftoverClip() {
        guard recording == .idle, unsavedClip == nil, !starting else { return }
        Task {
            for url in services.files.leftoverFiles() {
                // L'état a pu changer pendant l'attente (un enregistrement a pu démarrer).
                guard recording == .idle, clipURL == nil, unsavedClip == nil else { return }
                if await services.files.isPlayable(url) {
                    guard recording == .idle, clipURL == nil else { return }
                    unsavedClip = url
                    unsavedDuration = nil
                    return
                }
                guard recording == .idle, clipURL == nil else { return }
                services.files.remove(url)
            }
        }
    }
}
