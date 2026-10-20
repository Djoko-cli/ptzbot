import Foundation
import NacelleProtocol
import Network
import Observation
import os

/// Dialogue avec ptzd (spec § 7.2, spec accès local § 8, spec découverte et QR § 8) : à chaque
/// connexion, l'adresse du champ et le service Bonjour du réseau local sont essayés ensemble ; la
/// première connexion authentifiée l'emporte. Puis prise en main, `move` répété 10 fois par seconde
/// tant que le joystick est hors du centre, reconnexion espacée. Un QR code scanné remplace ces
/// candidates par ses adresses et Bonjour, en TLS avec le secret du QR, le temps de l'appairage.
@MainActor
@Observable
final class PTZClient {
    enum Link: Equatable {
        case idle
        case connecting
        case connected
        case waitingToRetry
    }

    /// Ce qui empêche l'authentification. Un verdict de ptzd par Tailscale (`unpaired`, `rejected`),
    /// l'expulsion, l'absence de clé et l'échec d'un premier appairage arrêtent les reconnexions jusqu'à ce
    /// que l'utilisateur agisse (ou le prochain retour au premier plan). Les autres verdicts d'un service du réseau local les laissent continuer ; effacés à chaque
    /// nouvelle tentative.
    enum AuthIssue: Equatable {
        /// Pas de clé, ou ptzd ne connaît pas cet iPhone.
        case unpaired
        /// Signature refusée.
        case rejected
        /// QR code refusé : preuve fausse, appairage expiré ou déjà utilisé, ou aucun Mac n'a répondu
        /// avec le secret du QR (spec découverte et QR § 9).
        case badCode
        /// Expulsé par le Mac pour quelques minutes (spec app Mac § 7.3). Le verdict vient d'une connexion
        /// authentifiée (TLS à clé pré-partagée ou Tailscale) : il arrête les reconnexions par tous les chemins.
        case blocked
    }

    /// Pourquoi une négociation vidéo n'a pas abouti.
    enum NegotiationError: Error, Equatable {
        /// Pas de connexion authentifiée dans le délai.
        case notConnected
        /// Connexion perdue ou fermée pendant la négociation.
        case connectionLost
        /// Pas de réponse de ptzd dans le délai.
        case timeout
        /// go2rtc n'a pas répondu à ptzd (`webrtcError`).
        case relay(String)
    }

    static let repeatInterval: TimeInterval = 0.1
    /// Délai d'une négociation vidéo, attente de la connexion comprise.
    static let negotiationTimeout: TimeInterval = 10
    /// Temps laissé au Mac pour fermer la connexion après `forgetMe`.
    static let forgetTimeout: TimeInterval = 2
    static let retryDelays: [TimeInterval] = [1, 2, 4, 8]
    /// Temps laissé à Bonjour pour trouver ptzd sur le réseau local, à chaque tentative.
    static let discoveryWindow: TimeInterval = 3
    /// Temps laissé à chaque connexion pour s'authentifier, comme ptzd côté serveur.
    static let authTimeout: TimeInterval = 10
    private static let logger = Logger(subsystem: "io.github.djoko-cli.nacelle", category: "ptz")

    private(set) var link: Link = .idle
    /// Dernier état reçu de ptzd ; nil hors connexion.
    private(set) var state: StateSnapshot? {
        didSet {
            if state != oldValue {
                onStateChange?()
            }
        }
    }
    /// Appelé à chaque changement d'état, y compris sa perte (nil) quand la connexion tombe.
    @ObservationIgnored var onStateChange: (() -> Void)?
    /// Dernière erreur renvoyée par ptzd.
    private(set) var lastError: ErrorCode?
    /// Vrai quand une tentative de connexion a échoué, jusqu'à la prochaine réussite.
    /// Remis à faux par `start(settings:)` et `stop()` : le bandeau revient à « Connexion… ».
    private(set) var isUnreachable = false
    private(set) var authIssue: AuthIssue?
    /// Cet iPhone s'est déjà authentifié, ou vient d'être appairé (enregistré).
    private(set) var isPaired: Bool
    /// Un QR code scanné attend la réponse du Mac.
    var isPairing: Bool {
        pendingPairing != nil
    }

