import Foundation
import NacelleProtocol

/// Point d'entrée de la logique : traite les messages de l'app, suit la
/// présence de la caméra et publie l'état (spec § 5 et § 6).
@MainActor
public final class PTZController {
    /// Délai avant de relire la position après un déplacement absolu : relue
    /// trop tôt, la caméra renvoie une valeur fausse (spec § 10, question 1).
    public static let settleDelay: TimeInterval = 2
    /// Écart toléré entre l'ordre absolu et la position relue (la relecture peut différer d'1°).
    public static let positionTolerance: Double = 3
    /// Renvois au plus d'un ordre absolu ignoré par la caméra, hors vie privée.
    public static let maxResends = 2
    /// En vie privée, la vérification ne s'arrête jamais : délais avant chaque nouvelle
    /// vérification après un renvoi, le dernier se répétant indéfiniment.
    public static let privacyBackoff: [TimeInterval] = [2, 5, 10, 30]

    public private(set) var snapshot: StateSnapshot
    /// Appelé à chaque changement d'état, pour diffusion à tous les clients.
    public var onStateChange: ((StateSnapshot) -> Void)?
    /// Erreur à transmettre plus tard à ce client (ordre de suivi IA échoué).
    public var onClientError: ((ClientID, ErrorCode, String) -> Void)?

    private let camera: any CameraDevice
    private let scheduler: any Scheduler
    private let motion: MotionDriver
    private let zoom: ZoomDriver
    private let privacy: PrivacyKeeper
    private let control: ControlTaker
    /// Vie privée native de la caméra, par l'utilitaire du suivi IA (spec § 6.5 bis).
    private let native: NativePrivacy
    private let log: LogSink
    private var settle: (any Cancellable)?
    private var verifyTarget = false
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
        self.scheduler = scheduler
        self.log = log
        motion = MotionDriver(camera: camera, scheduler: scheduler, settings: settings, log: log)
        zoom = ZoomDriver(camera: camera, scheduler: scheduler, log: log)
        privacy = PrivacyKeeper(camera: camera, store: store, log: log)
        let control = ControlTaker(runner: ai, scheduler: scheduler, isObsbotCenterRunning: isObsbotCenterRunning, log: log)
        self.control = control
        // L'utilitaire ne traite qu'un ordre à la fois, et la coupure du suivi IA passe avant la vie privée.
        native = NativePrivacy(runner: ai, scheduler: scheduler, canRun: { control.state != .taking }, log: log)
        snapshot = StateSnapshot(
            camera: camera.isPresent ? .connected : .absent,
            control: .idle,
            privacy: privacy.isActive,
            pan: nil, tilt: nil, zoom: nil,
            moving: false,
            privacyMode: privacy.isActive ? privacy.mode : nil
        )
        motion.onChange = { [weak self] in self?.publish() }
        zoom.onChange = { [weak self] in self?.publish() }
        privacy.onChange = { [weak self] in self?.publish() }
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
            verifyTarget = false
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
            // Une bascule native est en cours : la demande suivante n'a rien à ajouter, sauf une sortie pendant une
            // entrée (ou une réapplication), qui l'annule.
            if native.isBusy {
                guard !on, native.pendingOn == true else { return nil }
                native.cancel()
            }
            if on {
                // Le suivi IA ramènerait l'objectif vers la personne.
                if control.mayBeTracking {
                    control.take()
                }
                return attempt {
                    try? motion.stop()
                    guard !privacy.isActive else {
                        refreshAfterSettling()
                        return
                    }
                    // Sans SDK (pas d'utilitaire), l'inclinaison d'emblée (spec § 6.5 bis).
                    let mode: PrivacyMode = native.isAvailable ? .native : .tilt
                    try privacy.enter(currentPosition: motion.position, currentZoom: zoom.value, mode: mode)
                    if mode == .native {
                        applyNative(requester: client)
                    } else {
                        refreshAfterSettling()
                    }
                }
            }
            return attempt {
                if privacy.isActive, privacy.mode == .native {
                    leaveNative(requester: client)
                    return
                }
                try privacy.exit()
                refreshAfterSettling()
            }
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

