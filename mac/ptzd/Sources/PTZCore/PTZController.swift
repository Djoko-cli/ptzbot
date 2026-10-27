import Foundation
import NacelleProtocol

/// Point d'entrée de la logique : traite les messages de l'app, suit la
/// présence de la caméra et publie l'état (spec § 5 et § 6).
@MainActor
public final class PTZController {
    /// Délai avant de relire la position après un déplacement absolu (spec § 6.5).
    public static let settleDelay = PrivacyReconciler.settleDelay
    /// Écart toléré entre l'ordre absolu et la position relue.
    public static let positionTolerance = PrivacyReconciler.positionTolerance
    /// Renvois au plus d'un ordre absolu ignoré par la caméra, hors vie privée.
    public static let maxResends = PrivacyReconciler.maxResends
    /// Protection par l'inclinaison : délais avant chaque nouvelle vérification après un renvoi.
    public static let privacyBackoff = PrivacyReconciler.privacyBackoff
    /// Utilitaire gardé chaud : vérifié à cet intervalle, il est relancé s'il est mort seul (incident, SIGKILL). Sans effet
    /// pendant la minute que le lanceur laisse après un utilitaire mort sans avoir servi.
    public static let warmCheckInterval: TimeInterval = 60

    public private(set) var snapshot: StateSnapshot
    /// Appelé à chaque changement d'état, pour diffusion à tous les clients.
    public var onStateChange: ((StateSnapshot) -> Void)?
    /// Erreur à transmettre plus tard à ce client (ordre de suivi IA échoué, vie privée native).
    public var onClientError: ((ClientID, ErrorCode, String) -> Void)?

    private let camera: any CameraDevice
    private let scheduler: any Scheduler
    /// L'utilitaire obsbot-ai (par la file des ordres), à tenir chaud quand ptzd dispose du SDK.
    private let ai: any AIRunner
    /// La file des ordres de l'utilitaire (c'est `ai`) : ses ordres d'exposition en attente sont jetés quand l'exposition
    /// abandonne sa session.
    private let queue: AIOrderQueue
    private let motion: MotionDriver
    private let zoom: ZoomDriver
    /// La vie privée : état voulu, état constaté et réconciliateur (spec § 6.5 bis).
    private let privacy: PrivacyReconciler
    private let control: ControlTaker
    /// L'exposition automatique (spec § 6.11).
    private let exposure: ExposureReconciler
    /// Le suivi IA retenu et relu (spec § 6.4 bis).
    private let tracking: TrackingReconciler
    private let log: LogSink
    private var lastControl: ControlState = .idle
    /// Retour audio de talkd, lu par `TalkbackWatcher` (spec parler § 5).
    private var talkback: TalkbackAvailability = .unavailable
    private var warmCheck: (any Cancellable)?