    @ObservationIgnored private let makeTransport: (WebSocketEndpoint) -> any WebSocketTransport
    @ObservationIgnored private let browser: any ServiceBrowser
    @ObservationIgnored private let keys: any DeviceKeyStoring
    @ObservationIgnored private let pairingRecord: PairingRecord
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private let deviceName: String
    /// Adresse IPv4 du Mac qui vient d'appairer cet iPhone, à retenir dans le champ (spec découverte et QR § 8.3).
    @ObservationIgnored var onAddressLearned: ((_ host: String, _ port: Int) -> Void)?
    /// QR code refusé alors que l'iPhone était déjà appairé : simple avis, la connexion normale reprend.
    @ObservationIgnored var onPairingRefused: (() -> Void)?
    /// Réglages du dernier `start` ; nil à l'arrêt.
    @ObservationIgnored private var settings: ConnectionSettings?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var openedThisAttempt = false
    @ObservationIgnored private var candidates: [Candidate] = []
    @ObservationIgnored private var active: Candidate?
    @ObservationIgnored private var nextCandidateID = 0
    @ObservationIgnored private var foundLocal = false
    /// Verdict d'un service du réseau local pour la tentative en cours : affiché si la tentative
    /// échoue sans autre verdict, sans arrêter les reconnexions.
    @ObservationIgnored private var localIssue: AuthIssue?
    /// `authIssue` vient d'un verdict qui arrête les reconnexions (`giveUp`) : conservé d'une tentative à l'autre.
    @ObservationIgnored private var authIssueBlocks = false
    @ObservationIgnored private var discovery: (any Cancellable)?
    @ObservationIgnored private var retry: (any Cancellable)?
    @ObservationIgnored private var repeater: (any Cancellable)?
    /// `forgetMe` envoyé : attente de la fermeture de la connexion, bornée par `forgetTimeout`.
    @ObservationIgnored private var forgetTimer: (any Cancellable)?
    @ObservationIgnored private var currentMove = JoystickVector.zero
    /// QR code scanné, en attente d'appairage. Son secret n'est jamais rangé (spec découverte et QR § 8.3).
    private var pendingPairing: PairingLink?
    @ObservationIgnored private var pairingCandidate: Candidate?
    @ObservationIgnored private var nextOfferID = 0
    /// Négociations vidéo en attente de `webrtcAnswer`, par identifiant d'offre.
    @ObservationIgnored private var negotiations: [Int: CheckedContinuation<String, any Error>] = [:]
    /// Négociations en attente d'une connexion authentifiée.
    @ObservationIgnored private var waitingForLink: [Int: CheckedContinuation<Void, any Error>] = [:]

    /// Une connexion en cours d'essai ou retenue.
    private final class Candidate {
        let id: Int
        let transport: any WebSocketTransport
        /// Ouverte en TLS vers le réseau local (service Bonjour ou adresse locale), pas vers Tailscale.
        let isLocal: Bool
        /// Défi reçu, en attente de réponse.
        var nonce: Data?
        /// `auth` envoyé : seule une telle connexion peut recevoir un `authenticated` valable.
        var authSent = false
        /// Échéance d'authentification.
        var deadline: (any Cancellable)?

        init(id: Int, transport: any WebSocketTransport, isLocal: Bool) {
            self.id = id
            self.transport = transport
            self.isLocal = isLocal
        }
    }

