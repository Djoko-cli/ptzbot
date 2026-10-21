import Foundation
import NacelleProtocol

/// La vie privée (spec § 6.5 et § 6.5 bis) : un état voulu, un état constaté, et un réconciliateur qui mène l'un vers
/// l'autre, une étape à la fois.
///
/// - **Deux couches.** La protection immédiate est l'inclinaison à −70° (commande UVC directe) ; avec le SDK, le mode
///   natif de la caméra (image noire, micro coupé) vient par-dessus, par obsbot-ai.
/// - **Un seul pilote de la position.** Tant que la caméra peut être en mode natif (constaté, ou ordre natif parti sans
///   lecture depuis), y entre ou en sort, aucun ordre de position UVC ne part : elle gère seule sa position. Seule
///   exception : le rebranchement, d'où la caméra revient éveillée et droite (mesuré le 19/10).
/// - **Rien n'est supposé.** Après chaque ordre natif, l'état réel est relu (`privacy status`) pendant la bascule de la
///   caméra ; il l'est aussi lentement pendant le mode natif, et quand une réponse manque ou échoue. `native` n'est
///   publié qu'après une lecture `privacy`, et n'est plus affirmé après deux relectures ratées de suite (session du SDK
///   renouvelée, lecture, puis `privacy on`). L'inclinaison lue par le SDK est le second témoin d'un état illisible.
/// - **Le dernier choix gagne.** Une étape en cours (un ordre à l'utilitaire, la bascule qui le suit, une attente de
///   position) va à son terme ; la séquence repart alors vers le nouvel état voulu. Un délai d'attente, une relecture
///   lente ou une vérification s'arrêtent tout de suite. Aucun ordre n'est croisé : l'utilitaire n'en traite qu'un à la
///   fois, et le réconciliateur n'en donne jamais un second avant la réponse du premier.
///
/// Entrée rapide (banc du 19/10, « Accélération ») : SDK prêt et caméra éveillée, `privacy on` directement depuis la
/// position courante, puis relectures serrées jusqu'à la bascule ; deux essais. Repli : inclinaison à −70°, attente que
/// la caméra y soit, puis `privacy on` (utilitaire pas prêt, état illisible, branchement) ; ou la protection à −70°
/// seule, vérifiée sans fin (deux échecs du mode natif, pas de SDK, utilitaire à recompiler). Sortie : `privacy off`
/// (avec le SDK, quel que soit le mode), relectures serrées jusqu'à `run` (la caméra a alors repris d'elle-même sa
/// position d'entrée), puis position et zoom relus : à `saved`, rien d'autre ; sinon zoom et position mémorisée
/// renvoyés, vérifiés. Un ancien obsbot-ai (« ordre inconnu ») laisse la protection à −70° jusqu'à sa recompilation.
/// Chaque étape a sa ligne de journal, avec sa durée (spec § 6.5 bis, « journal »).
@MainActor
public final class PrivacyReconciler {
    // MARK: - Réglages (spec § 6.5 bis, mesures sur la vraie caméra du 19/10)

    /// Objectif vers le bas. −70° est obéi exactement ; la caméra ignore −90° (mesuré le 2026-10-05).
    public static let privacyTilt: Double = -70
    /// Délai avant de relire la position après un déplacement absolu : relue plus tôt, la caméra renvoie une valeur
    /// fausse (spec § 6.5).
    public static let settleDelay: TimeInterval = 2
    /// Écart toléré entre l'ordre absolu et la position relue (la relecture peut différer d'1°).
    public static let positionTolerance: Double = 3
    /// Hors vie privée, renvois au plus d'un ordre absolu ignoré par la caméra.
    public static let maxResends = 2
    /// Protection par l'inclinaison : la vérification ne s'arrête jamais ; délais avant chaque nouvelle vérification
    /// après un renvoi, le dernier se répétant indéfiniment.
    public static let privacyBackoff: [TimeInterval] = [2, 5, 10, 30]
    /// Relectures serrées pendant une bascule et pendant l'attente de l'inclinaison (spec § 6.5 bis, « Accélération ») :
    /// l'état se lit en 1 à 5 ms, la position en 50 à 100 ms (mesuré). Attente de l'inclinaison : une relecture à
    /// `settleDelay`, puis toutes les `pollInterval`, jusqu'à deux relectures de suite à moins de `stableTolerance` l'une
    /// de l'autre, près de −70°.
    public static let pollInterval: TimeInterval = 0.15
    public static let stableTolerance: Double = 1
    /// Délai maximal de l'attente de l'inclinaison avant le mode natif : passé ce délai, le mode natif part quand même
    /// (l'objectif n'étant pas vu à −70°, la protection reste « en cours »).
    public static let tiltWaitLimit: TimeInterval = 8
    /// Un ordre natif rend la main tout de suite, puis la caméra bascule : état 3 en 0,24 s à l'entrée, état 1 vers
    /// 1,5 à 1,7 s après le réveil (mesuré). Première lecture de l'état après `switchDelay`, puis toutes les
    /// `pollInterval` jusqu'à `switchLimit` après la réponse ; passé ce délai, l'essai n'a pas pris. Une lecture faite
    /// avant la bascule rend l'état d'avant : elle est simplement refaite.
    public static let switchDelay: TimeInterval = pollInterval
    public static let switchLimit: TimeInterval = 4
    /// Réveil confirmé par le seul témoin (état illisible) : la nacelle remonte en 1,1 s au plus, mais l'état ne passe à 1
    /// que vers 1,5 à 1,7 s ; aucun ordre de position avant `witnessWakeDelay` après la réponse.
    public static let witnessWakeDelay: TimeInterval = 2.5
    /// Une caméra qui pouvait être en mode natif est lue éveillée : sa remontée est finie quand l'état `run` se lit
    /// (remontée en 1,1 s au plus, état 1 vers 1,5 à 1,7 s, mesuré). Marge avant le premier ordre de position.
    public static let riseMargin: TimeInterval = 0.5
    /// Sortie rapide : réveillée, la caméra reprend d'elle-même sa position d'entrée (mesuré le 19/10). Relue à moins de
    /// `returnTolerance` de `saved` sur chaque axe, zoom égal, rien n'est renvoyé.
    public static let returnTolerance: Double = 2
    /// Délai avant un nouvel essai de sortie, ou une nouvelle lecture d'un état illisible.
    public static let retryDelay: TimeInterval = 1
    /// Essais au plus d'une entrée ou d'une sortie native.
    public static let maxAttempts = 2
    /// État réel toujours illisible, essais épuisés : relectures de plus en plus espacées, la dernière se répétant.
    public static let readBackoff: [TimeInterval] = [3, 5, 10, 30]
    /// Relecture lente de l'état réel pendant le mode natif : un réveil par un autre moyen (bouton, télécommande, app
    /// OBSBOT) est vu au plus tard après ce délai. Une lecture ne réveille pas la caméra (mesuré, deux par seconde
    /// pendant 15 s).
    public static let rereadInterval: TimeInterval = 30
    /// Un branchement vu dans ce délai après la sortie de veille du Mac n'est pas tenu pour une coupure d'alimentation :
    /// la caméra dormait peut-être encore en mode natif, et le Mac a pu renuméroter le bus USB sans la couper
    /// (réserve 1 de la troisième relecture). Il est traité comme un démarrage de ptzd : l'état réel d'abord.
    public static let wakeWindow: TimeInterval = 30
    /// Second témoin, l'inclinaison lue par le SDK (positive vers le bas) : environ 85 en vie privée native, 70 à −70°
    /// UVC (mesuré). À partir de `nativePitch`, la nacelle est dans la pose du mode natif ; jusqu'à `awakePitch`, elle
    /// n'y est pas.
    public static let nativePitch: Double = 80
    public static let awakePitch: Double = 75

