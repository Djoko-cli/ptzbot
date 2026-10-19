import Foundation
import NacelleProtocol

/// La vie privée (spec § 6.5 et § 6.5 bis) : un état voulu, un état constaté, et un réconciliateur qui mène l'un vers
/// l'autre, une étape à la fois.
///
/// - **Deux couches.** La protection immédiate est l'inclinaison à −70° (commande UVC directe) ; avec le SDK, le mode
///   natif de la caméra (image noire, micro coupé) vient par-dessus, par obsbot-ai.
/// - **Un seul pilote de la position.** Tant que la caméra peut être en mode natif (constaté, ou ordre natif parti sans
///   lecture depuis), y entre ou en sort, aucun ordre de position UVC ne part : elle gère seule sa position.
/// - **Rien n'est supposé.** Après chaque ordre natif, et quand une réponse manque ou échoue, l'état réel est relu
///   (`privacy status`). `native` n'est publié qu'après une lecture `privacy`.
/// - **Le dernier choix gagne.** Une étape en cours (un ordre à l'utilitaire, une attente de position) va à son terme ;
///   la séquence repart alors vers le nouvel état voulu. Un délai d'attente ou une vérification s'arrêtent tout de
///   suite. Aucun ordre n'est croisé : l'utilitaire n'en traite qu'un à la fois, et le réconciliateur n'en donne
///   jamais un second avant la réponse du premier.
///
/// Entrée : prise de la main sur le suivi IA, inclinaison à −70°, attente que la caméra y soit, `privacy on`, lecture ;
/// deux essais, puis la protection à −70° seule, vérifiée sans fin. Sortie : `privacy off` (avec le SDK, quel que soit
/// le mode), lecture jusqu'à `run`, attente de la fin de la remontée propre de la caméra, puis zoom et position
/// mémorisée. Un ancien obsbot-ai (« ordre inconnu ») laisse la protection à −70° jusqu'à sa recompilation.
@MainActor
public final class PrivacyReconciler {
    // MARK: - Réglages (délais à mesurer au banc : essais 1, 14)

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
    /// Attente de stabilité : une relecture à `settleDelay`, puis toutes les `pollInterval`, jusqu'à deux relectures de
    /// suite à moins de `stableTolerance` l'une de l'autre (près de −70°, sauf après un redémarrage de la caméra).
    public static let pollInterval: TimeInterval = 0.5
    public static let stableTolerance: Double = 1
    /// Délai maximal de l'attente de l'inclinaison avant le mode natif : passé ce délai, le mode natif part quand même.
    public static let tiltWaitLimit: TimeInterval = 8
    /// Délai maximal de l'attente de la remontée propre de la caméra après le réveil : passé ce délai, la position
    /// mémorisée part quand même.
    public static let riseWaitLimit: TimeInterval = 12
    /// Délai avant le second essai d'un ordre natif : il part dans les 10 s de la spec.
    public static let retryDelay: TimeInterval = 3
    /// Essais au plus d'une entrée ou d'une sortie native.
    public static let maxAttempts = 2
    /// État réel toujours illisible : relectures de plus en plus espacées, la dernière se répétant.
    public static let readBackoff: [TimeInterval] = [3, 5, 10, 30]

    // MARK: - État publié

    /// La vie privée est en vigueur (state.json `privacy`) : de l'entrée demandée jusqu'à la fin de la sortie. Pendant ce
    /// temps, `move`, `zoom` et le suivi IA sont refusés.
    public private(set) var isActive: Bool
    /// `native` seulement quand la dernière lecture de l'état réel a rendu `privacy` ; `tilt` sinon (spec § 6.5 bis).
    public var mode: PrivacyMode? {
        guard isActive else { return nil }
        return real == .privacy ? .native : .tilt
    }
    /// En mode `tilt`, pourquoi le mode natif ne tient pas ; nil pendant qu'il est en cours.
    public var reason: PrivacyReason? {
        guard mode == .tilt else { return nil }
        if !runner.supportsNativePrivacy {
            return .noSDK
        }
        if updating {
            return .updating
        }
        return gaveUp || readFailures >= Self.maxAttempts ? .failed : nil
    }
    /// Appelé quand l'état publié a pu changer.
    public var onChange: (() -> Void)?
    /// Un échec à montrer au client qui a demandé la vie privée (repli sur l'inclinaison, sortie impossible).
    public var onClientError: ((ClientID, ErrorCode, String) -> Void)?