    init(
        makeTransport: @escaping (WebSocketEndpoint) -> any WebSocketTransport,
        browser: any ServiceBrowser,
        keys: any DeviceKeyStoring,
        pairingRecord: PairingRecord,
        scheduler: any Scheduler,
        deviceName: String = "iPhone"
    ) {
        self.makeTransport = makeTransport
        self.browser = browser
        self.keys = keys
        self.pairingRecord = pairingRecord
        self.scheduler = scheduler
        self.deviceName = deviceName
        isPaired = pairingRecord.isPaired
        browser.onFound = { [weak self] endpoint in
            self?.found(endpoint)
        }
    }

    func start(settings: ConnectionSettings) {
        // Un `forgetMe` déjà parti : l'oubli s'achève ici, `connect()` s'arrêtera sur « non appairé ».
        if forgetTimer != nil {
            eraseLocalPairing()
        }
        self.settings = settings
        attempt = 0
        isUnreachable = false
        retry?.cancel()
        retry = nil
        connect()
    }

    /// Passage en arrière-plan : arrêt de la nacelle, puis fermeture.
    func stop() {
        // Un `forgetMe` déjà parti : l'oubli local s'achève tout de suite au lieu d'être abandonné.
        if forgetTimer != nil {
            eraseLocalPairing()
            authIssue = .unpaired
            authIssueBlocks = true
        }
        if currentMove != .zero {
            send(.move(pan: 0, tilt: 0))
        }
        currentMove = .zero
        stopRepeating()
        retry?.cancel()
        retry = nil
        settings = nil
        closeAll()
        link = .idle
        state = nil
        isUnreachable = false
        failNegotiations(.connectionLost)
    }