    // MARK: - État publié

    /// La vie privée est en vigueur (state.json `privacy`) : de l'entrée demandée jusqu'à la fin de la sortie. Pendant ce
    /// temps, `move`, `zoom` et le suivi IA sont refusés.
    public private(set) var isActive: Bool
    /// `native` seulement quand la dernière lecture de l'état réel a rendu `privacy` ; `tilt` sinon (spec § 6.5 bis).
    public var mode: PrivacyMode? {
        guard isActive else { return nil }
        return real == .privacy ? .native : .tilt
    }
    /// En mode `tilt`, pourquoi le mode natif ne tient pas, ou `pending` tant que l'objectif n'a pas été vu à −70° ; nil
    /// pendant que le mode natif est en cours, l'objectif déjà vu à −70°, et pendant une sortie.
    public var reason: PrivacyReason? {
        guard mode == .tilt else { return nil }
        if wanted, tilt != .placed {
            // L'affichage ne ment jamais : ni « objectif détourné » avant de l'avoir vu, ni « image et micro coupés »
            // avant de l'avoir lu (rebranchement, démarrage, réveil par un autre moyen, inclinaison refusée).
            return .pending
        }
        if !runner.supportsNativePrivacy {
            return .noSDK
        }
        if updating {
            return .updating
        }
        return wanted && (gaveUp || readFailures >= Self.maxAttempts) ? .failed : nil
    }
    /// Appelé quand l'état publié a pu changer.
    public var onChange: (() -> Void)?
    /// Un échec à montrer au client qui a demandé la vie privée (repli sur l'inclinaison, sortie impossible).
    public var onClientError: ((ClientID, ErrorCode, String) -> Void)?
    /// La vie privée vient de finir (fin de la sortie, caméra lue éveillée ou jamais endormie) : l'exposition voulue peut
    /// être réappliquée (spec § 6.11).
    public var onEnded: (() -> Void)?

    // MARK: - État interne

    /// L'inclinaison de la protection en cours : pas envoyée (ou refusée), envoyée (pas encore vue à −70°), vue à −70°.
    private enum Tilt {
        case none
        case sent
        case placed
    }

    /// L'étape en cours. `order`, `switching` et `settling` vont à leur terme ; `pause` et `verifying` s'arrêtent à un
    /// nouveau choix.
    private enum Step {
        case idle
        /// Un ordre à l'utilitaire, jusqu'à sa réponse.
        case order
        /// La bascule qui suit un ordre natif : délai avant la lecture, ou entre deux lectures. Une lecture faite pendant
        /// la bascule rendrait l'état d'avant.
        case switching
        /// Attente que la position se stabilise près de −70°, avant le mode natif.
        case settling
        /// Délai avant un nouvel essai, relecture différée ou lente, marge après une remontée.
        case pause
        /// Vérification de la position (spec § 6.5) : protection par l'inclinaison, ou position rétablie à la sortie.
        case verifying
    }

    private enum NativeOrder {
        case on
        case off
        case status
    }

    /// Les lectures qui suivent un ordre natif, jusqu'à la bascule ou jusqu'au délai.
    private struct Switch {
        /// `privacy on` ou `privacy off`.
        let order: NativeOrder
        /// La réponse de l'ordre.
        let start: TimeInterval
        let deadline: TimeInterval
        /// L'inclinaison lue par la lecture d'avant, pour juger la nacelle immobile (m4).
        var lastPitch: Double?
        /// Lectures faites pendant cette bascule (journal).
        var reads = 0
    }

    /// Pourquoi une sortie échoue, pour un message exact.
    private enum ExitFailure {
        case stayedPrivate
        case unreadable
        case needsUpdate

        var text: String {
            switch self {
            case .stayedPrivate: PrivacyFailureText.exitFailed
            case .unreadable: PrivacyFailureText.exitUnreadable
            case .needsUpdate: PrivacyFailureText.exitNeedsUpdate
            }
        }
    }

    private struct Settle {
        let deadline: TimeInterval
        var previous: PanTiltPosition?
    }

    private let camera: any CameraDevice
    private let scheduler: any Scheduler
    private let runner: any AIRunner
    private let store: any StateStore
    private let motion: MotionDriver
    private let zoom: ZoomDriver
    private let control: ControlTaker
    private let log: LogSink

    /// Le dernier choix de l'utilisateur (ou la vie privée retenue au démarrage).
    private var wanted: Bool
    /// La position d'avant la vie privée, écrite seulement à une entrée demandée par l'utilisateur.
    private var saved: SavedPosition?
    /// La caméra peut être en mode natif (state.json `native`) : tant que c'est vrai, aucun ordre de position.
    private var mayBeNative: Bool
    /// Dernier état réel lu ; nil s'il est inconnu (aucune lecture depuis le dernier ordre natif ou le branchement).
    private var real: CameraRunState?
    /// obsbot-ai a répondu « ordre inconnu » : il attend sa recompilation (raison `updating`).
    private var updating = false
    /// Essais natifs de l'entrée ou de la sortie en cours.
    private var attempts = 0
    /// L'entrée a épuisé ses essais : la protection à −70° seule (raison `failed`).
    private var gaveUp = false
    /// Lectures de l'état réel ratées (ni état, ni témoin) depuis le dernier ordre natif.
    private var readFailures = 0
    private var tilt: Tilt = .none
    /// L'attente de l'inclinaison envoyée en dernier est finie (vue à −70° ou délai passé).
    private var tiltWaited = false
    /// L'inclinaison a été refusée à l'entrée : le mode natif part sans attendre, l'inclinaison sera renvoyée s'il ne
    /// tient pas.
    private var tiltRefused = false
    /// Sortie : réveil constaté (lecture `run`).
    private var awake = false
    /// La caméra vient d'être lue éveillée alors qu'elle pouvait être en mode natif : sa remontée est finie, une marge
    /// encore avant tout ordre de position.
    private var afterWake = false
    /// Les lectures qui suivent un ordre natif.
    private var switching: Switch?
    /// Une relecture de l'état réel est demandée (connexion d'un client, réveil du Mac, entrée répétée, coupure du suivi
    /// pendant le mode natif) : elle part sans attendre la relecture lente.
    private var rereadRequested = false
    /// Au démarrage en mode natif possible, la coupure du suivi IA attend que la caméra soit vue éveillée : une
    /// coupure pendant le mode natif pourrait la réveiller.
    private var pendingTake = false
    /// La caméra a été vue débranchée par ce ptzd : son prochain branchement est un rebranchement (coupure
    /// d'alimentation), pas le démarrage de ptzd.
    private var sawAbsence = false
    /// Le Mac est sorti de veille à cet instant (horloge du planificateur) : un branchement tout proche n'est pas un
    /// rebranchement après une coupure d'alimentation.
    private var lastWake: TimeInterval?
    /// Branchement sans lecture de l'état (rebranchement, vie privée par l'inclinaison retenue) : la caméra revient
    /// peut-être éveillée et droite, l'entrée passe par le repli (−70° tout de suite).
    private var plugged = false
    /// La dernière lecture n'a pas rendu l'état (lecture ratée, ou témoin seul) : l'entrée suivante passe par le repli.
    private var stateUnreadable = false
    /// La dernière inclinaison lue par le SDK (positive vers le bas), pour comparer le retour de la caméra à `saved`.
    private var lastPitch: Double?
    /// Journal : début de la séquence en cours (demande, réapplication), et du dernier ordre natif.
    private var sequenceStart: TimeInterval?
    private var orderStart: TimeInterval = 0
    /// Le client à prévenir d'un échec ; nil pour une réapplication (démarrage, branchement).
    private var requester: ClientID?
    /// Dernier ordre absolu envoyé, pour la vérification du § 6.5.
    private var lastTarget: PanTiltPosition?
    private var step: Step = .idle
    private var settle: Settle?
    private var timer: (any Cancellable)?
    /// Change à chaque ordre et à chaque session neuve de l'utilitaire (branchement, recompilation) : la réponse d'un
    /// ordre donné à une session qui n'existe plus est écartée, et l'état réel est relu.
    private var ticket = 0