    /// Branchement ou débranchement de la caméra. Au branchement, la vie privée
    /// est réappliquée et le suivi IA recoupé, au cas où la caméra aurait redémarré.
    public func cameraPresenceChanged(_ present: Bool) {
        // Un ordre de vie privée native en cours ne vaut plus : le rebranchement réapplique la vie privée.
        native.cancel()
        // Le SDK gardé par l'utilitaire du suivi IA ne connaît plus la caméra : session neuve au prochain ordre.
        control.reset()
        if present {
            log("Caméra branchée.")
            motion.refreshPosition()
            zoom.refresh()
            if privacy.isActive {
                // La coupure du suivi part avant : la vie privée native attend sa fin (l'utilitaire ne traite qu'un ordre à la fois).
                control.take()
                reapplyPrivacy()
            } else {
                // La caméra a pu redémarrer avec son propre réglage : le dernier ordre ne vaut plus.
                control.forget()
            }
        } else {
            log("Caméra débranchée.")
            settle?.cancel()
            settle = nil
            verifyTarget = false
            motion.reset()
            zoom.reset()
        }
        publish()
    }

    /// Fin de la coupure du suivi IA en vie privée : sur une caméra qui démarre,
    /// obsbot-ai off a pu tourner en même temps que la première réapplication.
    private func controlChanged() {
        let previous = lastControl
        lastControl = control.state
        if previous == .taking, control.state != .taking, privacy.isActive, camera.isPresent {
            // En `native`, la caméra se gère seule (spec § 6.5 bis) : enforce() n'y fait rien.
            do {
                try privacy.enforce()
                if privacy.mode == .tilt {
                    refreshAfterSettling()
                }
            } catch {
                log("Vie privée non réappliquée après la coupure du suivi IA : \(error)")
            }
        }
        // L'utilitaire est libre : un ordre de vie privée native qui attendait peut partir.
        if control.state != .taking {
            native.resume()
        }
        publish()
    }

    // MARK: - Vie privée native (spec § 6.5 bis)

    /// Réapplique la vie privée retenue (démarrage, rebranchement). Avec le SDK, le mode natif est (re)tenté : un `tilt`
    /// subi par repli garde l'objectif détourné pendant ce temps. Sans SDK, l'inclinaison.
    private func reapplyPrivacy() {
        if native.isAvailable {
            if privacy.mode == .tilt {
                reapplyTilt()
            }
            applyNative(requester: nil)
        } else {
            if privacy.mode == .native {
                log("Vie privée native impossible (utilitaire obsbot-ai absent) : repli sur l'inclinaison de l'objectif.")
            }
            reapplyTilt()
        }
    }

    /// L'objectif est renvoyé vers le bas ; un mode `native` devient `tilt`.
    private func reapplyTilt() {
        do {
            if privacy.mode == .native {
                try privacy.fallBackToTilt()
            } else {
                try privacy.enforce()
            }
            refreshAfterSettling()
        } catch {
            log("Vie privée non réappliquée : \(error)")
        }
    }

    /// Lance `privacy on` (avec son second essai). Réussi : le mode est `native`. Échoué deux fois : repli sur `tilt` avec
    /// avertissement au client qui a demandé la vie privée, et dans le journal ; un `tilt` déjà en place y reste.
    private func applyNative(requester client: ClientID?) {
        if privacy.mode == .native {
            // Plus rien à vérifier : la caméra gère elle-même sa position. Un `tilt` à réappliquer garde sa vérification.
            settle?.cancel()
            settle = nil
            verifyTarget = false
        }
        native.apply(on: true) { [weak self] result in
            guard let self, privacy.isActive else { return }
            if result == .success {
                privacy.promoteToNative()
                refreshPositionAfterSettling()
                return
            }
            guard privacy.mode == .native else {
                log("Vie privée native toujours impossible (\(result.userDescription)) : l'objectif reste détourné.")
                return
            }
            log("Vie privée native impossible (\(result.userDescription)) : repli sur l'inclinaison de l'objectif.")
            if let client {
                onClientError?(client, .uvcFailed, PrivacyFailureText.fallbackToTilt)
            }
            reapplyTilt()
        }
    }

    /// Lance `privacy off` (avec son second essai). Réussi : la caméra a repris seule sa position, ptzd la relit. Échoué
    /// deux fois : la vie privée reste active et l'erreur est montrée.
    private func leaveNative(requester client: ClientID) {
        native.apply(on: false) { [weak self] result in
            guard let self, privacy.isActive else { return }
            guard result == .success else {
                log("La vie privée native n'a pas pu être levée (\(result.userDescription)) : elle reste active.")
                onClientError?(client, .uvcFailed, PrivacyFailureText.exitFailed)
                return
            }
            try? privacy.exit()
            refreshPositionAfterSettling()
        }
    }