    // MARK: - État interne

    /// L'inclinaison de la protection en cours : pas envoyée, envoyée (attente de la position), en place.
    private enum Tilt {
        case none
        case sent
        case placed
    }

    /// L'étape en cours. `order` et `settling` vont à leur terme ; `pause` et `verifying` s'arrêtent à un nouveau choix.
    private enum Step {
        case idle
        /// Un ordre à l'utilitaire, jusqu'à sa réponse.
        case order
        /// Attente que la position se stabilise près de −70° (avant le mode natif, ou après le réveil).
        case settling
        /// Délai avant un nouvel essai, ou relecture différée.
        case pause
        /// Vérification de la position (spec § 6.5) : protection par l'inclinaison, ou position rétablie à la sortie.
        case verifying
    }

    private enum NativeOrder {
        case on
        case off
        case status
    }

    /// Ce qu'attend une attente de position.
    private enum SettleKind {
        /// L'inclinaison à −70° avant le mode natif : stable près de −70°.
        case tilt
        /// La remontée propre de la caméra après un réveil : elle revient d'elle-même à la position qu'elle avait en
        /// entrant en mode natif, −70° (ptzd l'y met toujours avant) ; stable près de −70°.
        case wake
        /// Une caméra lue éveillée juste après un branchement (elle a redémarré) : stable, où qu'elle soit.
        case boot
    }