    public init(
        camera: any CameraDevice,
        scheduler: any Scheduler,
        runner: any AIRunner,
        store: any StateStore,
        motion: MotionDriver,
        zoom: ZoomDriver,
        control: ControlTaker,
        log: @escaping LogSink
    ) {
        self.camera = camera
        self.scheduler = scheduler
        self.runner = runner
        self.store = store
        self.motion = motion
        self.zoom = zoom
        self.control = control
        self.log = log
        let persisted = store.load()
        saved = persisted.saved
        mayBeNative = persisted.native
        wanted = persisted.privacy
        // Une caméra peut-être en mode natif hors vie privée voulue : une sortie interrompue, à finir.
        isActive = persisted.privacy || persisted.native
    }

    // MARK: - Événements

    /// Le message `privacy` d'un client, caméra présente. Rend l'erreur à lui renvoyer tout de suite, ou nil ; un échec
    /// plus tardif passe par `onClientError`.
    public func request(on: Bool, from client: ClientID) -> (code: ErrorCode, message: String)? {
        defer { changed() }
        return on ? requestEntry(from: client) : requestExit(from: client)
    }

    /// Fin d'une coupure du suivi IA (réussie ou non).
    public func controlFinished() {
        guard isActive, wanted, camera.isPresent else { return }
        defer { changed() }
        if real == .privacy {
            // Une coupure du suivi pendant le mode natif a pu réveiller la caméra : l'état est relu tout de suite.
            rereadRequested = true
            reconcile(interrupt: true)
            return
        }
        guard !mayBeNative else { return }
        switch step {
        case .settling:
            // Le suivi a pu détourner l'objectif pendant l'attente : l'inclinaison est renvoyée, l'attente reprend.
            if sendTilt() {
                startSettle()
            }
        case .idle, .verifying:
            // Protection par l'inclinaison : le suivi a pu remonter l'objectif pendant la coupure (spec § 6.5).
            guard tilt != .none, protectsByTiltOnly else { return }
            tilt = .none
            reconcile(interrupt: true)
        case .order, .switching, .pause:
            break
        }
    }

    /// Une session de l'utilitaire va être remplacée (branchement, recompilation) : la réponse d'un ordre en cours ne
    /// vaudra plus rien. À appeler avant `AIRunner.reset()`.
    public func abandonSession() {
        ticket += 1
        stopStep()
    }

    /// Branchement ou débranchement de la caméra (`abandonSession` d'abord). Au branchement, une vie privée en vigueur
    /// est réappliquée et une sortie en cours reprend.
    ///
    /// Un **rebranchement** (après un débranchement vu par ce ptzd) est une coupure d'alimentation : la caméra revient
    /// éveillée et droite (mesuré le 19/10), elle filmerait aussitôt. La protection à −70° part tout de suite, puis le
    /// mode natif, sans attendre une lecture de l'état (4 s de session neuve) : c'est la seule exception à « un seul
    /// pilote ». Au **démarrage** de ptzd, la caméra peut encore être en mode natif (PTZBot relancé) : l'état réel
    /// d'abord. Deux cas sont des mises sous tension, donc des rebranchements : une caméra absente au démarrage de ptzd
    /// (`cameraAbsentAtStartup`). À l'inverse, un branchement vu dans les `wakeWindow` secondes qui suivent la sortie de
    /// veille du Mac n'en est pas un : le Mac a pu renuméroter le bus sans couper l'alimentation, la caméra dormait
    /// peut-être encore en mode natif (traité comme un démarrage).
    public func cameraPresenceChanged(_ present: Bool) {
        defer { changed() }
        var replugged = present && sawAbsence
        if replugged, let woke = lastWake, scheduler.now - woke <= Self.wakeWindow {
            replugged = false
            if mayBeNative, isActive {
                log("Caméra branchée juste après la sortie de veille du Mac : elle a pu garder le mode natif ; l'état réel d'abord.")
            }
        }
        if !present {
            sawAbsence = true
        }
        real = nil
        tilt = .none
        tiltWaited = false
        tiltRefused = false
        awake = false
        afterWake = false
        switching = nil
        rereadRequested = false
        attempts = 0
        readFailures = 0
        gaveUp = false
        // Un utilitaire d'avant la V2 l'est peut-être encore : la prochaine réponse le dira.
        updating = false
        requester = nil
        lastTarget = nil
        pendingTake = false
        plugged = false
        guard present, isActive else { return }
        begin(wanted ? "réapplication au branchement de la caméra" : "la sortie reprend au branchement de la caméra")
        if replugged, mayBeNative {
            log("Caméra rebranchée : elle revient éveillée et droite ; protection à −70° tout de suite, puis le mode natif.")
            setMayBeNative(false)
        }
        // Sans lecture d'abord, la caméra peut filmer (éveillée et droite) : le repli, −70° tout de suite.
        plugged = wanted && !mayBeNative
        if wanted {
            if runner.supportsNativePrivacy && mayBeNative {
                // Peut-être encore en mode natif : la coupure du suivi IA seulement une fois la caméra vue éveillée.
                control.forget()
                pendingTake = true
            } else {
                // Protection immédiate (spec § 6.5), et le suivi IA recoupé : un redémarrage a pu le rallumer.
                control.take()
            }
        }
        reconcile()
    }

    /// PTZBot a recompilé ou réinstallé obsbot-ai (`abandonSession` et `AIRunner.reset()` d'abord) : le mode natif est
    /// retenté avec le nouvel utilitaire.
    public func utilityUpdated() {
        defer { changed() }
        updating = false
        gaveUp = false
        attempts = 0
        readFailures = 0
        switching = nil
        // Une session neuve du SDK : l'état est relu, sans changer ce qui est publié d'ici là.
        if real == .privacy {
            rereadRequested = true
        }
        guard camera.isPresent, isActive else { return }
        if wanted, control.mayBeTracking {
            // La coupure du suivi en cours visait l'ancienne session : elle est refaite (relecture, m1).
            if mayBeNative {
                pendingTake = true
            } else {
                control.take()
            }
        }
        reconcile(interrupt: true)
    }

    /// ptzd démarre sans voir la caméra (rien de branché, ou pas encore). Une caméra alimentée par l'USB et absente ne
    /// peut pas être en mode natif à son prochain branchement : c'est une mise sous tension, traitée comme un
    /// rebranchement et non comme le démarrage de ptzd (m1 de la troisième relecture).
    public func cameraAbsentAtStartup() {
        sawAbsence = true
    }

    /// Le Mac sort de veille : la fenêtre `wakeWindow` s'ouvre, et en mode natif l'état réel est relu tout de suite.
    public func systemWoke() {
        lastWake = scheduler.now
        refreshRealState()
    }

