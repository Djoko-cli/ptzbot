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

    public private(set) var snapshot: StateSnapshot
    /// Appelé à chaque changement d'état, pour diffusion à tous les clients.
    public var onStateChange: ((StateSnapshot) -> Void)?
    /// Erreur à transmettre plus tard à ce client (ordre de suivi IA échoué, vie privée native).
    public var onClientError: ((ClientID, ErrorCode, String) -> Void)?

    private let camera: any CameraDevice
    private let motion: MotionDriver
    private let zoom: ZoomDriver
    /// La vie privée : état voulu, état constaté et réconciliateur (spec § 6.5 bis).
    private let privacy: PrivacyReconciler
    private let control: ControlTaker
    private let log: LogSink
    private var lastControl: ControlState = .idle
    /// Retour audio de talkd, lu par `TalkbackWatcher` (spec parler § 5).
    private var talkback: TalkbackAvailability = .unavailable

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
        self.log = log
        // L'utilitaire ne traite qu'un ordre à la fois : la coupure du suivi IA et la vie privée native passent par la
        // même file, l'une après l'autre (spec § 6.5 bis).
        let queue = AIOrderQueue(runner: ai)
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
        snapshot = StateSnapshot(
            camera: camera.isPresent ? .connected : .absent,
            control: .idle,
            privacy: privacy.isActive,
            pan: nil, tilt: nil, zoom: nil,
            moving: false,
            privacyMode: privacy.mode,
            privacyReason: privacy.reason
        )
        motion.onChange = { [weak self] in self?.publish() }
        zoom.onChange = { [weak self] in self?.publish() }
        privacy.onChange = { [weak self] in self?.publish() }
        privacy.onClientError = { [weak self] in self?.onClientError?($0, $1, $2) }
        control.onChange = { [weak self] in self?.controlChanged() }
    }

    /// Le retour audio devient prêt ou indisponible : l'état est rediffusé si la valeur change.
    public func setTalkback(_ value: TalkbackAvailability) {
        guard value != talkback else { return }
        talkback = value
        publish()
    }

    /// Un iPhone vient de s'authentifier : prépare l'utilitaire du suivi IA avant son premier ordre.
    public func prewarmAI() {
        // Caméra absente ou vie privée : aucun ordre de suivi n'est possible, inutile de charger le SDK.
        guard camera.isPresent, !privacy.isActive else { return }
        control.prewarm()
    }

    /// PTZBot a recompilé ou réinstallé obsbot-ai (message `aiUpdated`) : l'utilitaire repart du nouveau programme, et
    /// la vie privée est réconciliée avec lui (spec § 6.5 bis).
    public func aiUpdated() {
        log("obsbot-ai mis à jour par PTZBot : utilitaire relancé.")
        privacy.abandonSession()
        control.reset()
        lastControl = control.state
        privacy.utilityUpdated()
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
            // Le suivi IA contrerait le joystick : coupé au premier mouvement, s'il n'est pas déjà coupé.
            if pan != 0 || tilt != 0, control.mayBeTracking {
                control.take()
            }
            privacy.userMoved()
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
            return privacy.request(on: on, from: client)
        case let .aiTracking(on):
            if let refusal = refusal() {
                return refusal
            }
            control.setTracking(on: on) { [weak self] result in
                guard result != .success else { return }
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
    /// la caméra peut être en mode natif) et le suivi IA recoupé, au cas où la caméra aurait redémarré.
    public func cameraPresenceChanged(_ present: Bool) {
        // Un ordre de vie privée native en cours ne vaut plus : sa réponse est écartée, l'état réel sera relu.
        privacy.abandonSession()
        // Le SDK gardé par l'utilitaire du suivi IA ne connaît plus la caméra : session neuve au prochain ordre.
        control.reset()
        lastControl = control.state
        if present {
            log("Caméra branchée.")
            if !privacy.isActive {
                motion.refreshPosition()
                zoom.refresh()
                // La caméra a pu redémarrer avec son propre réglage : le dernier ordre ne vaut plus.
                control.forget()
            }
        } else {
            log("Caméra débranchée.")
            motion.reset()
            zoom.reset()
        }
        privacy.cameraPresenceChanged(present)
        publish()
    }

    /// Fin d'une coupure du suivi IA : sur une caméra qui démarre, obsbot-ai off a pu tourner en même temps que la
    /// première réapplication de la vie privée.
    private func controlChanged() {
        let previous = lastControl
        lastControl = control.state
        if previous == .taking, control.state != .taking, camera.isPresent {
            privacy.controlFinished()
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
            privacyReason: privacy.reason
        )
        guard next != snapshot else { return }
        snapshot = next
        onStateChange?(next)
    }
}