    /// Négociation vidéo relayée par ptzd (spec accès local § 8.4) : attend la connexion
    /// authentifiée si besoin, puis envoie l'offre ; 10 s au plus en tout.
    func negotiate(offer: String) async throws -> String {
        nextOfferID += 1
        let id = nextOfferID
        let deadline = scheduler.schedule(after: Self.negotiationTimeout) { [weak self] in
            self?.expire(id)
        }
        defer { deadline.cancel() }
        if link != .connected {
            try await withCheckedThrowingContinuation { continuation in
                waitingForLink[id] = continuation
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            negotiations[id] = continuation
            send(.webrtcOffer(id: id, sdp: offer))
        }
    }

    private func expire(_ id: Int) {
        waitingForLink.removeValue(forKey: id)?.resume(throwing: NegotiationError.notConnected)
        negotiations.removeValue(forKey: id)?.resume(throwing: NegotiationError.timeout)
    }

    private func failNegotiations(_ error: NegotiationError) {
        let waiting = waitingForLink
        let pending = negotiations
        waitingForLink = [:]
        negotiations = [:]
        waiting.values.forEach { $0.resume(throwing: error) }
        pending.values.forEach { $0.resume(throwing: error) }
    }

    /// Nouveaux réglages pris en compte à la tentative suivante, sans couper la connexion
    /// (adresse retenue après un appairage).
    func update(_ settings: ConnectionSettings) {
        guard self.settings != nil else { return }
        self.settings = settings
    }

    /// Appairage avec le QR code de `ptzd pair` : connexion relancée vers ses adresses et Bonjour.
    func pair(with link: PairingLink) {
        pendingPairing = link
        authIssue = nil
        authIssueBlocks = false
        restart()
    }

    /// Oublie la clé et l'appairage. Connecté, demande d'abord au Mac de retirer cet iPhone de sa liste
    /// (`forgetMe`), puis attend la fermeture de la connexion, au plus `forgetTimeout` ; sinon, tout de suite.
    /// Dans les deux cas ptzd refusera cet iPhone jusqu'au prochain appairage.
    func forgetPairing() {
        guard link == .connected else {
            forgetLocally()
            return
        }
        guard forgetTimer == nil else { return }
        send(.forgetMe)
        forgetTimer = scheduler.schedule(after: Self.forgetTimeout) { [weak self] in
            self?.forgetLocally()
        }
    }

    /// Clé et appairage oubliés. `giveUp` : le Mac a retiré l'iPhone pendant la session ; on s'arrête sur
    /// « non appairé » au lieu de relancer une connexion qu'il refuserait.
    private func forgetLocally(giveUp stop: Bool = false) {
        eraseLocalPairing()
        if stop {
            giveUp(.unpaired)
        } else {
            restart()
        }
    }

    /// Clé supprimée, appairage oublié, minuterie d'oubli soldée.
    private func eraseLocalPairing() {
        forgetTimer?.cancel()
        forgetTimer = nil
        keys.delete()
        setPaired(false)
        pendingPairing = nil
    }

    func setJoystick(_ vector: JoystickVector) {
        let wasMoving = currentMove != .zero
        currentMove = vector
        guard vector != .zero else {
            stopRepeating()
            if wasMoving {
                send(.move(pan: 0, tilt: 0))
            }
            return
        }
        send(.move(pan: vector.pan, tilt: vector.tilt))
        if repeater == nil {
            scheduleRepeat()
        }
    }

    func setZoom(_ value: Int) {
        send(.zoom(value: value))
    }

    /// Allume ou coupe le suivi IA de la caméra (spec app Mac § 7.5).
    func setAITracking(_ on: Bool) {
        send(.aiTracking(on: on))
    }

    func setPrivacy(_ on: Bool) {
        send(.privacy(on: on))
    }

    /// Active ou désactive l'exposition automatique de la caméra (spec § 6.11).
    func setAutoExposure(_ on: Bool) {
        send(.autoExposure(on: on))
    }

    func takeControl() {
        send(.takeControl)
    }

    // MARK: - Connexions

    private func restart() {
        guard settings != nil else { return }
        retry?.cancel()
        retry = nil
        attempt = 0
        connect()
    }

    /// Une tentative. Appairage : chaque adresse du QR et Bonjour, avec le secret du QR. Sinon : l'adresse
    /// du champ tout de suite, et Bonjour si l'iPhone a son secret du réseau local. Sans clé, rien à tenter.
    private func connect() {
        guard let settings else { return }
        closeAll()
        link = .connecting
        openedThisAttempt = false
        foundLocal = false
        localIssue = nil
        if !authIssueBlocks {
            authIssue = nil
        }
        if let pairing = pendingPairing {
            let credentials = Self.credentials(for: pairing)
            for host in pairing.hosts {
                if let url = ConnectionSettings.webSocketURL(host: host, port: pairing.port) {
                    open(.tls(.url(url), credentials))
                }
            }
        } else {
            guard keys.load() != nil else {
                setPaired(false)
                giveUp(.unpaired)
                return
            }
            if let endpoint = settings.endpoint(credentials: deviceCredentials()) {
                open(endpoint)
            }
        }
        if lanCredentials() != nil {
            browser.start()
        }
        discovery = scheduler.schedule(after: Self.discoveryWindow) { [weak self] in
            self?.discoveryEnded()
        }
    }

    /// Identité TLS `pair-<pairingID>` et secret du QR code.
    private static func credentials(for pairing: PairingLink) -> LANCredentials {
        LANCredentials(identity: NacelleTLS.pairingIdentity(pairing.pairingID), key: pairing.secret)
    }

    /// Identité (`deviceID`) et secret remis à l'appairage, si l'iPhone a les deux.
    private func deviceCredentials() -> LANCredentials? {
        guard let key = keys.load(), let lanKey = keys.lanKey() else { return nil }
        return LANCredentials(identity: key.deviceID, key: lanKey)
    }

    /// De quoi ouvrir le TLS du réseau local pour la tentative en cours.
    private func lanCredentials() -> LANCredentials? {
        pendingPairing.map(Self.credentials(for:)) ?? deviceCredentials()
    }

    private func found(_ endpoint: NWEndpoint) {
        guard link == .connecting, active == nil, !foundLocal, let credentials = lanCredentials() else { return }
        foundLocal = true
        open(.tls(endpoint, credentials))
    }

    private func discoveryEnded() {
        discovery = nil
        browser.stop()
        if candidates.isEmpty, active == nil {
            attemptFailed()
        }
    }

    private func open(_ endpoint: WebSocketEndpoint) {
        nextCandidateID += 1
        let isLocal: Bool
        if case .tls = endpoint {
            isLocal = true
        } else {
            isLocal = false
        }
        let candidate = Candidate(id: nextCandidateID, transport: makeTransport(endpoint), isLocal: isLocal)
        candidates.append(candidate)
        candidate.transport.onEvent = { [weak self, weak candidate] event in
            guard let self, let candidate else { return }
            self.handle(event, from: candidate)
        }
        candidate.deadline = scheduler.schedule(after: Self.authTimeout) { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            self.close(candidate)
            self.failAttemptIfOver()
        }
        candidate.transport.open(endpoint)
    }

    private func closeAll() {
        discovery?.cancel()
        discovery = nil
        browser.stop()
        for candidate in candidates {
            candidate.deadline?.cancel()
            candidate.transport.onEvent = nil
            candidate.transport.close()
        }
        candidates = []
        active = nil
        pairingCandidate = nil
    }

    private func close(_ candidate: Candidate) {
        candidate.deadline?.cancel()
        candidate.transport.onEvent = nil
        candidate.transport.close()
        candidates.removeAll { $0 === candidate }
        if pairingCandidate === candidate {
            pairingCandidate = nil
        }
    }

    private func handle(_ event: TransportEvent, from candidate: Candidate) {
        switch event {
        case .opened:
            openedThisAttempt = true
        case let .message(text):
            guard let message = try? NacelleCodec.decodeServer(text) else { return }
            if candidate === active {
                handleActive(message)
            } else {
                handleHandshake(message, from: candidate)
            }
        case .closed:
            candidate.deadline?.cancel()
            candidates.removeAll { $0 === candidate }
            if pairingCandidate === candidate {
                pairingCandidate = nil
            }
            if candidate === active {
                active = nil
                if forgetTimer != nil {
                    // Le Mac a coupé après `forgetMe` : on oublie sans attendre le délai.
                    forgetLocally()
                } else {
                    lost()
                }
            } else {
                failAttemptIfOver()
            }
        }
    }

    /// La tentative échoue quand plus aucune connexion n'est en vie et que Bonjour a fini de chercher.
    private func failAttemptIfOver() {
        if active == nil, candidates.isEmpty, discovery == nil, link == .connecting {
            attemptFailed()
        }
    }

    private func handleHandshake(_ message: ServerMessage, from candidate: Candidate) {
        switch message {
        case let .challenge(nonce):
            answer(nonce, on: candidate)
        case let .paired(_, lanKey):
            // Seule la connexion qui a envoyé la preuve peut confirmer l'appairage.
            guard candidate === pairingCandidate else { return }
            let qrHost = pendingPairing?.hosts.first
            let qrPort = pendingPairing?.port
            // Sans le secret, le réseau local en TLS est impossible ; seule l'écoute Tailscale reste : l'appairage est valable quand même.
            do {
                try keys.saveLANKey(lanKey)
            } catch {
                Self.logger.error("Secret du réseau local non enregistré : \(String(describing: error), privacy: .public)")
            }
            pendingPairing = nil
            pairingCandidate = nil
            setPaired(true)
            // L'adresse du Mac qui a répondu, sinon la première du QR (service Bonjour en IPv6 ou non résolu, spec découverte et QR § 8.1).
            if let address = candidate.transport.remoteAddress ?? qrHost, let port = qrPort {
                onAddressLearned?(address, port)
            }
            for waiting in candidates where waiting.nonce != nil {
                authenticate(waiting)
            }
        case .authenticated:
            // Un `authenticated` sans `auth` envoyé n'est pas une réponse : connexion fermée.
            guard candidate.authSent else {
                close(candidate)
                failAttemptIfOver()
                return
            }
            becomeActive(candidate)
        case let .error(code, _):
            handleHandshakeError(code, from: candidate)
        default:
            break
        }
    }

    /// Un refus de la preuve arrête l'appairage. Hors appairage, le verdict d'un service du réseau local
    /// ne ferme que sa connexion et ne touche pas à l'appairage ; seule la connexion Tailscale peut tout arrêter.
    private func handleHandshakeError(_ code: ErrorCode, from candidate: Candidate) {
        let issue: AuthIssue
        switch code {
        case .unpaired:
            issue = .unpaired
        case .authFailed:
            issue = .rejected
        case .badCode, .pairingClosed, .notLocal:
            issue = .badCode
        case .blocked:
            issue = .blocked
        default:
            lastError = code
            return
        }
        if candidate === pairingCandidate {
            pairingRefused()
            return
        }
        if issue == .blocked {
            giveUp(.blocked)
            return
        }
        if candidate.isLocal {
            localIssue = issue
            close(candidate)
            failAttemptIfOver()
            return
        }
        if issue == .unpaired {
            setPaired(false)
        }
        giveUp(issue)
    }

    private func answer(_ nonce: Data, on candidate: Candidate) {
        candidate.nonce = nonce
        if let pairing = pendingPairing {
            // Un seul appairage à la fois : les autres connexions attendent `paired`.
            guard pairingCandidate == nil else { return }
            guard let key = try? keys.loadOrCreate() else {
                pendingPairing = nil
                giveUp(.unpaired)
                return
            }
            pairingCandidate = candidate
            let proof = NacelleAuth.pairingProof(secret: pairing.secret, nonce: nonce, publicKeyX963: key.publicKeyX963)
            send(.pair(pairingID: pairing.pairingID, publicKey: key.publicKeyX963, name: deviceName, proof: proof), on: candidate)
        } else if keys.load() != nil {
            authenticate(candidate)
        } else {
            setPaired(false)
            giveUp(.unpaired)
        }
    }

    private func authenticate(_ candidate: Candidate) {
        guard let nonce = candidate.nonce, let key = keys.load(), let signature = try? key.signChallenge(nonce) else { return }
        candidate.nonce = nil
        candidate.authSent = true
        send(.auth(deviceID: key.deviceID, signature: signature), on: candidate)
    }

    private func becomeActive(_ candidate: Candidate) {
        guard active == nil else {
            close(candidate)
            return
        }
        candidate.deadline?.cancel()
        candidate.deadline = nil
        active = candidate
        for other in candidates where other !== candidate {
            close(other)
        }
        discovery?.cancel()
        discovery = nil
        browser.stop()
        link = .connected
        attempt = 0
        isUnreachable = false
        authIssue = nil
        authIssueBlocks = false
        setPaired(true)
        send(.takeControl)
        let waiting = waitingForLink
        waitingForLink = [:]
        waiting.values.forEach { $0.resume() }
    }

    private func handleActive(_ message: ServerMessage) {
        switch message {
        case let .state(snapshot):
            state = snapshot
        case .error(.blocked, _):
            // Expulsé pendant la session : pas de reconnexion, qui serait refusée.
            giveUp(.blocked)
        case .error(.unpaired, _):
            // Session ouverte : le Mac a retiré cet iPhone de sa liste. Si l'oubli vient de cet iPhone
            // (forgetMe en attente), il s'achève ici, quel que soit le chemin.
            // Sinon, oubli complet seulement en TLS local, où le Mac est authentifié ; en WebSocket simple
            // (Tailscale), n'importe quel serveur pourrait envoyer ce message : on garde les clés.
            if forgetTimer != nil || active?.isLocal == true {
                forgetLocally(giveUp: true)
            } else {
                setPaired(false)
                giveUp(.unpaired)
            }
        case .error(.badMessage, _) where forgetTimer != nil:
            // Un ptzd plus ancien ne connaît pas forgetMe : inutile d'attendre sa fermeture.
            forgetLocally()
        case let .error(code, _):
            lastError = code
        case let .webrtcAnswer(id, sdp):
            negotiations.removeValue(forKey: id)?.resume(returning: sdp)
        case let .webrtcError(id, message):
            negotiations.removeValue(forKey: id)?.resume(throwing: NegotiationError.relay(message))
        case .challenge, .authenticated, .paired, .pairingOpened, .adminState:
            break
        }
    }

    /// QR code refusé. Sur un iPhone déjà appairé (scan depuis les réglages), simple avis et reconnexion
    /// normale ; sinon, arrêt sur « QR code refusé » (spec app Mac § 9).
    private func pairingRefused() {
        pendingPairing = nil
        guard isPaired, keys.load() != nil else {
            giveUp(.badCode)
            return
        }
        onPairingRefused?()
        restart()
    }

    /// Plus de reconnexion : l'utilisateur doit appairer l'iPhone (spec accès local § 8.5).
    private func giveUp(_ issue: AuthIssue) {
        authIssue = issue
        authIssueBlocks = true
        stopRepeating()
        currentMove = .zero
        state = nil
        retry?.cancel()
        retry = nil
        closeAll()
        link = .idle
        failNegotiations(.notConnected)
    }

    private func lost() {
        stopRepeating()
        currentMove = .zero
        state = nil
        let pending = negotiations
        negotiations = [:]
        pending.values.forEach { $0.resume(throwing: NegotiationError.connectionLost) }
        scheduleRetry()
    }

    private func attemptFailed() {
        // Appairage sans réponse : le QR est refusé (mauvais secret, expiré) ou aucun Mac n'est joignable.
        if pendingPairing != nil {
            pairingRefused()
            return
        }
        closeAll()
        if !openedThisAttempt {
            isUnreachable = true
        }
        if let localIssue {
            authIssue = localIssue
        }
        state = nil
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard settings != nil else {
            link = .idle
            return
        }
        closeAll()
        link = .waitingToRetry
        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
        attempt += 1
        retry = scheduler.schedule(after: delay) { [weak self] in
            self?.retry = nil
            self?.connect()
        }
    }

    private func setPaired(_ paired: Bool) {
        guard isPaired != paired else { return }
        isPaired = paired
        pairingRecord.isPaired = paired
    }

    // MARK: - Envoi

    private func send(_ message: ClientMessage) {
        guard link == .connected, let active else { return }
        send(message, on: active)
    }

    private func send(_ message: ClientMessage, on candidate: Candidate) {
        guard let text = try? NacelleCodec.encode(message) else { return }
        candidate.transport.send(text)
    }

    /// Envoie une trame voix de `VoiceFrame.byteCount` octets sur la connexion authentifiée. Faux, sans rien
    /// envoyer, hors connexion ou à une autre taille. `completion` signale la fin de l'envoi.
    func sendVoice(_ frame: Data, completion: @escaping @MainActor () -> Void) -> Bool {
        guard link == .connected, let active, VoiceFrame.isValid(frame) else { return false }
        active.transport.sendVoice(frame, completion: completion)
        return true
    }

    private func scheduleRepeat() {
        repeater = scheduler.schedule(after: Self.repeatInterval) { [weak self] in
            self?.repeatTick()
        }
    }

    private func repeatTick() {
        repeater = nil
        guard currentMove != .zero else { return }
        send(.move(pan: currentMove.pan, tilt: currentMove.tilt))
        scheduleRepeat()
    }

    private func stopRepeating() {
        repeater?.cancel()
        repeater = nil
    }
}

/// Mémoire de l'appairage, pour l'afficher dans les réglages.
final class PairingRecord {
    static let key = "paired"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isPaired: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