    /// Un client vient de se connecter, ou le Mac sort de veille : en mode natif, l'état réel est relu tout de suite
    /// au lieu d'attendre la relecture lente (constat B de la relecture).
    public func refreshRealState() {
        guard isActive, wanted, camera.isPresent, runner.supportsNativePrivacy, !updating, real == .privacy else { return }
        rereadRequested = true
        reconcile(interrupt: true)
        changed()
    }

    /// Un mouvement de l'utilisateur après la sortie : la vérification de la position rétablie s'arrête.
    public func userMoved() {
        guard !isActive, case .verifying = step else { return }
        stopStep()
        lastTarget = nil
    }

    // MARK: - Demandes

    private func requestEntry(from client: ClientID) -> (code: ErrorCode, message: String)? {
        requester = client
        // Le suivi IA ramènerait l'objectif vers la personne. Pas d'ordre à une caméra qui peut être en mode natif : la
        // coupure attend qu'elle soit lue éveillée (m2 de la troisième relecture).
        if control.mayBeTracking {
            if mayBeNative && runner.supportsNativePrivacy {
                pendingTake = true
            } else {
                control.take()
            }
        }
        guard !wanted else {
            // Déjà voulue : l'état réel est relu (mode natif), ou la vérification de l'inclinaison relancée.
            rereadRequested = true
            reconcile(interrupt: true)
            return nil
        }
        wanted = true
        attempts = 0
        gaveUp = false
        if isActive {
            // Une sortie est en cours : elle s'arrête à la prochaine étape et repart vers la vie privée. `saved` reste la
            // position d'avant la vie privée.
            begin("retour à la vie privée demandé pendant la sortie (client \(client))")
            awake = false
            persist()
            reconcile(interrupt: true)
            return nil
        }
        // Entrée demandée : la seule qui écrit `saved`.
        begin("entrée demandée (client \(client))")
        try? motion.stop()
        zoom.cancelPending()
        saved = motion.position.map { SavedPosition(pan: $0.pan, tilt: $0.tilt, zoom: zoom.value) }
        isActive = true
        tilt = .none
        afterWake = false
        readFailures = 0
        if !runner.supportsNativePrivacy {
            // Sans utilitaire, la caméra ne peut pas être en mode natif par ptzd.
            mayBeNative = false
        }
        persist()
        // Chemin rapide : rien ici, `privacy on` part de la position courante (`advanceEntry`). Repli : la protection
        // immédiate par l'inclinaison part tout de suite (spec § 6.5), le mode natif ensuite.
        if !mayBeNative, let cause = fallbackCause() {
            note("chemin de repli, −70° d'abord (\(cause))")
            do {
                try sendTiltOrThrow()
            } catch {
                guard runner.supportsNativePrivacy else {
                    // Sans SDK, rien d'autre ne protège : l'entrée est annulée et l'erreur remonte (spec § 6.5).
                    isActive = false
                    wanted = false
                    saved = nil
                    lastTarget = nil
                    persist()
                    end("entrée annulée, inclinaison refusée")
                    return failure(error)
                }
                log("Inclinaison de la vie privée refusée (\(error)) : le mode natif part tout de suite ; l'inclinaison sera renvoyée s'il ne tient pas.")
                tiltRefused = true
            }
        }
        reconcile(interrupt: true)
        return nil
    }

    private func requestExit(from client: ClientID) -> (code: ErrorCode, message: String)? {
        guard isActive else { return nil }
        requester = client
        guard wanted else { return nil }
        begin("sortie demandée (client \(client))")
        wanted = false
        attempts = 0
        readFailures = 0
        awake = false
        rereadRequested = false
        if exitsDirectly, !stepInProgress, !afterWake {
            // Sans mode natif possible : directement la position mémorisée (spec § 6.5 bis, sortie, étape 4).
            stopStep()
            do {
                try restore()
            } catch {
                // La vie privée reste en vigueur, et sa vérification reprend.
                wanted = true
                reconcile(interrupt: true)
                return failure(error)
            }
            return nil
        }
        reconcile(interrupt: true)
        return nil
    }

    // MARK: - Réconciliation

    /// Choisit l'étape suivante d'après l'état voulu et l'état constaté. Une étape qui va à son terme (ordre, bascule,
    /// attente de position) n'est jamais interrompue ; un délai ou une vérification l'est si `interrupt` (nouveau choix).
    private func reconcile(interrupt: Bool = false) {
        switch step {
        case .order, .switching, .settling:
            return
        case .pause, .verifying:
            guard interrupt else { return }
            stopStep()
        case .idle:
            break
        }
        guard camera.isPresent, isActive else { return }
        if wanted {
            advanceEntry()
        } else {
            advanceExit()
        }
    }

    private func advanceEntry() {
        guard runner.supportsNativePrivacy else {
            if mayBeNative {
                // Plus d'utilitaire pour lire ni réveiller la caméra : l'inclinaison est le seul recours.
                log("Vie privée : obsbot-ai absent, l'état réel ne se lit plus ; protection par l'inclinaison.")
                mayBeNative = false
                persist()
            }
            protectByTilt()
            return
        }
        if real == .privacy {
            // Mode natif constaté : la caméra est protégée et gère seule sa position. Une confirmation tardive efface
            // l'échec annoncé. Relecture lente de l'état, ou tout de suite si elle est demandée (constat B).
            attempts = 0
            gaveUp = false
            lastTarget = nil
            tilt = .none
            if rereadRequested {
                rereadRequested = false
                issue(.status)
            } else {
                pause(Self.rereadInterval) { $0.issue(.status) }
            }
            return
        }
        if mayBeNative && real == nil {
            readUnknownState()
            return
        }
        // Ici, la caméra n'est pas en mode natif : lue éveillée, jamais mise en mode natif, ou rebranchée.
        rereadRequested = false
        if pendingTake {
            pendingTake = false
            control.take()
        }
        if afterWake {
            // Elle vient de quitter le mode natif (ou ne l'a pas pris) : sa remontée est finie, une marge encore.
            afterWake = false
            pause(Self.riseMargin) { $0.reconcile() }
            return
        }
        if updating || gaveUp {
            protectByTilt()
            return
        }
        switch tilt {
        case .none:
            if tiltRefused {
                // Inclinaison refusée : le mode natif protégera l'image ; s'il ne tient pas, elle sera renvoyée.
                tiltRefused = false
                sendPrivacyOn()
            } else if let cause = fallbackCause() {
                // Repli : −70° d'abord, attente que la caméra y soit, puis le mode natif.
                plugged = false
                note("chemin de repli, −70° d'abord (\(cause))")
                if sendTilt() {
                    startSettle()
                } else {
                    sendPrivacyOn()
                }
            } else {
                // Chemin rapide (spec § 6.5 bis, « Accélération ») : la caméra est éveillée, le SDK prêt. Le mode natif
                // part de la position courante, d'un seul mouvement, et la caméra la reprendra d'elle-même au réveil.
                note("chemin rapide, privacy on directement depuis la position courante")
                sendPrivacyOn()
            }
        case .sent:
            if tiltWaited {
                // Pas vue à −70° à temps : le mode natif part quand même (la protection reste « en cours »).
                sendPrivacyOn()
            } else {
                startSettle()
            }
        case .placed:
            sendPrivacyOn()
        }
    }

