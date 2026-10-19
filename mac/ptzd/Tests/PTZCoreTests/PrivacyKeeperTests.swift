import NacelleProtocol
import Testing
@testable import PTZCore

@MainActor
@Suite("Vie privée")
struct PrivacyKeeperTests {
    let camera = FakeCamera()
    let store = MemoryStateStore()
    let log = LogRecorder()

    private func makeKeeper() -> PrivacyKeeper {
        PrivacyKeeper(camera: camera, store: store, log: log.sink)
    }

    @Test("Entrée : position mémorisée et enregistrée, objectif vers le bas")
    func enter() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50)
        #expect(keeper.isActive)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 30, tilt: PrivacyKeeper.privacyTilt)])
        #expect(store.state == PersistedState(privacy: true, saved: SavedPosition(pan: 30, tilt: -10, zoom: 50)))
    }

    @Test("Entrée refusée par la caméra : rien n'est activé, l'enregistrement est annulé")
    func enterFailure() {
        let keeper = makeKeeper()
        camera.failNextWrite = .ioKit(-536870212)
        #expect(throws: CameraError.ioKit(-536870212)) {
            try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50)
        }
        #expect(!keeper.isActive)
        #expect(store.state == PersistedState(privacy: false, saved: nil))
        #expect(store.saveCount == 2)
    }

    @Test("Sortie : position et zoom rétablis, état effacé")
    func exit() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50)
        try keeper.exit()
        #expect(!keeper.isActive)
        #expect(camera.absoluteCommands.last == PanTiltPosition(pan: 30, tilt: -10))
        #expect(camera.zoomCommands == [50])
        #expect(store.state == PersistedState(privacy: false, saved: nil))
    }

    @Test("Sortie refusée : on reste en vie privée")
    func exitFailure() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50)
        camera.failNextWrite = .ioKit(-536870212)
        #expect(throws: CameraError.ioKit(-536870212)) { try keeper.exit() }
        #expect(keeper.isActive)
        #expect(store.state.privacy)
    }

    @Test("Zoom refusé à la sortie : l'objectif reste tourné vers le bas")
    func exitZoomFailure() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50)
        camera.failNextWrite = .ioKit(-536870212)
        #expect(throws: CameraError.ioKit(-536870212)) { try keeper.exit() }
        #expect(keeper.isActive)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 30, tilt: PrivacyKeeper.privacyTilt)])
    }

    @Test("Position inconnue : pan 0 à l'entrée, 0°/0° à la sortie, zoom inchangé")
    func unknownPosition() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: nil, currentZoom: nil)
        try keeper.exit()
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 0, tilt: PrivacyKeeper.privacyTilt), PanTiltPosition(pan: 0, tilt: 0)])
        #expect(camera.zoomCommands.isEmpty)
    }

    @Test("Au démarrage, l'état enregistré est repris et réappliqué")
    func restoreAndEnforce() throws {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        let keeper = makeKeeper()
        #expect(keeper.isActive)
        try keeper.enforce()
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyKeeper.privacyTilt)])
    }

    @Test("enforce ne fait rien hors vie privée")
    func enforceIdle() throws {
        try makeKeeper().enforce()
        #expect(camera.absoluteCommands.isEmpty)
    }

    @Test("Un échec d'écriture du fichier n'empêche pas de protéger l'image")
    func storeFailure() throws {
        store.failSaves = true
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50)
        #expect(keeper.isActive)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 30, tilt: PrivacyKeeper.privacyTilt)])
        #expect(log.lines.count == 1)
    }

    // MARK: - Mode natif (spec § 6.5 bis)

    @Test("Entrée native : position retenue avec le mode, la caméra n'est pas touchée")
    func enterNative() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50, mode: .native)
        #expect(keeper.isActive)
        #expect(keeper.mode == .native)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(keeper.lastTarget == nil)
        #expect(store.state == PersistedState(privacy: true, saved: SavedPosition(pan: 30, tilt: -10, zoom: 50), mode: .native))
    }

    @Test("Le mode natif n'envoie ni renvoi ni réapplication à la caméra")
    func nativeSendsNothing() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50, mode: .native)
        try keeper.enforce()
        try keeper.resendLastTarget()
        #expect(camera.absoluteCommands.isEmpty)
    }

    @Test("Sortie native : la caméra reprend seule sa position, rien n'est envoyé ; l'état est effacé")
    func exitNative() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50, mode: .native)
        try keeper.exit()
        #expect(!keeper.isActive)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(camera.zoomCommands.isEmpty)
        #expect(store.state == PersistedState(privacy: false, saved: nil))
    }

    @Test("Repli sur l'inclinaison : mode retenu, objectif vers le bas à l'ancien pan, position mémorisée gardée")
    func fallBackToTilt() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50, mode: .native)
        try keeper.fallBackToTilt()
        #expect(keeper.mode == .tilt)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 30, tilt: PrivacyKeeper.privacyTilt)])
        #expect(store.state == PersistedState(privacy: true, saved: SavedPosition(pan: 30, tilt: -10, zoom: 50), mode: .tilt))
        try keeper.exit()
        #expect(camera.absoluteCommands.last == PanTiltPosition(pan: 30, tilt: -10))
        #expect(camera.zoomCommands == [50])
    }

    @Test("Repli refusé par la caméra : le mode tilt est quand même retenu")
    func fallBackRefused() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50, mode: .native)
        camera.failNextWrite = .ioKit(-536870212)
        #expect(throws: CameraError.ioKit(-536870212)) { try keeper.fallBackToTilt() }
        #expect(keeper.mode == .tilt)
        #expect(store.state.mode == .tilt)
    }

    @Test("Promotion : un tilt subi devient natif, la position mémorisée est gardée")
    func promoteToNative() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50)
        keeper.promoteToNative()
        #expect(keeper.mode == .native)
        #expect(keeper.lastTarget == nil)
        #expect(store.state == PersistedState(privacy: true, saved: SavedPosition(pan: 30, tilt: -10, zoom: 50), mode: .native))
    }

    @Test("Le mode retenu est relu au démarrage")
    func modeReloaded() {
        store.state = PersistedState(privacy: true, saved: nil, mode: .native)
        #expect(makeKeeper().mode == .native)
    }
}