    private struct Settle {
        let kind: SettleKind
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
    /// Lectures de l'état réel ratées depuis le dernier ordre natif.
    private var readFailures = 0
    /// Un `privacy on` a répondu : la lecture qui suit dit s'il a pris.
    private var awaitingConfirmation = false
    private var tilt: Tilt = .none
    /// Sortie : réveil constaté (lecture `run`).
    private var awake = false
    /// La caméra vient peut-être de quitter le mode natif (lue éveillée alors qu'elle pouvait y être) ou de redémarrer :
    /// elle bouge d'elle-même, et aucun ordre de position ne part avant qu'elle soit stable.
    private var rising: SettleKind?
    /// Branchement avec une caméra peut-être en mode natif : si la première lecture la trouve éveillée, elle a redémarré.
    private var booting = false
    /// Au branchement en mode natif possible, la coupure du suivi IA attend que la caméra soit vue éveillée : une
    /// coupure pendant le mode natif pourrait la réveiller (essai de banc 3).
    private var pendingTake = false
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
            // Une coupure du suivi pendant le mode natif a pu réveiller la caméra (essai de banc 3) : l'état est relu.
            real = nil
            readFailures = 0
            reconcile()
            return
        }
        guard !mayBeNative else { return }
        switch step {
        case .settling where settle?.kind == .tilt:
            // Le suivi a pu détourner l'objectif pendant l'attente : l'inclinaison est renvoyée, l'attente reprend.
            if sendTilt() {
                startSettle(.tilt)
            }
        case .idle, .verifying:
            // Protection par l'inclinaison : le suivi a pu remonter l'objectif pendant la coupure (spec § 6.5).
            guard tilt != .none, protectsByTiltOnly else { return }
            tilt = .none
            reconcile(interrupt: true)
        case .order, .pause, .settling:
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
    /// est réappliquée et une sortie en cours reprend, d'après l'état réel relu si la caméra peut être en mode natif.
    public func cameraPresenceChanged(_ present: Bool) {
        defer { changed() }
        real = nil
        tilt = .none
        awake = false
        rising = nil
        booting = false
        attempts = 0
        readFailures = 0
        gaveUp = false
        awaitingConfirmation = false
        // Un utilitaire d'avant la V2 l'est peut-être encore : la prochaine réponse le dira.
        updating = false
        requester = nil
        lastTarget = nil
        pendingTake = false
        guard present, isActive else { return }
        if wanted {
            if runner.supportsNativePrivacy && mayBeNative {
                // Peut-être déjà en mode natif : l'état réel d'abord, et la coupure du suivi IA seulement une fois la
                // caméra vue éveillée.
                control.forget()
                pendingTake = true
                booting = true
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
        awaitingConfirmation = false
        // Une session neuve du SDK a pu réveiller la caméra (essai de banc 3).
        if real == .privacy {
            real = nil
        }
        // Une attente de position interrompue reprend à la prochaine étape (`tilt`, `awake` et `rising` sont gardés).
        guard camera.isPresent, isActive else { return }
        reconcile(interrupt: true)
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
        // Le suivi IA ramènerait l'objectif vers la personne.
        if control.mayBeTracking {
            control.take()
        }
        guard !wanted else {
            // Déjà voulue : rien de neuf, sinon une vérification de l'inclinaison relancée.
            reconcile(interrupt: true)
            return nil
        }
        wanted = true
        attempts = 0
        gaveUp = false
        awaitingConfirmation = false
        if isActive {
            // Une sortie est en cours : elle s'arrête à la prochaine étape et repart vers la vie privée. `saved` reste la
            // position d'avant la vie privée.
            persist()
            reconcile(interrupt: true)
            return nil
        }
        // Entrée demandée : la seule qui écrit `saved`.
        try? motion.stop()
        zoom.cancelPending()
        saved = motion.position.map { SavedPosition(pan: $0.pan, tilt: $0.tilt, zoom: zoom.value) }
        isActive = true
        tilt = .none
        rising = nil
        readFailures = 0
        if !runner.supportsNativePrivacy {
            // Sans utilitaire, la caméra ne peut pas être en mode natif par ptzd.
            mayBeNative = false
        }
        persist()
        if !mayBeNative {
            // Protection immédiate : l'inclinaison part tout de suite (spec § 6.5).
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
                    return failure(error)
                }
                log("Inclinaison de la vie privée refusée (\(error)) : le mode natif protégera l'image.")
                tilt = .placed
            }
        }
        reconcile(interrupt: true)
        return nil
    }

    private func requestExit(from client: ClientID) -> (code: ErrorCode, message: String)? {
        guard isActive else { return nil }
        requester = client
        guard wanted else { return nil }
        wanted = false
        attempts = 0
        readFailures = 0
        awaitingConfirmation = false
        awake = false
        if exitsDirectly, !stepInProgress, rising == nil {
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

    /// Choisit l'étape suivante d'après l'état voulu et l'état constaté. Une étape qui va à son terme (ordre, attente de
    /// position) n'est jamais interrompue ; un délai ou une vérification l'est si `interrupt` (nouveau choix).
    private func reconcile(interrupt: Bool = false) {
        switch step {
        case .order, .settling:
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
            // l'échec annoncé. Après un réveil, l'inclinaison sera remise.
            attempts = 0
            gaveUp = false
            lastTarget = nil
            tilt = .none
            return
        }
        if mayBeNative && real == nil {
            readUnknownState()
            return
        }
        // Ici, la caméra n'est pas en mode natif : lue éveillée ou en veille, ou jamais mise en mode natif.
        if pendingTake {
            pendingTake = false
            control.take()
        }
        if let rising {
            // Elle vient peut-être d'en sortir, ou de redémarrer : qu'elle soit stable d'abord (un seul pilote).
            startSettle(rising)
            return
        }
        if updating || gaveUp {
            protectByTilt()
            return
        }
        switch tilt {
        case .none:
            if sendTilt() {
                startSettle(.tilt)
            } else {
                // Inclinaison refusée : le mode natif protégera l'image.
                tilt = .placed
                sendPrivacyOn()
            }
        case .sent:
            startSettle(.tilt)
        case .placed:
            sendPrivacyOn()
        }
    }

    /// L'état réel est inconnu alors que la caméra peut être en mode natif : on le lit, sans aucun ordre de position.
    /// Après un essai natif dont la lecture a raté, ou deux lectures ratées, un nouvel ordre natif (sans effet si la
    /// caméra y est déjà) ; une fois les essais épuisés, des relectures espacées jusqu'à une réponse.
    private func readUnknownState() {
        if updating {
            // Un utilitaire d'avant la V2 ne sait pas lire l'état : on attend sa recompilation, sans ordre de position.
            return
        }
        if readFailures == 0 {
            issue(.status)
            return
        }
        guard attempts > 0 || readFailures >= Self.maxAttempts else {
            pause(Self.retryDelay) { $0.issue(.status) }
            return
        }
        if attempts < Self.maxAttempts {
            pause(Self.retryDelay) { $0.sendPrivacyOn() }
            return
        }
        giveUp()
        let delay = Self.readBackoff[min(readFailures - 1, Self.readBackoff.count - 1)]
        pause(delay) { $0.issue(.status) }
    }

    private func advanceExit() {
        if awake || exitsDirectly {
            // Réveil constaté : la fin de sa remontée propre, puis seulement la position mémorisée.
            if let rising {
                startSettle(rising)
            } else {
                finishExit()
            }
            return
        }
        if updating {
            // Un utilitaire d'avant la V2 ne peut pas réveiller une caméra peut-être en mode natif.
            exitFailed()
            return
        }
        if attempts == 0 {
            sendPrivacyOff()
            return
        }
        if real == nil && readFailures == 0 {
            issue(.status)
            return
        }
        // Le dernier essai n'a pas réveillé la caméra (lue en vie privée ou en veille), ou son état ne se lit pas.
        if attempts < Self.maxAttempts {
            pause(Self.retryDelay) { $0.sendPrivacyOff() }
            return
        }
        exitFailed()
    }

    // MARK: - Ordres natifs

    private func sendPrivacyOn() {
        let before = Known(real: real, mayBeNative: mayBeNative)
        attempts += 1
        readFailures = 0
        awaitingConfirmation = false
        // La vérification du § 6.5 s'arrête : la caméra va gérer seule sa position.
        lastTarget = nil
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
        step = .order
        switch order {
        case .on, .off:
            let before = before ?? Known(real: real, mayBeNative: mayBeNative)
            real = nil
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
            // obsbot-ai d'avant la V2 : rien n'a été fait, la caméra n'a pas bougé (spec § 6.5 bis).
            log("obsbot-ai ne connaît pas la vie privée native : protection à −70° en attendant sa recompilation.")
            updating = true
            attempts -= 1
            real = before.real
            setMayBeNative(before.mayBeNative)
            if order == .off, !mayBeNative {
                // Cet utilitaire n'a jamais mis la caméra en mode natif : elle est éveillée.
                awake = true
                rising = .wake
            }
        } else {
            if result != .success {
                log("obsbot-ai privacy \(order == .on ? "on" : "off") : \(result) ; l'état réel est relu.")
            }
            awaitingConfirmation = order == .on
        }
        reconcile()
    }

    private func read(_ reading: PrivacyReading) {
        switch reading {
        case let .state(state):
            readFailures = 0
            real = state
            // Lue hors du mode natif alors qu'elle pouvait y être : elle en sort peut-être, et remonte d'elle-même ;
            // juste après un branchement, elle a plutôt redémarré.
            if mayBeNative, state != .privacy {
                rising = booting ? .boot : .wake
            }
            booting = false
            setMayBeNative(state == .privacy)
            if wanted {
                if awaitingConfirmation, state != .privacy {
                    // L'essai n'a pas pris : la caméra peut avoir bougé, l'inclinaison est remise avant le suivant.
                    log("Vie privée native non constatée (état réel : \(state.rawValue)), essai \(attempts)/\(Self.maxAttempts).")
                    tilt = .none
                    if attempts >= Self.maxAttempts {
                        giveUp()
                    }
                }
            } else if state == .run {
                awake = true
                // La sortie attend toujours la fin de la remontée propre (spec § 6.5 bis, sortie, étape 2).
                rising = .wake
            }
            awaitingConfirmation = false
        case .failed(.unknownOrder):
            log("obsbot-ai ne sait pas lire l'état de la caméra : en attente de sa recompilation.")
            updating = true
        case let .failed(result):
            readFailures += 1
            log("État réel de la caméra illisible (\(result)).")
        }
        reconcile()
    }

    /// L'entrée a épuisé ses essais : la protection à −70° seule, et l'avertissement au client qui l'a demandée.
    private func giveUp() {
        guard !gaveUp else { return }
        gaveUp = true
        log("Vie privée native impossible après \(Self.maxAttempts) essais : l'objectif reste détourné.")
        if let requester {
            onClientError?(requester, .uvcFailed, PrivacyFailureText.fallbackToTilt)
        }
    }

    /// La caméra ne s'est pas réveillée après deux essais : la vie privée reste en vigueur, l'erreur est montrée, et
    /// le réconciliateur la ramène vers un état sûr (mode natif confirmé, ou protection à −70°).
    private func exitFailed() {
        log("La vie privée n'a pas pu être levée (état réel : \(real?.rawValue ?? "illisible")) : elle reste en vigueur.")
        if let requester {
            onClientError?(requester, .uvcFailed, PrivacyFailureText.exitFailed)
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
        case .order, .settling: true
        case .idle, .pause, .verifying: false
        }
    }

    /// La protection par l'inclinaison seule : l'objectif à −70°, vérifié et renvoyé sans fin (spec § 6.5).
    private func protectByTilt() {
        guard !mayBeNative else { return }
        if tilt == .none {
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

    /// Le seul ordre de position de la vie privée : jamais quand la caméra peut être en mode natif.
    private func sendTiltOrThrow() throws {
        guard !mayBeNative else {
            log("Inclinaison retenue : la caméra peut être en mode natif.")
            return
        }
        let target = PanTiltPosition(pan: saved?.pan ?? 0, tilt: Self.privacyTilt)
        lastTarget = target
        tilt = .sent
        try camera.setPanTiltAbsolute(panDegrees: target.pan, tiltDegrees: target.tilt)
    }

    /// Attente que la caméra soit stable près de −70° : avant le mode natif (elle y va sur notre ordre), ou après le
    /// réveil (elle revient d'elle-même à la position qu'elle avait en entrant en mode natif, −70°). Passé le délai
    /// maximal, la séquence continue.
    private func startSettle(_ kind: SettleKind) {
        stopStep()
        let limit = kind == .tilt ? Self.tiltWaitLimit : Self.riseWaitLimit
        settle = Settle(kind: kind, deadline: scheduler.now + limit, previous: nil)
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
        if stable && (onTarget || current.kind == .boot) {
            finishSettle(current, onTarget: onTarget)
        } else if scheduler.now >= current.deadline {
            let what = switch current.kind {
            case .tilt: "Inclinaison de la vie privée"
            case .wake: "Remontée de la caméra"
            case .boot: "Redémarrage de la caméra"
            }
            log("\(what) non stabilisée à temps (relue \(position.map { "\($0)" } ?? "illisible")) : la séquence continue.")
            finishSettle(current, onTarget: onTarget)
        } else {
            current.previous = position
            settle = current
            scheduleSettleRead(after: Self.pollInterval)
        }
        changed()
    }

    private func finishSettle(_ finished: Settle, onTarget: Bool) {
        settle = nil
        step = .idle
        if finished.kind == .tilt {
            tilt = .placed
        } else {
            rising = nil
            zoom.refresh()
            // Revenue à −70° (sa position en entrant en mode natif) : l'inclinaison est déjà en place.
            tilt = onTarget ? .placed : .none
        }
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
            log("Position d'avant la vie privée refusée par la caméra : \(error). La vie privée reste en vigueur.")
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
        isActive = false
        saved = nil
        mayBeNative = false
        real = nil
        tilt = .none
        attempts = 0
        readFailures = 0
        awake = false
        rising = nil
        requester = nil
        pendingTake = false
        persist()
        startVerification()
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

    private func pause(_ delay: TimeInterval, then action: @escaping @MainActor @Sendable (PrivacyReconciler) -> Void) {
        stopStep()
        step = .pause
        timer = scheduler.schedule(after: delay) { [weak self] in
            guard let self, case .pause = step else { return }
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
            try store.save(PersistedState(privacy: isActive, saved: saved, native: mayBeNative))
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
}