    /// Pourquoi l'entrée passe par le repli (−70° d'abord), ou nil pour le chemin rapide : `privacy on` directement,
    /// SDK prêt et caméra éveillée (spec § 6.5 bis, « Accélération »).
    private func fallbackCause() -> String? {
        if !runner.supportsNativePrivacy {
            return "pas de SDK"
        }
        if updating {
            return "obsbot-ai en attente de recompilation"
        }
        if gaveUp {
            return "deux échecs du mode natif"
        }
        if plugged {
            return "caméra branchée, peut-être éveillée et droite"
        }
        if stateUnreadable {
            return "état réel illisible"
        }
        if runner.busyWithExposure {
            // La vie privée passe devant les ordres d'exposition en attente, mais pas devant celui qui est parti.
            return "ordre d'exposition en cours"
        }
        if !runner.isReady {
            // Un ordre attendrait la session neuve du SDK (environ 4 s) : l'inclinaison protège tout de suite.
            return "SDK pas encore prêt"
        }
        return nil
    }

    /// L'état réel est inconnu alors que la caméra peut être en mode natif : on le lit, sans aucun ordre de position.
    /// Une lecture ratée est refaite une fois ; puis un nouvel ordre natif (sans effet si la caméra y est déjà) ; une
    /// fois les essais épuisés, des relectures espacées jusqu'à une réponse.
    private func readUnknownState() {
        if updating {
            // Un utilitaire d'avant la V2 ne sait pas lire l'état : on attend sa recompilation, sans ordre de position.
            return
        }
        rereadRequested = false
        if readFailures == 0 {
            issue(.status)
            return
        }
        if readFailures < Self.maxAttempts {
            pause(Self.retryDelay) { $0.issue(.status) }
            return
        }
        if attempts < Self.maxAttempts {
            // Le seul cas où un `privacy on` part sans avoir lu l'état : deux lectures ratées de suite.
            note("état lu : illisible (\(readFailures) lectures ratées), privacy on de précaution, sans effet si la caméra y est déjà")
            pause(Self.retryDelay) { $0.sendPrivacyOn() }
            return
        }
        giveUp()
        let delay = Self.readBackoff[min(readFailures - Self.maxAttempts, Self.readBackoff.count - 1)]
        pause(delay) { $0.issue(.status) }
    }

    private func advanceExit() {
        if awake || exitsDirectly {
            // Réveil constaté : sa remontée propre est finie. Sortie rapide : revenue d'elle-même à `saved`, rien
            // d'autre ; sinon (entrée par le repli, caméra bougée entre-temps), une marge, puis la position mémorisée.
            if afterWake {
                afterWake = false
                if returnedToSaved() {
                    lastTarget = nil
                    endPrivacy()
                    end("levée, caméra revenue d'elle-même à sa position d'avant")
                    return
                }
                pause(Self.riseMargin) { $0.reconcile() }
            } else {
                finishExit()
            }
            return
        }
        if updating {
            // Un utilitaire d'avant la V2 ne peut pas réveiller une caméra peut-être en mode natif.
            exitFailed(.needsUpdate)
            return
        }
        if attempts == 0 {
            sendPrivacyOff()
            return
        }
        // Le dernier essai n'a pas réveillé la caméra (lue en vie privée), ou son état ne se lit pas.
        if attempts < Self.maxAttempts {
            pause(Self.retryDelay) { $0.sendPrivacyOff() }
            return
        }
        exitFailed(real == .privacy ? .stayedPrivate : .unreadable)
    }

    // MARK: - Ordres natifs

    private func sendPrivacyOn() {
        let before = Known(real: real, mayBeNative: mayBeNative)
        attempts += 1
        readFailures = 0
        // Un arrêt du mouvement refusé n'est plus retenté : aucun ordre UVC vers une caméra peut-être en mode natif.
        motion.cancelStopRetry()
        setMayBeNative(true)
        issue(.on, before: before)
    }

    private func sendPrivacyOff() {
        attempts += 1
        readFailures = 0
        issue(.off, before: Known(real: real, mayBeNative: mayBeNative))
    }

    /// Ce qu'on savait de la caméra avant un ordre natif : un « ordre inconnu » n'a rien changé, on y revient.
    private struct Known {
        let real: CameraRunState?
        let mayBeNative: Bool
    }

    /// Donne l'ordre à l'utilitaire (par la file : il part après ceux qui attendent). L'état réel devient inconnu dès
    /// qu'un ordre natif part.
    private func issue(_ order: NativeOrder, before: Known? = nil) {
        ticket += 1
        let current = ticket
        stopStep()
        step = .order
        switch order {
        case .on, .off:
            let before = before ?? Known(real: real, mayBeNative: mayBeNative)
            real = nil
            switching = nil
            orderStart = scheduler.now
            note("\(Self.name(order)) envoyé")
            runner.runPrivacy(on: order == .on) { [weak self] result in
                guard let self, current == ticket else { return }
                step = .idle
                replied(order, result, before: before)
                changed()
            }
        case .status:
            runner.readPrivacy { [weak self] reading in
                guard let self, current == ticket else { return }
                step = .idle
                read(reading)
                changed()
            }
        }
    }

    private func replied(_ order: NativeOrder, _ result: AIResult, before: Known) {
        if result == .unknownOrder {
            // obsbot-ai d'avant la V2 : rien n'a été fait, la caméra n'a pas bougé (spec § 6.5 bis). La protection à
            // −70° reprend, vérifiée : l'objectif n'est « en place » que s'il y a été vu.
            log("obsbot-ai ne connaît pas la vie privée native : protection à −70° en attendant sa recompilation.")
            updating = true
            attempts -= 1
            real = before.real
            setMayBeNative(before.mayBeNative)
            if order == .off, !mayBeNative {
                // Cet utilitaire n'a jamais mis la caméra en mode natif : elle est éveillée.
                awake = true
            }
            reconcile()
            return
        }
        note("\(Self.name(order)) rendu (\(result == .success ? "ok" : "\(result)")) \(Self.seconds(scheduler.now - orderStart)) après l'ordre"
            + (result == .success ? "" : " ; l'état réel est relu"))
        if order == .on, !wanted {
            // Une sortie a été demandée pendant l'ordre : `privacy off` part tout de suite, il remplace celui-ci.
            reconcile()
            return
        }
        // L'ordre rend la main tout de suite ; la caméra bascule ensuite. Une lecture faite trop tôt rendrait l'état
        // d'avant : la première attend `switchDelay`.
        switching = Switch(order: order, start: scheduler.now, deadline: scheduler.now + Self.switchLimit)
        wait(Self.switchDelay, as: .switching) { $0.issue(.status) }
    }

    /// L'état lu, ou celui que dit le second témoin quand l'état ne se lit pas : la nacelle dans la pose du mode natif
    /// (vers 85°) ou hors de cette pose (70° à −70° UVC). Entre les deux, rien. `witness` décrit l'usage du témoin.
    private func witnessed(_ reading: PrivacyReading) -> (state: CameraRunState?, pitch: Double?, witness: String?) {
        switch reading {
        case let .state(state, pitch):
            return (state, pitch, nil)
        case let .failed(result, pitch):
            guard let pitch else {
                return (nil, nil, "état réel illisible (\(result))")
            }
            let state: CameraRunState? = if pitch >= Self.nativePitch {
                .privacy
            } else if pitch <= Self.awakePitch {
                .run
            } else {
                nil
            }
            let pose = switch state {
            case .privacy: "pose du mode natif"
            case .run: "hors de la pose du mode natif"
            case nil: "en mouvement"
            }
            return (state, pitch, "état réel illisible (\(result)), inclinaison \(pitch)° : \(pose)")
        }
    }

