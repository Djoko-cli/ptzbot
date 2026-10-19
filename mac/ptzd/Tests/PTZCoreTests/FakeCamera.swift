import Testing
@testable import PTZCore

/// Caméra simulée : enregistre les commandes, peut échouer sur demande.
@MainActor
final class FakeCamera: CameraDevice {
    var isPresent = true
    var position = PanTiltPosition(pan: 2, tilt: -1)
    var zoomValue = 33
    /// La prochaine écriture échoue avec cette erreur.
    var failNextWrite: CameraError?
    /// Nombre d'ordres absolus à « ignorer » : enregistrés, mais sans effet sur la position.
    var ignoreAbsoluteCommands = 0
    /// Les relectures de position échouent tant que c'est vrai.
    var failReads = false
    /// Les relectures de position rendent cette valeur au lieu de la vraie (relecture UVC périmée).
    var staleRead: PanTiltPosition?
    /// Les ordres en vitesse sont refusés tant que c'est vrai.
    var refuseRelative = false
    /// Ordres en vitesse tentés, refusés compris.
    private(set) var relativeAttempts = 0
    private(set) var relativeCommands: [PanTiltRelative] = []
    private(set) var absoluteCommands: [PanTiltPosition] = []
    private(set) var zoomCommands: [Int] = []
    /// L'invariant des faux (spec § 6.5 bis, « un seul pilote de la position ») : la caméra dit si elle gère seule sa
    /// position (mode natif, bascule, remontée propre). Un ordre UVC qui part alors fait échouer le test, sauf si la
    /// caméra a été rebranchée entre-temps (`FakeAIRunner.powerCycle` la remet éveillée et droite). Posé par
    /// `FakeAIRunner.attach`.
    var drivesItsOwnPosition: (@MainActor () -> Bool)?

    func setPanTiltRelative(_ command: PanTiltRelative) throws {
        relativeAttempts += 1
        checkSingleDriver("ordre en vitesse \(command)")
        if refuseRelative, isPresent {
            throw CameraError.ioKit(-536870212)
        }
        try checkWrite()
        relativeCommands.append(command)
    }

    func setPanTiltAbsolute(panDegrees: Double, tiltDegrees: Double) throws {
        checkSingleDriver("ordre absolu \(panDegrees)° / \(tiltDegrees)°")
        try checkWrite()
        let target = PanTiltPosition(pan: panDegrees, tilt: tiltDegrees)
        absoluteCommands.append(target)
        if ignoreAbsoluteCommands > 0 {
            ignoreAbsoluteCommands -= 1
            return
        }
        position = target
    }

    func setZoom(_ value: Int) throws {
        checkSingleDriver("zoom \(value)")
        try checkWrite()
        zoomCommands.append(value)
        zoomValue = value
    }

    func readPanTilt() throws -> PanTiltPosition {
        guard isPresent else { throw CameraError.absent }
        if failReads {
            throw CameraError.ioKit(-536870212)
        }
        return staleRead ?? position
    }

    func readZoom() throws -> Int {
        guard isPresent else { throw CameraError.absent }
        return zoomValue
    }

    private func checkSingleDriver(_ order: String, sourceLocation: SourceLocation = #_sourceLocation) {
        if isPresent, drivesItsOwnPosition?() == true {
            Issue.record("Un seul pilote : \(order) envoyé pendant que la caméra gère seule sa position (mode natif, bascule ou remontée)", sourceLocation: sourceLocation)
        }
    }

    private func checkWrite() throws {
        guard isPresent else { throw CameraError.absent }
        if let failure = failNextWrite {
            failNextWrite = nil
            throw failure
        }
    }
}