    public init(
        camera: any CameraDevice,
        scheduler: any Scheduler,
        ai: any AIRunner,
        store: any StateStore,
        settings: MotionSettings,
        isObsbotCenterRunning: @escaping @MainActor () -> Bool,
        log: @escaping LogSink
    ) {
        self.camera = camera
        self.scheduler = scheduler
        self.log = log
        // L'utilitaire ne traite qu'un ordre à la fois : la coupure du suivi IA et la vie privée native passent par la
        // même file, l'une après l'autre (spec § 6.5 bis).
        let queue = AIOrderQueue(runner: ai)
        self.queue = queue
        self.ai = queue
        let motion = MotionDriver(camera: camera, scheduler: scheduler, settings: settings, log: log)
        let zoom = ZoomDriver(camera: camera, scheduler: scheduler, log: log)
        let control = ControlTaker(runner: queue, scheduler: scheduler, isObsbotCenterRunning: isObsbotCenterRunning, log: log)
        self.motion = motion
        self.zoom = zoom
        self.control = control
        privacy = PrivacyReconciler(
            camera: camera,
            scheduler: scheduler,
            runner: queue,
            store: store,
            motion: motion,
            zoom: zoom,
            control: control,
            log: log
        )
        let exposure = ExposureReconciler(runner: queue, store: store, log: log)
        self.exposure = exposure
        let tracking = TrackingReconciler(control: control, queue: queue, scheduler: scheduler, store: store, log: log)
        self.tracking = tracking
        snapshot = StateSnapshot(
            camera: camera.isPresent ? .connected : .absent,
            control: .idle,
            privacy: privacy.isActive,
            pan: nil, tilt: nil, zoom: nil,
            moving: false,
            privacyMode: privacy.mode,
            privacyReason: privacy.reason,
            autoExposure: exposure.published
        )
        motion.onChange = { [weak self] in self?.publish() }
        zoom.onChange = { [weak self] in self?.publish() }
        privacy.onChange = { [weak self] in self?.publish() }
        privacy.onClientError = { [weak self] in self?.onClientError?($0, $1, $2) }
        privacy.onEnded = { [weak self] in self?.privacyEnded() }
        // Aucun ordre d'exposition tant que la vie privée est voulue ou en cours (spec § 6.11) : la caméra peut dormir en
        // mode natif.
        exposure.canOrder = { [weak self] in !(self?.privacy.isActive ?? false) }
        exposure.discardQueuedOrders = { [weak queue] in queue?.dropQueuedExposure() }
        exposure.onChange = { [weak self] in self?.publish() }
        exposure.onClientError = { [weak self] in self?.onClientError?($0, $1, $2) }
        control.onChange = { [weak self] in self?.controlChanged() }
        // Le suivi n'est jamais allumé pendant la vie privée, ni sur une caméra qui peut être en mode natif (spec § 6.4 bis).
        tracking.canOrder = { [weak self] in
            guard let self else { return false }
            return camera.isPresent && privacy.allowsTracking
        }
        // Il reprend une fois la position d'avant la vie privée rétablie, jamais pendant sa vérification.
        privacy.onPositionRestored = { [weak self] in self?.positionRestored() }
    }

    /// Le retour audio devient prêt ou indisponible : l'état est rediffusé si la valeur change.
    public func setTalkback(_ value: TalkbackAvailability) {
        guard value != talkback else { return }
        talkback = value
        publish()
    }

    /// Un iPhone vient de s'authentifier : prépare l'utilitaire du suivi IA avant son premier ordre.
    public func prewarmAI() {
        // Caméra absente : rien à piloter. Vie privée : aucun ordre de suivi n'est possible, inutile de charger le SDK,
        // sauf si l'utilitaire est gardé chaud (il relit alors l'état réel de la caméra).
        guard camera.isPresent, ai.keepsWarm || !privacy.isActive else { return }
        control.prewarm()
    }

    /// Utilitaire toujours chaud (ptzd lancé avec le SDK, spec § 6.9) : préparé dès que la caméra est là (démarrage de
    /// ptzd, branchement, mise à jour d'obsbot-ai, connexion d'un client), puis vérifié toutes les `warmCheckInterval`
    /// secondes. Ainsi toute entrée en vie privée prend le chemin rapide. Sans effet quand l'utilitaire n'est pas gardé
    /// chaud ou n'est pas installé ; sans caméra, rien n'est lancé (il ne trouverait rien).
    private func keepAIWarm() {
        guard ai.keepsWarm, ai.supportsNativePrivacy else { return }
        if camera.isPresent {
            ai.prewarm()
        }
        if warmCheck == nil {
            warmCheck = scheduler.schedule(after: Self.warmCheckInterval) { [weak self] in
                self?.warmCheck = nil
                self?.keepAIWarm()
            }
        }
    }

    /// Un client (iPhone ou Mac) vient de s'authentifier : en vie privée native, l'état réel de la caméra est relu
    /// tout de suite, pour que ce qu'il affiche ne date pas de la dernière relecture lente (spec § 6.5 bis).
    public func clientConnected() {
        keepAIWarm()
        privacy.refreshRealState()
    }