    private func read(_ reading: PrivacyReading) {
        if case .failed(.unknownOrder, _) = reading {
            log("obsbot-ai ne sait pas lire l'état de la caméra : en attente de sa recompilation.")
            updating = true
            switching = nil
            reconcile()
            return
        }
        let (seen, pitch, witness) = witnessed(reading)
        if case .state = reading {
            stateUnreadable = false
        } else {
            stateUnreadable = true
        }
        lastPitch = pitch
        if var current = switching {
            current.reads += 1
            let target: CameraRunState = current.order == .on ? .privacy : .run
            var switched = seen == target
            if target == .run {
                // Réveillée, elle a fini sa remontée : plus dans la pose du mode natif (sauf si sa position d'entrée,
                // objectif très bas, y était déjà), et immobile (deux inclinaisons de suite à moins d'1° l'une de
                // l'autre : une remontée peut durer plus que l'état `run`, m4). Dite réveillée par le seul témoin, elle ne
                // l'est qu'une fois passé le délai de l'état `run`.
                var still = true
                if let pitch {
                    still = current.lastPitch.map { abs($0 - pitch) <= Self.stableTolerance } ?? false
                }
                let posed = pitch.map { $0 >= Self.nativePitch && !isEntryPose($0) } ?? false
                switched = switched && !posed && still
                    && (witness == nil || scheduler.now - current.start >= Self.witnessWakeDelay)
            }
            current.lastPitch = pitch
            switching = current
            if !switched && scheduler.now < current.deadline {
                // La bascule n'est pas finie : relue un peu plus tard, et rien d'autre ne part.
                wait(Self.pollInterval, as: .switching) { $0.issue(.status) }
                return
            }
            switching = nil
            // Une ligne pour toute la bascule, pas une par relecture.
            let state = seen.map { "état \($0.rawValue) lu" } ?? "état illisible"
            let reads = current.reads > 1 ? "\(current.reads) lectures" : "1 lecture"
            let tilt = pitch.map { ", inclinaison SDK \(Self.pitchText($0))" } ?? ""
            note("\(Self.name(current.order)), \(state) \(Self.seconds(scheduler.now - orderStart)) après l'ordre (\(reads)\(tilt))"
                + (witness.map { " ; \($0)" } ?? ""))
            if let seen {
                apply(seen, pitch: pitch)
                if !switched {
                    noteFailedAttempt(current.order, seen: seen)
                }
            } else {
                readFailures += 1
            }
            reconcile()
            return
        }
        // Une ligne de journal quand le témoin décide, ou quand rien ne se lit ; pas à chaque relecture lente.
        if let witness, seen == nil || seen != real {
            log("Caméra : \(witness).")
        }
        // Dans une séquence (démarrage, branchement, reprise), l'état lu est écrit avant d'agir : on voit ce que ptzd a
        // constaté, et pourquoi un ordre natif part ou non.
        if sequenceStart != nil, let seen {
            let source = witness == nil ? "" : " (témoin)"
            let action = switch (wanted, seen) {
            case (true, .privacy): "rien à faire"
            case (true, .run): "reprotection"
            case (false, .privacy): "la sortie reprend"
            case (false, .run): "la sortie se termine"
            }
            note("état lu : \(seen.rawValue)\(source), \(action)")
        }
        if let seen {
            apply(seen, pitch: pitch)
        } else {
            readFailures += 1
            if real == .privacy, readFailures >= Self.maxAttempts {
                readLost()
            }
        }
        reconcile()
    }

    /// Le mode natif est constaté, mais l'état ne se lit plus depuis `maxAttempts` relectures de suite (OBSBOT Center
    /// ouvert, USB pas prêt après la veille, session du SDK périmée) : la caméra a pu être réveillée sans que ptzd le voie.
    /// « Image et micro coupés » n'est plus affirmé (« protection en cours »), la session du SDK est renouvelée, et la
    /// séquence reprend : lecture, puis `privacy on` (sans effet si la caméra y est déjà, mesuré), puis des relectures
    /// espacées. Aucun ordre de position tant que la caméra peut être en mode natif.
    private func readLost() {
        log("Caméra : l'état réel ne se lit plus (\(readFailures) lectures de suite) ; « image et micro coupés » n'est plus affirmé. Session du SDK renouvelée.")
        real = nil
        readFailures = 0
        runner.reset()
    }

    /// Un état lu (ou dit par le témoin).
    private func apply(_ state: CameraRunState, pitch: Double?) {
        let wasNative = mayBeNative
        readFailures = 0
        // Lue : la caméra n'est plus « branchée sans lecture ».
        plugged = false
        real = state
        setMayBeNative(state == .privacy)
        if state == .privacy, wanted, sequenceStart != nil {
            // Une relecture qui confirme, elle, ne dit rien.
            end("mode natif constaté, image et micro coupés")
        }
        guard state == .run else { return }
        if wasNative, wanted, sequenceStart == nil {
            begin("caméra lue éveillée pendant la vie privée, reprotection")
        }
        if wasNative {
            // Lue éveillée alors qu'elle pouvait être en mode natif : elle en sort, ou ne l'a pas pris. Sa remontée est
            // finie quand l'état `run` se lit (mesuré) ; une marge encore avant tout ordre de position.
            afterWake = true
        }
        if let pitch, abs(pitch + Self.privacyTilt) <= Self.positionTolerance {
            // Le SDK la voit à −70° (inclinaison 70 vers le bas) : l'objectif est détourné, inutile de le renvoyer.
            tilt = .placed
            lastTarget = PanTiltPosition(pan: saved?.pan ?? 0, tilt: Self.privacyTilt)
        } else if wasNative {
            // Pas revue à −70° depuis qu'elle pouvait être en mode natif : l'inclinaison sera renvoyée.
            tilt = .none
        }
        if !wanted {
            awake = true
        }
    }

    /// L'inclinaison lue par le SDK est celle de la position d'avant la vie privée : la caméra y revient d'elle-même au
    /// réveil après une entrée rapide.
    private func isEntryPose(_ pitch: Double) -> Bool {
        saved.map { abs(-$0.tilt - pitch) < Self.returnTolerance } ?? false
    }

    /// L'ordre natif n'a pas pris dans le délai de la bascule.
    private func noteFailedAttempt(_ order: NativeOrder, seen: CameraRunState) {
        if order == .on, wanted {
            note("mode natif non constaté (état réel : \(seen.rawValue)), essai \(attempts)/\(Self.maxAttempts)")
            if attempts >= Self.maxAttempts {
                giveUp()
            }
        } else if order == .off, !wanted {
            note("caméra pas réveillée (état réel : \(seen.rawValue)), essai \(attempts)/\(Self.maxAttempts)")
        }
    }

    /// L'entrée a épuisé ses essais : la protection à −70° seule, et l'avertissement au client qui l'a demandée.
    private func giveUp() {
        guard !gaveUp else { return }
        gaveUp = true
        end("repli après \(Self.maxAttempts) essais du mode natif, l'objectif reste détourné à −70°")
        if let requester {
            onClientError?(requester, .uvcFailed, PrivacyFailureText.fallbackToTilt)
        }
    }

    /// La sortie ne peut pas être confirmée : la vie privée reste en vigueur, l'erreur exacte est montrée, et le
    /// réconciliateur la ramène vers un état sûr (mode natif confirmé, ou protection à −70°). Un nouvel ordre de sortie
    /// la retente toujours.
    private func exitFailed(_ cause: ExitFailure) {
        end("la vie privée n'a pas pu être levée (état réel : \(real?.rawValue ?? "illisible")), elle reste en vigueur")
        if let requester {
            onClientError?(requester, .uvcFailed, cause.text)
        }
        wanted = true
        attempts = 0
        gaveUp = false
        tilt = .none
        reconcile()
    }

    // MARK: - Position

    /// Les ordres de vie privée ne passent que par l'inclinaison : impossibles quand le mode natif sert.
    private var protectsByTiltOnly: Bool {
        !runner.supportsNativePrivacy || updating || gaveUp
    }