    /// Relit la position et le zoom après le délai habituel, sans rien comparer ni renvoyer : en mode natif, la caméra
    /// gère elle-même sa position.
    private func refreshPositionAfterSettling() {
        verifyTarget = false
        settle?.cancel()
        settle = scheduler.schedule(after: Self.settleDelay) { [weak self] in
            guard let self else { return }
            self.settle = nil
            self.motion.refreshPosition()
            self.zoom.refresh()
        }
    }

    /// Relit la position après `delay`, puis la compare à la cible. `resends` compte
    /// les renvois déjà faits pour cette cible.
    private func refreshAfterSettling(resends: Int = 0, delay: TimeInterval = PTZController.settleDelay) {
        verifyTarget = true
        settle?.cancel()
        settle = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.settle = nil
            self.motion.refreshPosition()
            self.zoom.refresh()
            self.checkTargetReached(resends: resends)
        }
    }

    /// La caméra ignore parfois un ordre absolu en renvoyant un succès : on compare la
    /// position relue à la cible et on renvoie l'ordre. Hors vie privée, au plus
    /// maxResends fois ; en vie privée, jusqu'à ce que le tilt soit atteint.
    private func checkTargetReached(resends: Int) {
        guard verifyTarget, let target = privacy.lastTarget else { return }
        // Mode natif : la caméra gère elle-même sa position (spec § 6.5 bis), rien à vérifier ni à renvoyer.
        if privacy.isActive, privacy.mode == .native {
            verifyTarget = false
            return
        }
        let position = motion.position
        if let position {
            // En vie privée, seul le tilt protège l'image ; à -70° la caméra relit d'ailleurs
            // un pan décalé (constaté le 2026-10-05). Hors vie privée, les deux axes comptent.
            let panReached = privacy.isActive || abs(position.pan - target.pan) <= Self.positionTolerance
            if panReached && abs(position.tilt - target.tilt) <= Self.positionTolerance {
                verifyTarget = false
                if resends > Self.maxResends {
                    log("Position atteinte après \(resends) renvois : relue \(position).")
                }
                return
            }
        } else if !privacy.isActive {
            // Position illisible hors vie privée : rien à comparer.
            verifyTarget = false
            return
        }
        let seen = position.map { "\($0)" } ?? "illisible"
        if privacy.isActive {
            retryPrivacy(target: target, seen: seen, resends: resends)
            return
        }
        guard resends < Self.maxResends else {
            verifyTarget = false
            log("Position non atteinte après \(Self.maxResends) renvois : cible \(target), relue \(seen).")
            return
        }
        log("Ordre absolu ignoré par la caméra (cible \(target), relue \(seen)) : nouvel envoi.")
        do {
            try privacy.resendLastTarget()
            refreshAfterSettling(resends: resends + 1)
        } catch {
            verifyTarget = false
            log("Nouvel envoi refusé : \(error)")
        }
    }

    /// Vie privée : renvoi puis nouvelle vérification après 2, 5, 10, puis toutes les 30 s,
    /// sans jamais abandonner. Une ligne de journal par palier au plus.
    private func retryPrivacy(target: PanTiltPosition, seen: String, resends: Int) {
        let stage = min(resends, Self.privacyBackoff.count - 1)
        let delay = Self.privacyBackoff[stage]
        let logged = resends < Self.privacyBackoff.count
        if logged {
            let next = stage == Self.privacyBackoff.count - 1 ? "toutes les \(Int(delay)) s" : "dans \(Int(delay)) s"
            log("Ordre de vie privée ignoré par la caméra (cible \(target), relue \(seen)) : nouvel envoi, vérification \(next).")
        }
        do {
            try privacy.resendLastTarget()
        } catch CameraError.absent {
            // Le débranchement est traité par cameraPresenceChanged ; le rebranchement réapplique.
            verifyTarget = false
            return
        } catch {
            if logged {
                log("Nouvel envoi refusé : \(error). Nouvel essai quand même.")
            }
        }
        refreshAfterSettling(resends: resends + 1, delay: delay)
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
            privacyMode: privacy.isActive ? privacy.mode : nil
        )
        guard next != snapshot else { return }
        snapshot = next
        onStateChange?(next)
    }
}
