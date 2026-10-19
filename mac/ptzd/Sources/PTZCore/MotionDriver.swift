import Foundation

/// Mouvement en vitesse, avec arrêt automatique et relecture de la position (spec § 6.2).
@MainActor
public final class MotionDriver {
    /// Délai sans message `move` au bout duquel le mouvement s'arrête.
    public static let deadManDelay: TimeInterval = 0.3
    /// Période de relecture de la position pendant un mouvement.
    public static let pollInterval: TimeInterval = 1.0

    public private(set) var isMoving = false
    public private(set) var position: PanTiltPosition?
    /// Appelé quand `isMoving` ou `position` change.
    public var onChange: (() -> Void)?

    private let camera: any CameraDevice
    private let scheduler: any Scheduler
    private let settings: MotionSettings
    private let log: LogSink
    private var lastSent = PanTiltRelative.stop
    private var lastMover: ClientID?
    private var deadMan: (any Cancellable)?
    private var poll: (any Cancellable)?

    public init(camera: any CameraDevice, scheduler: any Scheduler, settings: MotionSettings, log: @escaping LogSink) {
        self.camera = camera
        self.scheduler = scheduler
        self.settings = settings
        self.log = log
    }

    /// Applique une consigne de vitesse. `0,0` arrête tout de suite.
    public func move(pan: Double, tilt: Double, from client: ClientID) throws {
        lastMover = client
        let command = SpeedCurve.command(pan: pan, tilt: tilt, settings: settings)
        guard command != .stop else {
            try stop()
            return
        }
        if command != lastSent {
            try camera.setPanTiltRelative(command)
            lastSent = command
        }
        deadMan?.cancel()
        deadMan = scheduler.schedule(after: Self.deadManDelay) { [weak self] in
            self?.deadManFired()
        }
        if !isMoving {
            isMoving = true
            schedulePoll()
            onChange?()
        }
    }

    /// Arrête le mouvement puis relit la position. Un arrêt refusé par la caméra
    /// est retenté toutes les 0,3 s ; le mouvement reste signalé tant qu'il n'a pas réussi.
    public func stop() throws {
        deadMan?.cancel()
        deadMan = nil
        if lastSent != .stop {
            do {
                try camera.setPanTiltRelative(.stop)
            } catch {
                scheduleStopRetry()
                throw error
            }
            lastSent = .stop
        }
        poll?.cancel()
        poll = nil
        let wasMoving = isMoving
        isMoving = false
        refreshPosition()
        if wasMoving {
            onChange?()
        }
    }

    /// N'essaie plus l'arrêt refusé : la caméra va passer en mode natif, où aucun ordre UVC ne doit partir
    /// (spec § 6.5 bis, relecture m6).
    public func cancelStopRetry() {
        deadMan?.cancel()
        deadMan = nil
    }

    /// Arrête le mouvement si ce client était le dernier à piloter.
    public func clientDisconnected(_ client: ClientID) {
        guard client == lastMover else { return }
        lastMover = nil
        do {
            try stop()
        } catch {
            log("Arrêt à la déconnexion impossible : \(error). Nouvel essai dans 0,3 s.")
        }
    }

    /// Relit la position ; publie si elle a changé. Une relecture ratée la rend
    /// inconnue (nil) : la vérification de la vie privée ne compare jamais une valeur périmée.
    public func refreshPosition() {
        let read = try? camera.readPanTilt()
        guard read != position else { return }
        position = read
        onChange?()
    }

    /// Oublie tout (caméra débranchée).
    public func reset() {
        deadMan?.cancel()
        deadMan = nil
        poll?.cancel()
        poll = nil
        lastSent = .stop
        lastMover = nil
        let changed = isMoving || position != nil
        isMoving = false
        position = nil
        if changed {
            onChange?()
        }
    }

    private func deadManFired() {
        deadMan = nil
        do {
            try stop()
        } catch {
            log("Arrêt automatique impossible : \(error). Nouvel essai dans 0,3 s.")
        }
    }

    private func scheduleStopRetry() {
        deadMan = scheduler.schedule(after: Self.deadManDelay) { [weak self] in
            self?.deadManFired()
        }
    }

    private func schedulePoll() {
        poll = scheduler.schedule(after: Self.pollInterval) { [weak self] in
            self?.pollTick()
        }
    }

    private func pollTick() {
        guard isMoving else { return }
        refreshPosition()
        schedulePoll()
    }
}