    /// Le Mac sort de veille : la caméra a pu être réveillée pendant ce temps ; même relecture qu'à une connexion. Un
    /// branchement vu juste après est traité comme un démarrage, non comme une coupure d'alimentation (réserve 1).
    public func systemWoke() {
        log("Le Mac sort de veille.")
        // Une relance ou une lecture du suivi en cours visait la session d'avant la veille.
        tracking.abandonSession()
        // Utilitaire gardé chaud, vie privée éteinte : sa session du SDK a pu devenir périmée pendant la veille (le bus
        // USB n'est pas renuméroté, aucun branchement n'est vu). Elle repart neuve : une entrée dans les secondes qui
        // suivent prend le repli (−70° tout de suite), jamais un ordre sur une session invalide. En vie privée, la
        // relecture du réveil (`privacy.systemWoke`) couvre déjà ce cas : deux lectures ratées ouvrent une session neuve.
        if ai.keepsWarm, !privacy.isActive {
            control.reset()
            lastControl = control.state
            keepAIWarm()
        }
        privacy.systemWoke()
        // Le bus USB a pu dormir : l'état réel est lu d'abord (sur une caméra qui suit encore, un « on » superflu est
        // évité), le suivi voulu relancé s'il est lu coupé (sans effet pendant la vie privée ni sa vérification).
        tracking.reapply(reason: "sortie de veille du Mac", readFirst: true)
    }

    /// ptzd démarre sans voir la caméra : son prochain branchement est une mise sous tension, pas un redémarrage de ptzd
    /// (la caméra ne peut pas être restée en mode natif).
    public func cameraAbsentAtStartup() {
        privacy.cameraAbsentAtStartup()
    }

    /// PTZBot a recompilé ou réinstallé obsbot-ai (message `aiUpdated`) : l'utilitaire repart du nouveau programme, et
    /// la vie privée est réconciliée avec lui (spec § 6.5 bis).
    public func aiUpdated() {
        log("obsbot-ai mis à jour par PTZBot : utilitaire relancé.")
        privacy.abandonSession()
        exposure.abandonSession()
        tracking.abandonSession()
        control.reset()
        lastControl = control.state
        keepAIWarm()
        privacy.utilityUpdated()
        // Toujours : l'indicateur « en cours de mise à jour » doit retomber même caméra absente.
        exposure.utilityUpdated(cameraPresent: camera.isPresent)
        tracking.utilityUpdated(cameraPresent: camera.isPresent)
        publish()
    }

    /// Traite un message. Renvoie l'erreur à transmettre à ce client, ou nil.
    public func handle(_ message: ClientMessage, from client: ClientID) -> (code: ErrorCode, message: String)? {
        prewarmAI()
        switch message {
        case .takeControl:
            // N'allume ni ne coupe le suivi IA : c'est le premier mouvement qui le coupe (spec app Mac § 7.5).
            return nil
        case let .move(pan, tilt):
            if privacy.isActive, pan == 0, tilt == 0 {
                return nil
            }
            if let refusal = refusal() {
                return refusal
            }
            // Le suivi IA contrerait le joystick : coupé au premier mouvement, s'il n'est pas déjà coupé ; le choix retenu
            // devient « coupé » (spec § 6.4 bis).
            // Un simple arrêt (0, 0) n'est pas un mouvement : il ne coupe pas le suivi et n'interrompt pas la vérification de
            // la position rétablie, dont la fin fait reprendre le suivi.
            if pan != 0 || tilt != 0 {
                if control.mayBeTracking {
                    control.take()
                }
                tracking.userMoved()
                privacy.userMoved()
            }
            return attempt { try motion.move(pan: pan, tilt: tilt, from: client) }
        case let .zoom(value):
            if let refusal = refusal() {
                return refusal
            }
            return attempt { try zoom.set(value) }
        case let .privacy(on):
            guard camera.isPresent else {
                return (.cameraAbsent, "Caméra débranchée.")
            }
            if on {
                // La vie privée passe avant l'exposition : ses ordres en file sont jetés, un ordre déjà parti va à son
                // terme (l'entrée prend alors le repli, −70° d'abord), et rien d'autre ne part à la caméra.
                exposure.abandonSession()
            }
            return privacy.request(on: on, from: client)
        case let .autoExposure(on):
            // Utilisable pendant la vie privée : le choix est retenu et publié, l'ordre part à la sortie (spec § 6.11).
            guard camera.isPresent else {
                return (.cameraAbsent, "Caméra débranchée.")
            }
            return exposure.request(on: on, from: client)
        case let .aiTracking(on):
            if let refusal = refusal() {
                return refusal
            }
            control.setTracking(on: on) { [weak self] result in
                guard result != .success else {
                    // L'interrupteur des apps : le choix retenu (spec § 6.4 bis).
                    self?.tracking.userChose(on: on)
                    return
                }
                self?.onClientError?(client, .uvcFailed, AIFailureText.message(motive: result.userDescription))
            }
            return nil
        case .pair, .openPairing, .auth, .webrtcOffer, .adminWatch, .revoke, .kick, .unblock, .closePairing, .forgetMe,
             .aiUpdated:
            // Messages de session et d'administration : le serveur les traite et ne les transmet jamais.
            return (.badMessage, "Message de session inattendu.")
        }
    }

