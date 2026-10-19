import Foundation
import NacelleProtocol
import Testing
@testable import PTZCore

/// Vie privée V2 vue du contrôleur : mode natif, second essai, repli sur l'inclinaison (spec § 6.5 bis).
@MainActor
@Suite("Contrôleur : vie privée native")
struct NativePrivacyControllerTests {
    let camera = FakeCamera()
    let scheduler = FakeScheduler()
    let runner = FakeAIRunner()
    let store = MemoryStateStore()
    let log = LogRecorder()
    let errors = ClientErrorBox()

    private func makeController(sdk: Bool = true) -> PTZController {
        runner.nativePrivacyAvailable = sdk
        let controller = PTZController(
            camera: camera,
            scheduler: scheduler,
            ai: runner,
            store: store,
            settings: MotionSettings(),
            isObsbotCenterRunning: { false },
            log: log.sink
        )
        controller.onClientError = { [errors] in errors.values.append(($0, $1, $2)) }
        return controller
    }

    /// Le suivi IA est déjà coupé : la vie privée native part tout de suite.
    private func trackingCut(_ controller: PTZController) {
        _ = controller.handle(.aiTracking(on: false), from: 1)
        runner.finish(.success)
    }

    // MARK: - Entrée

    @Test("Avec le SDK : privacy on part à l'utilitaire, l'objectif n'est pas touché, le mode publié est natif")
    func enterNative() {
        let controller = makeController()
        trackingCut(controller)
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        #expect(runner.privacyOrders == [true])
        #expect(camera.absoluteCommands.isEmpty)
        #expect(controller.snapshot.privacy)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(store.state.mode == .native)
        #expect(store.state.privacy)
        runner.finishPrivacy(.success)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(errors.values.isEmpty)
    }

    @Test("Sans le SDK : l'inclinaison d'emblée, mode tilt publié, aucun ordre natif")
    func enterWithoutSDK() {
        let controller = makeController(sdk: false)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(runner.privacyOrders.isEmpty)
        #expect(camera.absoluteCommands.last?.tilt == PrivacyKeeper.privacyTilt)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(store.state.mode == .tilt)
        #expect(errors.values.isEmpty)
    }

    @Test("Hors vie privée, le mode n'est pas publié")
    func noModeOutsidePrivacy() {
        let controller = makeController()
        #expect(controller.snapshot.privacyMode == nil)
    }

    @Test("Le suivi IA est d'abord coupé : privacy on attend la fin de la coupure")
    func waitsForTrackingCut() {
        let controller = makeController()
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(runner.orders == [false])
        #expect(runner.privacyOrders.isEmpty)
        runner.finish(.success)
        #expect(runner.privacyOrders == [true])
    }

    @Test("Coupure du suivi IA échouée deux fois : la vie privée native part quand même")
    func trackingCutFailureDoesNotBlock() {
        let controller = makeController()
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.finish(.sdkError)
        scheduler.advance(by: ControlTaker.retryDelay)
        runner.finish(.sdkError)
        #expect(controller.snapshot.control == .failed)
        #expect(runner.privacyOrders == [true])
    }

