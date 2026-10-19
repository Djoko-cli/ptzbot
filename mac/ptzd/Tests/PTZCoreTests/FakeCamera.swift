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
    /// Les ordres en vitesse sont refusés tant que c'est vrai.
    var refuseRelative = false
    /// Ordres en vitesse tentés, refusés compris.
    private(set) var relativeAttempts = 0
    private(set) var relativeCommands: [PanTiltRelative] = []
    private(set) var absoluteCommands: [PanTiltPosition] = []
    private(set) var zoomCommands: [Int] = []

    func setPanTiltRelative(_ command: PanTiltRelative) throws {
        relativeAttempts += 1
        if refuseRelative, isPresent {
            throw CameraError.ioKit(-536870212)
        }
        try checkWrite()
        relativeCommands.append(command)
    }

    func setPanTiltAbsolute(panDegrees: Double, tiltDegrees: Double) throws {
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
        try checkWrite()
        zoomCommands.append(value)
        zoomValue = value
    }

    func readPanTilt() throws -> PanTiltPosition {
        guard isPresent else { throw CameraError.absent }
        if failReads {
            throw CameraError.ioKit(-536870212)
        }
        return position
    }

    func readZoom() throws -> Int {
        guard isPresent else { throw CameraError.absent }
        return zoomValue
    }

    private func checkWrite() throws {
        guard isPresent else { throw CameraError.absent }
        if let failure = failNextWrite {
            failNextWrite = nil
            throw failure
        }
    }
}