    public func clientDisconnected(_ client: ClientID) {
        motion.clientDisconnected(client)
    }

    /// Branchement ou débranchement de la caméra. Au branchement, la vie privée est réappliquée (d'après l'état réel si
    /// la caméra peut être en mode natif) et le suivi IA recoupé, au cas où la caméra aurait redémarré ; hors vie privée,
    /// le suivi IA voulu est relancé, puis relu (spec § 6.4 bis).
    public func cameraPresenceChanged(_ present: Bool) {
        // Un ordre de vie privée native en cours ne vaut plus : sa réponse est écartée, l'état réel sera relu.
        privacy.abandonSession()
        exposure.abandonSession()
        tracking.abandonSession()
        // Le SDK gardé par l'utilitaire du suivi IA ne connaît plus la caméra : session neuve au prochain ordre.
        control.reset()
        lastControl = control.state
        if present {
            keepAIWarm()
            log("Caméra branchée.")
            if !privacy.isActive {
                motion.refreshPosition()
                zoom.refresh()
                // La caméra a pu redémarrer avec son propre réglage : le dernier ordre ne vaut plus, jusqu'à la relecture.
                control.forget()
            }
        } else {
            log("Caméra débranchée.")
            motion.reset()
            zoom.reset()
        }
        privacy.cameraPresenceChanged(present)
        if present {
            // La caméra a pu oublier le mode automatique en redémarrant : l'exposition voulue est réappliquée.
            exposure.reapply(reason: "caméra branchée")
            // De même pour le suivi IA voulu ; la relecture qui suit remplace « inconnu » par l'état réel.
            tracking.reapply(reason: "caméra branchée")
        }
        publish()
    }

    /// La vie privée est finie, la caméra lue éveillée (ou jamais endormie) : l'exposition voulue est réappliquée.
    private func privacyEnded() {
        guard camera.isPresent else { return }
        exposure.privacyEnded()
    }

    /// La vie privée est finie et la position d'avant rétablie : le suivi IA voulu reprend (spec § 6.4 bis).
    private func positionRestored() {
        guard camera.isPresent else { return }
        tracking.reapply(reason: "sortie de la vie privée")
    }

    /// Fin d'une coupure du suivi IA : sur une caméra qui démarre, obsbot-ai off a pu tourner en même temps que la
    /// première réapplication de la vie privée.
    private func controlChanged() {
        let previous = lastControl
        lastControl = control.state
        if previous == .taking, control.state != .taking, camera.isPresent {
            privacy.controlFinished()
            tracking.controlFinished()
        }
        publish()
    }

    private func refusal() -> (code: ErrorCode, message: String)? {
        if !camera.isPresent {
            return (.cameraAbsent, "Caméra débranchée.")
        }
        if privacy.isActive {
            return (.privacyActive, "Vie privée active : commande refusée.")
        }
        return nil
    }

    private func attempt(_ body: () throws -> Void) -> (code: ErrorCode, message: String)? {
        do {
            try body()
            return nil
        } catch CameraError.absent {
            return (.cameraAbsent, "Caméra débranchée.")
        } catch {
            log("Commande UVC refusée : \(error)")
            return (.uvcFailed, "La caméra a refusé la commande (\(error)).")
        }
    }

    private func publish() {
        let next = StateSnapshot(
            camera: camera.isPresent ? .connected : .absent,
            control: control.state,
            privacy: privacy.isActive,
            pan: motion.position?.pan,
            tilt: motion.position?.tilt,
            zoom: zoom.value,
            moving: motion.isMoving,
            aiTracking: control.tracking,
            talkback: talkback,
            privacyMode: privacy.mode,
            privacyReason: privacy.reason,
            autoExposure: exposure.published
        )
        guard next != snapshot else { return }
        snapshot = next
        onStateChange?(next)
    }
}