    /// La sortie va directement à la position mémorisée : pas d'utilitaire, ou un utilitaire d'avant la V2 qui n'a pas
    /// pu mettre la caméra en mode natif.
    private var exitsDirectly: Bool {
        !runner.supportsNativePrivacy || (updating && !mayBeNative)
    }

    private var stepInProgress: Bool {
        switch step {
        case .order, .switching, .settling: true
        case .idle, .pause, .verifying: false
        }
    }

    /// La protection par l'inclinaison seule : l'objectif à −70°, toujours vérifié et renvoyé sans fin (spec § 6.5),
    /// dès qu'il est établi que la caméra n'est pas en mode natif.
    private func protectByTilt() {
        guard !mayBeNative else { return }
        // Pas envoyée, refusée, ou attendue sans être vue à −70° : renvoyée tout de suite. Juste envoyée : la
        // vérification la renverra si besoin.
        if tilt == .none || lastTarget == nil || (tilt == .sent && tiltWaited) {
            sendTilt()
        }
        startVerification()
    }

    /// L'inclinaison à −70° ; un refus est journalisé (la vérification la renvoie). Faux si elle n'est pas partie.
    @discardableResult
    private func sendTilt() -> Bool {
        do {
            try sendTiltOrThrow()
            return true
        } catch {
            log("Inclinaison de la vie privée refusée : \(error)")
            return false
        }
    }

    /// Le seul ordre de position de la vie privée : jamais quand la caméra peut être en mode natif. Refusé, il reste la
    /// cible de la vérification.
    private func sendTiltOrThrow() throws {
        guard !mayBeNative else {
            log("Inclinaison retenue : la caméra peut être en mode natif.")
            return
        }
        let target = PanTiltPosition(pan: saved?.pan ?? 0, tilt: Self.privacyTilt)
        lastTarget = target
        tilt = .sent
        tiltWaited = false
        do {
            try camera.setPanTiltAbsolute(panDegrees: target.pan, tiltDegrees: target.tilt)
        } catch {
            tilt = .none
            throw error
        }
    }

    /// Attente que la caméra soit stable près de −70°, avant le mode natif. Passé le délai maximal, la séquence
    /// continue ; l'objectif n'est « en place » que s'il y a été vu.
    private func startSettle() {
        stopStep()
        settle = Settle(deadline: scheduler.now + Self.tiltWaitLimit, previous: nil)
        step = .settling
        scheduleSettleRead(after: Self.settleDelay)
    }

    private func scheduleSettleRead(after delay: TimeInterval) {
        timer = scheduler.schedule(after: delay) { [weak self] in
            guard let self, case .settling = step else { return }
            timer = nil
            settleTick()
        }
    }

    private func settleTick() {
        guard var current = settle else { return }
        motion.refreshPosition()
        let position = motion.position
        var stable = false
        if let position, let previous = current.previous {
            stable = abs(position.pan - previous.pan) <= Self.stableTolerance
                && abs(position.tilt - previous.tilt) <= Self.stableTolerance
        }
        let onTarget = position.map { abs($0.tilt - Self.privacyTilt) <= Self.positionTolerance } ?? false
        if stable && onTarget {
            finishSettle(onTarget: true)
        } else if scheduler.now >= current.deadline {
            log("Inclinaison de la vie privée non stabilisée à temps (relue \(position.map { "\($0)" } ?? "illisible")) : la séquence continue.")
            finishSettle(onTarget: onTarget)
        } else {
            current.previous = position
            settle = current
            scheduleSettleRead(after: Self.pollInterval)
        }
        changed()
    }

    private func finishSettle(onTarget: Bool) {
        if onTarget {
            note("−70° atteint, relu \(motion.position.map { Self.degrees($0.tilt) } ?? "illisible")")
        }
        settle = nil
        step = .idle
        tiltWaited = true
        tilt = onTarget ? .placed : .sent
        reconcile()
    }

    /// Sortie, dernière étape : zoom puis position mémorisée (ou 0°/0°), et fin de la vie privée.
    private func finishExit() {
        do {
            try restore()
        } catch CameraError.absent {
            // Le débranchement est traité à part ; le branchement reprend la sortie.
            return
        } catch {
            end("position d'avant la vie privée refusée par la caméra (\(error)), la vie privée reste en vigueur")
            if let requester {
                onClientError?(requester, .uvcFailed, "La caméra a refusé la commande (\(error)).")
            }
            wanted = true
            tilt = .none
            reconcile()
        }
    }

    /// Zoom d'abord : si la caméra refuse, l'objectif est encore tourné vers le bas. Puis la position, vérifiée et
    /// renvoyée au plus `maxResends` fois. Si la caméra refuse, rien ne change et l'erreur remonte.
    private func restore() throws {
        let target = saved ?? SavedPosition(pan: 0, tilt: 0, zoom: nil)
        if let value = target.zoom {
            try camera.setZoom(value)
        }
        try camera.setPanTiltAbsolute(panDegrees: target.pan, tiltDegrees: target.tilt)
        lastTarget = PanTiltPosition(pan: target.pan, tilt: target.tilt)
        endPrivacy()
        end("levée, position mémorisée renvoyée (vérifiée dans \(Int(Self.settleDelay)) s)")
        startVerification()
    }

    /// Fin de la vie privée, la caméra à sa position d'avant (renvoyée, ou reprise d'elle-même).
    private func endPrivacy() {
        isActive = false
        plugged = false
        saved = nil
        mayBeNative = false
        real = nil
        tilt = .none
        tiltRefused = false
        attempts = 0
        readFailures = 0
        awake = false
        afterWake = false
        switching = nil
        requester = nil
        pendingTake = false
        persist()
        zoom.refresh()
        onEnded?()
    }

    /// Sortie rapide (spec § 6.5 bis, « Accélération ») : la caméra vient d'être lue éveillée, nacelle immobile. Position
    /// et zoom relus (UVC), comparés à `saved` ; l'inclinaison lue par le SDK doit aussi y être, au cas où la relecture
    /// UVC serait périmée. Vrai si rien n'est à renvoyer, jamais si l'inclinaison du SDK manque (le second témoin ne dit
    /// rien : la position mémorisée est renvoyée et vérifiée). Une relecture ne bouge pas la caméra.
    private func returnedToSaved() -> Bool {
        motion.refreshPosition()
        let position = motion.position
        let zoomValue = try? camera.readZoom()
        let read = position.map { "pan \(Self.degrees($0.pan)), tilt \(Self.degrees($0.tilt))" } ?? "position illisible"
        let readZoom = zoomValue.map { "zoom \($0)" } ?? "zoom illisible"
        let readPitch = lastPitch.map { " (inclinaison SDK \(Self.pitchText($0)))" } ?? ""
        guard let target = saved else {
            note("position relue \(read), \(readZoom)\(readPitch) ; position mémorisée inconnue, 0°/0° renvoyé")
            return false
        }
        var gap = Double.infinity
        if let position {
            gap = max(abs(position.pan - target.pan), abs(position.tilt - target.tilt))
        }
        // Le second témoin manque (inclinaison illisible par le SDK) : la relecture UVC, juste après le mouvement propre
        // de la caméra, n'est pas mesurée comme fiable. Rien n'est conclu : la position mémorisée est renvoyée et
        // vérifiée, comme avant la sortie rapide.
        let witnessMissing = lastPitch == nil
        if let lastPitch {
            gap = max(gap, abs(-lastPitch - target.tilt))
        }
        let zoomSame = target.zoom == nil || zoomValue == target.zoom
        let back = gap < Self.returnTolerance && zoomSame && !witnessMissing
        let memorized = "pan \(Self.degrees(target.pan)), tilt \(Self.degrees(target.tilt)), zoom \(target.zoom.map { "\($0)" } ?? "inconnu")"
        let verdict = back ? "rien à renvoyer" : "position mémorisée renvoyée"
        let shownGap = gap.isFinite ? Self.degrees(gap) : "inconnu"
        let missing = witnessMissing ? ", inclinaison SDK illisible" : ""
        note("position relue \(read), \(readZoom)\(readPitch) ; mémorisée \(memorized) : écart \(shownGap)\(zoomSame ? "" : ", zoom différent")\(missing), \(verdict)")
        return back
    }