    @Test("Mode natif : pas de vérification de position ni de renvoi, seulement une relecture après 2 s")
    func nativeOnlyRereadsPosition() {
        let controller = makeController()
        trackingCut(controller)
        camera.position = PanTiltPosition(pan: 2, tilt: -1)
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.finishPrivacy(.success)
        camera.position = PanTiltPosition(pan: 0, tilt: 90)
        scheduler.advance(by: PTZController.settleDelay - 0.1)
        #expect(controller.snapshot.tilt != 90)
        scheduler.advance(by: 0.2)
        #expect(controller.snapshot.tilt == 90)
        scheduler.advance(by: 120)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Pendant la vie privée native : move, zoom et suivi IA restent refusés")
    func commandsRefused() {
        let controller = makeController()
        trackingCut(controller)
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.finishPrivacy(.success)
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.zoom(value: 5), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.aiTracking(on: true), from: 1)?.code == .privacyActive)
    }

    // MARK: - Second essai et repli

    @Test("Un échec : second essai dans les 10 s, réussi : le mode reste natif, sans avertissement")
    func secondAttemptSucceeds() {
        let controller = makeController()
        trackingCut(controller)
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.finishPrivacy(.timeout)
        #expect(runner.privacyOrders == [true])
        scheduler.advance(by: NativePrivacy.retryDelay)
        #expect(runner.privacyOrders == [true, true])
        runner.finishPrivacy(.success)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(errors.values.isEmpty)
    }

    @Test("Deux échecs : repli sur l'inclinaison, avertissement au client demandeur, mode tilt publié et retenu")
    func fallbackToTilt() {
        let controller = makeController()
        trackingCut(controller)
        camera.position = PanTiltPosition(pan: 12, tilt: 4)
        _ = controller.handle(.zoom(value: 40), from: 1)
        _ = controller.handle(.privacy(on: true), from: 7)
        runner.finishPrivacy(.sdkError)
        scheduler.advance(by: NativePrivacy.retryDelay)
        runner.finishPrivacy(.sdkError)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(store.state.mode == .tilt)
        #expect(store.state.privacy)
        #expect(camera.absoluteCommands.last?.tilt == PrivacyKeeper.privacyTilt)
        #expect(errors.values.count == 1)
        #expect(errors.values.first?.0 == 7)
        #expect(errors.values.first?.1 == .uvcFailed)
        #expect(errors.values.first?.2 == PrivacyFailureText.fallbackToTilt)
        // La vérification de position reprend, comme en mode tilt.
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyKeeper.privacyTilt)
        // Et la sortie rétablit la position mémorisée, par l'objectif.
        _ = controller.handle(.privacy(on: false), from: 7)
        #expect(runner.privacyOrders.count == 2)
        #expect(!controller.snapshot.privacy)
        #expect(camera.absoluteCommands.last == PanTiltPosition(pan: 12, tilt: 4))
        #expect(camera.zoomCommands.last == 40)
    }

    @Test("Repli : l'ordre absolu ignoré par la caméra est renvoyé (vérification du mode tilt)")
    func fallbackVerifiesPosition() {
        let controller = makeController()
        trackingCut(controller)
        _ = controller.handle(.privacy(on: true), from: 7)
        runner.finishPrivacy(.sdkError)
        scheduler.advance(by: NativePrivacy.retryDelay)
        camera.ignoreAbsoluteCommands = 1
        runner.finishPrivacy(.sdkError)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(camera.absoluteCommands.count == 2)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyKeeper.privacyTilt)
    }

    // MARK: - Sortie

    @Test("Sortie native : privacy off, la vie privée reste active jusqu'à la réponse, puis la position est relue")
    func exitNative() {
        let controller = makeController()
        trackingCut(controller)
        camera.position = PanTiltPosition(pan: 20, tilt: 5)
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.finishPrivacy(.success)
        #expect(controller.handle(.privacy(on: false), from: 1) == nil)
        #expect(runner.privacyOrders == [true, false])
        #expect(controller.snapshot.privacy)
        runner.finishPrivacy(.success)
        #expect(!controller.snapshot.privacy)
        #expect(controller.snapshot.privacyMode == nil)
        #expect(store.state == PersistedState(privacy: false, saved: nil))
        #expect(camera.absoluteCommands.isEmpty)
        #expect(camera.zoomCommands.isEmpty)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.pan == 20)
        #expect(controller.snapshot.tilt == 5)
        scheduler.advance(by: 120)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(errors.values.isEmpty)
    }

    @Test("Sortie native : un échec, second essai dans les 10 s")
    func exitNativeRetry() {
        let controller = makeController()
        trackingCut(controller)
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.finishPrivacy(.success)
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.finishPrivacy(.timeout)
        #expect(controller.snapshot.privacy)
        scheduler.advance(by: NativePrivacy.retryDelay)
        #expect(runner.privacyOrders == [true, false, false])
        runner.finishPrivacy(.success)
        #expect(!controller.snapshot.privacy)
        #expect(errors.values.isEmpty)
    }

    @Test("Sortie native échouée deux fois : la vie privée reste active et l'erreur est montrée au client")
    func exitNativeFailure() {
        let controller = makeController()
        trackingCut(controller)
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.finishPrivacy(.success)
        _ = controller.handle(.privacy(on: false), from: 9)
        runner.finishPrivacy(.sdkError)
        scheduler.advance(by: NativePrivacy.retryDelay)
        runner.finishPrivacy(.sdkError)
        #expect(controller.snapshot.privacy)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(store.state.privacy)
        #expect(errors.values.count == 1)
        #expect(errors.values.first?.0 == 9)
        #expect(errors.values.first?.1 == .uvcFailed)
        #expect(errors.values.first?.2 == PrivacyFailureText.exitFailed)
        // Un nouvel essai de l'utilisateur est possible.
        _ = controller.handle(.privacy(on: false), from: 9)
        #expect(runner.privacyOrders.count == 4)
    }

    @Test("Une demande pendant une bascule en cours est ignorée ; une sortie pendant l'entrée l'annule")
    func requestsDuringSwitch() {
        let controller = makeController()
        trackingCut(controller)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(controller.handle(.privacy(on: true), from: 2) == nil)
        #expect(runner.privacyOrders == [true])
        // Sortie pendant l'entrée : l'entrée est abandonnée, la sortie native part.
        #expect(controller.handle(.privacy(on: false), from: 2) == nil)
        runner.finishPrivacy(.success)
        #expect(runner.privacyOrders == [true, false])
        runner.finishPrivacy(.success)
        #expect(!controller.snapshot.privacy)
    }

    // MARK: - Réapplication

    @Test("Démarrage avec un mode natif retenu et le SDK : privacy on est réappliqué, le suivi recoupé d'abord")
    func startupNative() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), mode: .native)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        #expect(runner.orders == [false])
        #expect(runner.privacyOrders.isEmpty)
        runner.finish(.success)
        #expect(runner.privacyOrders == [true])
        #expect(camera.absoluteCommands.isEmpty)
        runner.finishPrivacy(.success)
        #expect(controller.snapshot.privacyMode == .native)
    }

    @Test("Réapplication native échouée deux fois : repli sur l'inclinaison, journalisé (aucun client à avertir)")
    func startupNativeFails() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), mode: .native)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.finish(.success)
        runner.finishPrivacy(.sdkError)
        scheduler.advance(by: NativePrivacy.retryDelay)
        runner.finishPrivacy(.sdkError)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(store.state.mode == .tilt)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyKeeper.privacyTilt)])
        #expect(errors.values.isEmpty)
        #expect(log.lines.contains { $0.contains("repli") })
    }

    @Test("Mode natif retenu mais plus de SDK : l'inclinaison directement")
    func startupNativeWithoutSDK() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), mode: .native)
        let controller = makeController(sdk: false)
        controller.cameraPresenceChanged(true)
        #expect(runner.privacyOrders.isEmpty)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(store.state.mode == .tilt)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyKeeper.privacyTilt)])
    }

    @Test("Un tilt subi par repli retente le mode natif au rebranchement, objectif détourné entre-temps")
    func tiltRetriesNativeOnReplug() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), mode: .tilt)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyKeeper.privacyTilt)])
        runner.finish(.success)
        #expect(runner.privacyOrders == [true])
        #expect(controller.snapshot.privacyMode == .tilt)
        runner.finishPrivacy(.success)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(store.state.mode == .native)
        // La vérification du tilt est abandonnée.
        let sent = camera.absoluteCommands.count
        scheduler.advance(by: 120)
        #expect(camera.absoluteCommands.count == sent)
        #expect(errors.values.isEmpty)
    }

    @Test("Un tilt dont la réapplication native échoue reste en tilt, sans avertissement répété")
    func tiltStaysWhenNativeFailsAgain() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), mode: .tilt)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.finish(.success)
        runner.finishPrivacy(.sdkError)
        scheduler.advance(by: NativePrivacy.retryDelay)
        runner.finishPrivacy(.sdkError)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(errors.values.isEmpty)
        // La vérification du tilt continue.
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyKeeper.privacyTilt)
    }

    @Test("Caméra débranchée pendant l'entrée : l'ordre est abandonné, le rebranchement réapplique")
    func unplugCancels() {
        let controller = makeController()
        trackingCut(controller)
        _ = controller.handle(.privacy(on: true), from: 1)
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        runner.finishPrivacy(.sdkError)
        scheduler.advance(by: 60)
        #expect(runner.privacyOrders == [true])
        #expect(controller.snapshot.privacyMode == .native)
        #expect(errors.values.isEmpty)
        camera.isPresent = true
        controller.cameraPresenceChanged(true)
        runner.finish(.success)
        #expect(runner.privacyOrders == [true, true])
    }
}
