import NacelleProtocol

/// Mode vie privée : position mémorisée, et soit l'objectif tourné vers le bas (`tilt`, spec § 6.5), soit le mode
/// natif de la caméra (`native`, spec § 6.5 bis). Le mode natif se commande par obsbot-ai, hors de cette classe :
/// ici, il ne fait que se retenir et laisser la caméra seule.
@MainActor
public final class PrivacyKeeper {
    /// Objectif vers le bas. -70° est obéi exactement ; la caméra ignore -90° (mesuré le 2026-10-05).
    public static let privacyTilt: Double = -70

    public private(set) var isActive: Bool
    /// Mode retenu dans state.json ; sans effet hors vie privée.
    public private(set) var mode: PrivacyMode
    /// Appelé quand `isActive` change.
    public var onChange: (() -> Void)?
    /// Dernier ordre absolu envoyé (entrée, sortie ou réapplication), pour vérifier qu'il a été suivi.
    public private(set) var lastTarget: PanTiltPosition?

    private let camera: any CameraDevice
    private let store: any StateStore
    private let log: LogSink
    private var saved: SavedPosition?

    public init(camera: any CameraDevice, store: any StateStore, log: @escaping LogSink) {
        self.camera = camera
        self.store = store
        self.log = log
        let persisted = store.load()
        isActive = persisted.privacy
        saved = persisted.saved
        mode = persisted.mode
    }

    /// Mémorise la position (nil si inconnue) et enregistre. En `tilt`, tourne ensuite l'objectif vers le bas ; si la
    /// caméra refuse, l'enregistrement est annulé et l'erreur remonte. En `native`, la caméra n'est pas touchée : le
    /// mode natif l'est ensuite par obsbot-ai, et la vie privée est déjà retenue (une coupure de ptzd en cours de route
    /// la réapplique).
    public func enter(currentPosition: PanTiltPosition?, currentZoom: Int?, mode newMode: PrivacyMode = .tilt) throws {
        guard !isActive else { return }
        let savedNow = currentPosition.map { SavedPosition(pan: $0.pan, tilt: $0.tilt, zoom: currentZoom) }
        persist(PersistedState(privacy: true, saved: savedNow, mode: newMode))
        if newMode == .tilt {
            do {
                try camera.setPanTiltAbsolute(panDegrees: currentPosition?.pan ?? 0, tiltDegrees: Self.privacyTilt)
            } catch {
                persist(PersistedState(privacy: false, saved: nil))
                throw error
            }
            lastTarget = PanTiltPosition(pan: currentPosition?.pan ?? 0, tilt: Self.privacyTilt)
        } else {
            lastTarget = nil
        }
        saved = savedNow
        mode = newMode
        isActive = true
        onChange?()
    }

    /// Le mode natif a échoué deux fois : repli sur l'inclinaison (spec § 6.5 bis). Le mode est retenu d'abord, pour
    /// qu'un refus de la caméra n'y change rien ; la vérification de position reprend alors le travail.
    public func fallBackToTilt() throws {
        guard isActive, mode == .native else { return }
        mode = .tilt
        persist(PersistedState(privacy: true, saved: saved, mode: .tilt))
        onChange?()
        try enforce()
    }

    /// Le mode natif a réussi alors que la vie privée tenait par l'inclinaison (réapplication d'un repli).
    public func promoteToNative() {
        guard isActive, mode == .tilt else { return }
        mode = .native
        lastTarget = nil
        persist(PersistedState(privacy: true, saved: saved, mode: .native))
        onChange?()
    }

    /// Rétablit la vie privée à la sortie. En `tilt`, remet la position mémorisée, ou 0°/0° si elle est inconnue ;
    /// si la caméra refuse, on reste en vie privée. En `native`, la caméra a déjà quitté sa vie privée et repris seule
    /// sa position : il ne reste qu'à effacer l'état.
    public func exit() throws {
        guard isActive else { return }
        if mode == .native {
            lastTarget = nil
            persist(PersistedState(privacy: false, saved: nil))
            saved = nil
            isActive = false
            onChange?()
            return
        }
        let target = saved ?? SavedPosition(pan: 0, tilt: 0, zoom: nil)
        // Zoom d'abord : si la caméra refuse, l'objectif est encore tourné vers le bas.
        if let zoom = target.zoom {
            try camera.setZoom(zoom)
        }
        try camera.setPanTiltAbsolute(panDegrees: target.pan, tiltDegrees: target.tilt)
        lastTarget = PanTiltPosition(pan: target.pan, tilt: target.tilt)
        persist(PersistedState(privacy: false, saved: nil))
        saved = nil
        isActive = false
        onChange?()
    }

    /// Renvoie l'objectif vers le bas si la vie privée est active en `tilt` (démarrage, rebranchement).
    public func enforce() throws {
        guard isActive, mode == .tilt else { return }
        try camera.setPanTiltAbsolute(panDegrees: saved?.pan ?? 0, tiltDegrees: Self.privacyTilt)
        lastTarget = PanTiltPosition(pan: saved?.pan ?? 0, tilt: Self.privacyTilt)
    }

    /// Renvoie le dernier ordre absolu : la caméra en ignore parfois un en renvoyant
    /// pourtant un succès (constaté le 2026-10-05).
    public func resendLastTarget() throws {
        guard let target = lastTarget, !(isActive && mode == .native) else { return }
        try camera.setPanTiltAbsolute(panDegrees: target.pan, tiltDegrees: target.tilt)
    }

    /// Une erreur d'écriture n'empêche pas de protéger l'image : on la journalise.
    private func persist(_ state: PersistedState) {
        do {
            try store.save(state)
        } catch {
            log("Enregistrement de state.json impossible : \(error)")
        }
    }
}