    // MARK: - Vérification de la position (spec § 6.5)

    /// Relit la position après `delay`, puis la compare à la cible. `resends` compte les renvois déjà faits.
    private func startVerification(resends: Int = 0, delay: TimeInterval = PrivacyReconciler.settleDelay) {
        stopStep()
        step = .verifying
        timer = scheduler.schedule(after: delay) { [weak self] in
            guard let self, case .verifying = step else { return }
            timer = nil
            motion.refreshPosition()
            zoom.refresh()
            checkTarget(resends: resends)
            changed()
        }
    }

    /// La caméra ignore parfois un ordre absolu en renvoyant un succès : on compare la position relue à la cible et
    /// on renvoie l'ordre. Hors vie privée, au plus `maxResends` fois ; en vie privée, jusqu'à ce que le tilt soit
    /// atteint.
    private func checkTarget(resends: Int) {
        step = .idle
        guard let target = lastTarget, !(isActive && mayBeNative) else { return }
        let position = motion.position
        if let position {
            // En vie privée, seul le tilt protège l'image ; à −70° la caméra relit d'ailleurs un pan décalé
            // (constaté le 2026-10-05). Hors vie privée, les deux axes comptent.
            let panReached = isActive || abs(position.pan - target.pan) <= Self.positionTolerance
            if panReached && abs(position.tilt - target.tilt) <= Self.positionTolerance {
                if resends > Self.maxResends {
                    log("Position atteinte après \(resends) renvois : relue \(position).")
                }
                if isActive {
                    tilt = .placed
                }
                return
            }
        } else if !isActive {
            // Position illisible hors vie privée : rien à comparer.
            return
        }
        let seen = position.map { "\($0)" } ?? "illisible"
        if isActive {
            retryProtection(target: target, seen: seen, resends: resends)
            return
        }
        guard resends < Self.maxResends else {
            log("Position non atteinte après \(Self.maxResends) renvois : cible \(target), relue \(seen).")
            return
        }
        log("Ordre absolu ignoré par la caméra (cible \(target), relue \(seen)) : nouvel envoi.")
        do {
            try camera.setPanTiltAbsolute(panDegrees: target.pan, tiltDegrees: target.tilt)
            startVerification(resends: resends + 1)
        } catch {
            log("Nouvel envoi refusé : \(error)")
        }
    }

    /// Protection par l'inclinaison : renvoi puis nouvelle vérification après 2, 5, 10, puis toutes les 30 s, sans
    /// jamais abandonner. Une ligne de journal par palier au plus.
    private func retryProtection(target: PanTiltPosition, seen: String, resends: Int) {
        let stage = min(resends, Self.privacyBackoff.count - 1)
        let delay = Self.privacyBackoff[stage]
        let logged = resends < Self.privacyBackoff.count
        if logged {
            let next = stage == Self.privacyBackoff.count - 1 ? "toutes les \(Int(delay)) s" : "dans \(Int(delay)) s"
            log("Ordre de vie privée ignoré par la caméra (cible \(target), relue \(seen)) : nouvel envoi, vérification \(next).")
        }
        do {
            try camera.setPanTiltAbsolute(panDegrees: target.pan, tiltDegrees: target.tilt)
        } catch CameraError.absent {
            // Le débranchement est traité à part ; le branchement réapplique.
            return
        } catch {
            if logged {
                log("Nouvel envoi refusé : \(error). Nouvel essai quand même.")
            }
        }
        startVerification(resends: resends + 1, delay: delay)
    }

    // MARK: - Outils

    /// Un délai interrompu par un nouveau choix.
    private func pause(_ delay: TimeInterval, then action: @escaping @MainActor @Sendable (PrivacyReconciler) -> Void) {
        wait(delay, as: .pause, then: action)
    }

    /// Un délai : `pause` s'arrête à un nouveau choix, `switching` va à son terme.
    private func wait(
        _ delay: TimeInterval,
        as kind: Step,
        then action: @escaping @MainActor @Sendable (PrivacyReconciler) -> Void
    ) {
        stopStep()
        step = kind
        timer = scheduler.schedule(after: delay) { [weak self] in
            guard let self, step == kind else { return }
            timer = nil
            step = .idle
            action(self)
            changed()
        }
    }

    /// Arrête le délai, l'attente ou la vérification en cours (un ordre en cours, lui, garde sa réponse : voir `ticket`).
    private func stopStep() {
        timer?.cancel()
        timer = nil
        settle = nil
        step = .idle
    }

    private func setMayBeNative(_ value: Bool) {
        guard mayBeNative != value else { return }
        mayBeNative = value
        persist()
    }

    /// Une erreur d'écriture n'empêche pas de protéger l'image : on la journalise.
    private func persist() {
        do {
            // Relit d'abord le fichier : l'exposition automatique y écrit aussi (spec § 6.11), ses champs ne doivent pas
            // être effacés.
            var state = store.load()
            state.privacy = isActive
            state.saved = saved
            state.native = mayBeNative
            try store.save(state)
        } catch {
            log("Enregistrement de state.json impossible : \(error)")
        }
    }

    private func failure(_ error: any Error) -> (code: ErrorCode, message: String) {
        if case CameraError.absent? = error as? CameraError {
            return (.cameraAbsent, "Caméra débranchée.")
        }
        log("Commande UVC refusée : \(error)")
        return (.uvcFailed, "La caméra a refusé la commande (\(error)).")
    }

    private func changed() {
        onChange?()
    }

    // MARK: - Journal (spec § 6.5 bis : une ligne par étape, lisible pour un diagnostic)

    /// Une demande ou une réapplication commence : les durées suivantes partent de là.
    private func begin(_ text: String) {
        sequenceStart = scheduler.now
        log("Vie privée : \(text).")
    }

    /// Une étape, avec la durée depuis le début de la séquence.
    private func note(_ text: String) {
        let elapsed = sequenceStart.map { " (+\(Self.seconds(scheduler.now - $0)))" } ?? ""
        log("Vie privée : \(text)\(elapsed).")
    }

    /// La fin d'une séquence, avec sa durée totale.
    private func end(_ text: String) {
        guard let start = sequenceStart else {
            log("Vie privée : \(text).")
            return
        }
        sequenceStart = nil
        log("Vie privée : \(text), en \(Self.seconds(scheduler.now - start)) au total.")
    }

    private static func name(_ order: NativeOrder) -> String {
        switch order {
        case .on: "privacy on"
        case .off: "privacy off"
        case .status: "privacy status"
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2f s", value)
    }

    private static func degrees(_ value: Double) -> String {
        String(format: "%.1f°", value)
    }

    /// L'inclinaison lue par le SDK, positive vers le bas.
    private static func pitchText(_ pitch: Double) -> String {
        pitch >= 0 ? "\(degrees(pitch)) vers le bas" : "\(degrees(-pitch)) vers le haut"
    }
}
