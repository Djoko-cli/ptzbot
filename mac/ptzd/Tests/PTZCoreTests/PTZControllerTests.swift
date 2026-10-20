import Foundation
import NacelleProtocol
import Testing
@testable import PTZCore

@MainActor
@Suite("Contrôleur")
struct PTZControllerTests {
    let camera = FakeCamera()
    let scheduler = FakeScheduler()
    let runner = FakeAIRunner()
    let store = MemoryStateStore()
    let log = LogRecorder()

    private func makeController() -> PTZController {
        PTZController(
            camera: camera,
            scheduler: scheduler,
            ai: runner,
            store: store,
            settings: MotionSettings(),
            isObsbotCenterRunning: { false },
            log: log.sink
        )
    }

    @Test("L'état initial reflète la caméra et state.json")
    func initialSnapshot() {
        camera.isPresent = false
        store.state = PersistedState(privacy: true, saved: nil)
        let controller = makeController()
        #expect(controller.snapshot.camera == .absent)
        #expect(controller.snapshot.privacy)
        #expect(controller.snapshot.control == .idle)
    }

    @Test("Messages de session : refusés sans toucher à la caméra")
    func sessionMessages() {
        let controller = makeController()
        #expect(controller.handle(.auth(deviceID: "x", signature: Data()), from: 1)?.code == .badMessage)
        #expect(controller.handle(.pair(pairingID: "123456", publicKey: Data(), name: "x", proof: Data()), from: 1)?.code == .badMessage)
        #expect(controller.handle(.webrtcOffer(id: 1, sdp: "v=0"), from: 1)?.code == .badMessage)
        #expect(camera.relativeCommands.isEmpty)
    }

    @Test("prewarmAI prépare l'utilitaire du suivi IA ; chaque message d'un client aussi")
    func prewarm() {
        let controller = makeController()
        #expect(runner.prewarms == 0)
        controller.prewarmAI()
        #expect(runner.prewarms == 1)
        _ = controller.handle(.zoom(value: 10), from: 1)
        #expect(runner.prewarms == 2)
        #expect(runner.runCount == 0)
    }

    @Test("Caméra absente ou vie privée : aucune préparation du suivi IA, ni par un message ni par prewarmAI")
    func noPrewarmWithoutCameraOrInPrivacy() {
        camera.isPresent = false
        let controller = makeController()
        controller.prewarmAI()
        _ = controller.handle(.zoom(value: 10), from: 1)
        #expect(runner.prewarms == 0)

        camera.isPresent = true
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        let before = runner.prewarms
        controller.prewarmAI()
        _ = controller.handle(.zoom(value: 10), from: 1)
        #expect(runner.prewarms == before)

        _ = controller.handle(.privacy(on: false), from: 1)
        controller.prewarmAI()
        #expect(runner.prewarms == before + 1)
    }

    @Test("Branchement ou débranchement de la caméra : l'utilitaire du suivi IA est réinitialisé")
    func presenceResetsRunner() {
        let controller = makeController()
        controller.cameraPresenceChanged(false)
        #expect(runner.resets == 1)
        controller.cameraPresenceChanged(true)
        #expect(runner.resets == 2)
    }

    @Test("Caméra absente : move, zoom et privacy sont refusés")
    func cameraAbsent() {
        camera.isPresent = false
        let controller = makeController()
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1)?.code == .cameraAbsent)
        #expect(controller.handle(.zoom(value: 10), from: 1)?.code == .cameraAbsent)
        #expect(controller.handle(.privacy(on: true), from: 1)?.code == .cameraAbsent)
    }

    @Test("Un mouvement publie moving, puis l'arrêt automatique le retire")
    func movePublishes() {
        let controller = makeController()
        var published: [StateSnapshot] = []
        controller.onStateChange = { published.append($0) }
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1) == nil)
        #expect(controller.snapshot.moving)
        scheduler.advance(by: 0.31)
        #expect(!controller.snapshot.moving)
        #expect(published.contains { $0.moving })
    }

    @Test("Vie privée : arrêt, objectif vers le bas, puis refus des commandes")
    func privacyOn() {
        let controller = makeController()
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        #expect(controller.snapshot.privacy)
        #expect(!controller.snapshot.moving)
        #expect(camera.absoluteCommands.last?.tilt == PrivacyReconciler.privacyTilt)
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.zoom(value: 10), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.move(pan: 0, tilt: 0), from: 1) == nil)
    }

    @Test("La position n'est relue que 2 s après le déplacement absolu")
    func settleBeforeReading() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(controller.snapshot.tilt == -1)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyReconciler.privacyTilt)
    }

    @Test("Sortie de vie privée : position et zoom relus")
    func privacyOff() {
        let controller = makeController()
        camera.position = PanTiltPosition(pan: 20, tilt: 5)
        _ = controller.handle(.zoom(value: 40), from: 1)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(controller.handle(.privacy(on: false), from: 1) == nil)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(!controller.snapshot.privacy)
        #expect(controller.snapshot.pan == 20)
        #expect(controller.snapshot.tilt == 5)
        #expect(controller.snapshot.zoom == 40)
    }

    @Test("Commande refusée par la caméra : uvcFailed")
    func uvcFailure() {
        let controller = makeController()
        camera.failNextWrite = .ioKit(-536870212)
        #expect(controller.handle(.zoom(value: 10), from: 1)?.code == .uvcFailed)
    }

    @Test("takeControl ne touche plus au suivi IA")
    func takeControl() {
        let controller = makeController()
        #expect(controller.handle(.takeControl, from: 1) == nil)
        #expect(runner.runCount == 0)
        #expect(controller.snapshot.control == .idle)
    }

    @Test("Premier mouvement : coupe le suivi (inconnu ou allumé), une seule fois ; le mouvement part quand même")
    func firstMoveCutsTracking() {
        let controller = makeController()
        #expect(controller.handle(.move(pan: 0, tilt: 0), from: 1) == nil)
        #expect(runner.runCount == 0)
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1) == nil)
        #expect(runner.orders == [false])
        #expect(controller.snapshot.control == .taking)
        #expect(controller.snapshot.moving)
        _ = controller.handle(.move(pan: 0.5, tilt: 0), from: 1)
        #expect(runner.runCount == 1)
        runner.finish(.success)
        #expect(controller.snapshot.aiTracking == .off)
        #expect(controller.snapshot.control == .ready)
        _ = controller.handle(.move(pan: 1, tilt: 1), from: 1)
        #expect(runner.runCount == 1)
    }

    @Test("aiTracking on : utilitaire lancé, état publié ; le mouvement suivant le recoupe")
    func aiTrackingOn() {
        let controller = makeController()
        #expect(controller.handle(.aiTracking(on: true), from: 1) == nil)
        #expect(runner.orders == [true])
        runner.finish(.success)
        #expect(controller.snapshot.aiTracking == .on)
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        #expect(runner.orders == [true, false])
    }

    @Test("aiTracking refusé en vie privée et caméra débranchée")
    func aiTrackingRefused() {
        let controller = makeController()
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.finish(.success)
        #expect(controller.handle(.aiTracking(on: true), from: 1)?.code == .privacyActive)
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        #expect(controller.handle(.aiTracking(on: true), from: 1)?.code == .cameraAbsent)
    }

    @Test("aiTracking échoué : erreur uvcFailed envoyée plus tard au client qui l'a demandé")
    func aiTrackingFailure() {
        let controller = makeController()
        let errors = ClientErrorBox()
        controller.onClientError = { errors.values.append(($0, $1, $2)) }
        _ = controller.handle(.aiTracking(on: true), from: 7)
        runner.finish(.sdkError)
        #expect(errors.values.count == 1)
        #expect(errors.values.first?.0 == 7)
        #expect(errors.values.first?.1 == .uvcFailed)
        #expect(errors.values.first?.2 == "Suivi IA non modifié (erreur du SDK OBSBOT).")
        #expect(controller.snapshot.aiTracking == .unknown)
    }

    @Test("Entrer en vie privée coupe le suivi d'abord ; rebrancher hors vie privée le rend inconnu")
    func privacyCutsTrackingAndReplugForgets() {
        let controller = makeController()
        _ = controller.handle(.aiTracking(on: true), from: 1)
        runner.finish(.success)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(runner.orders == [true, false])
        runner.finish(.success)
        _ = controller.handle(.privacy(on: false), from: 1)
        #expect(controller.snapshot.aiTracking == .off)
        controller.cameraPresenceChanged(true)
        #expect(controller.snapshot.aiTracking == .unknown)
    }

    @Test("aiTracking(on: true) en vol, puis privacy(on: true) lance la coupure après succès")
    func aiTrackingCutDuringPrivacyEntry() {
        let controller = makeController()
        _ = controller.handle(.aiTracking(on: true), from: 1)
        #expect(runner.orders == [true])
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.finish(.success)
        #expect(runner.orders == [true, false])
        #expect(runner.runCount == 2)
        runner.finish(.success)
        #expect(controller.snapshot.aiTracking == .off)
    }

    @Test("À partir de tracking .off : aiTracking(on: true) en vol, puis privacy(on: true) lance la coupure")
    func aiTrackingCutFromOffDuringPrivacy() {
        let controller = makeController()
        _ = controller.handle(.aiTracking(on: false), from: 1)
        runner.finish(.success)
        #expect(controller.snapshot.aiTracking == .off)
        _ = controller.handle(.aiTracking(on: true), from: 1)
        #expect(runner.orders == [false, true])
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.finish(.success)
        #expect(runner.orders == [false, true, false])
        #expect(runner.runCount == 3)
        runner.finish(.success)
        #expect(controller.snapshot.aiTracking == .off)
    }

    @Test("À partir de tracking .off : aiTracking(on: true) en vol, puis mouvement lance la coupure")
    func aiTrackingCutFromOffDuringMove() {
        let controller = makeController()
        _ = controller.handle(.aiTracking(on: false), from: 1)
        runner.finish(.success)
        #expect(controller.snapshot.aiTracking == .off)
        _ = controller.handle(.aiTracking(on: true), from: 1)
        #expect(runner.orders == [false, true])
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        runner.finish(.success)
        #expect(runner.orders == [false, true, false])
        #expect(runner.runCount == 3)
        runner.finish(.success)
        #expect(controller.snapshot.aiTracking == .off)
    }

    @Test("Débranchement : caméra absente, mouvement oublié")
    func unplug() {
        let controller = makeController()
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        #expect(controller.snapshot.camera == .absent)
        #expect(!controller.snapshot.moving)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Rebranchement en vie privée : objectif renvoyé vers le bas et suivi IA recoupé")
    func replugInPrivacy() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        camera.isPresent = false
        let controller = makeController()
        camera.isPresent = true
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyReconciler.privacyTilt)])
        #expect(runner.runCount == 1)
        #expect(controller.snapshot.camera == .connected)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyReconciler.privacyTilt)
    }

    @Test("La déconnexion du pilote arrête la nacelle")
    func disconnectStops() {
        let controller = makeController()
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 7)
        controller.clientDisconnected(7)
        #expect(!controller.snapshot.moving)
        #expect(camera.relativeCommands.last == .stop)
    }

    @Test("Ordre de vie privée ignoré par la caméra : renvoyé après relecture")
    func ignoredPrivacyCommandIsResent() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        camera.ignoreAbsoluteCommands = 1
        _ = controller.handle(.privacy(on: true), from: 1)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(camera.absoluteCommands.count == 2)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyReconciler.privacyTilt)
        #expect(log.lines.contains { $0.contains("ignoré") })
    }

    @Test("Hors vie privée, ordre de sortie toujours ignoré : deux renvois au plus, puis une erreur")
    func exitResendsAreBounded() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        camera.position = PanTiltPosition(pan: 20, tilt: 5)
        _ = controller.handle(.privacy(on: true), from: 1)
        scheduler.advance(by: PTZController.settleDelay)
        let sent = camera.absoluteCommands.count
        camera.ignoreAbsoluteCommands = 10
        _ = controller.handle(.privacy(on: false), from: 1)
        for _ in 0..<10 {
            scheduler.advance(by: 30)
        }
        #expect(camera.absoluteCommands.count == sent + 1 + PTZController.maxResends)
        #expect(log.lines.filter { $0.contains("non atteinte") }.count == 1)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Vie privée : la vérification ne s'arrête pas après maxResends et finit par atteindre le tilt")
    func privacyNeverGivesUp() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        camera.ignoreAbsoluteCommands = 6
        _ = controller.handle(.privacy(on: true), from: 1)
        // Vérifications à 2 s, puis renvois suivis de 2, 5, 10, 30, 30, 30 s.
        let checks: [Double] = [PTZController.settleDelay] + PTZController.privacyBackoff + [30, 30]
        for (index, delay) in checks.enumerated() {
            #expect(camera.absoluteCommands.count == 1 + index)
            scheduler.advance(by: delay)
        }
        #expect(camera.absoluteCommands.count == 7)
        #expect(camera.absoluteCommands.allSatisfy { $0.tilt == PrivacyReconciler.privacyTilt })
        #expect(controller.snapshot.tilt == PrivacyReconciler.privacyTilt)
        // Un premier raté, puis une ligne par palier (2, 5, 10, 30 s) : pas à chaque essai de 30 s.
        #expect(log.lines.filter { $0.contains("ignoré") }.count == PTZController.privacyBackoff.count)
        scheduler.advance(by: 300)
        #expect(camera.absoluteCommands.count == 7)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Vie privée et relecture impossible : renvoi quand même, jusqu'à relire le tilt")
    func privacyUnreadablePositionRetries() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        camera.failReads = true
        scheduler.advance(by: PTZController.settleDelay)
        #expect(camera.absoluteCommands.count == 2)
        camera.failReads = false
        scheduler.advance(by: PTZController.privacyBackoff[0])
        #expect(controller.snapshot.tilt == PrivacyReconciler.privacyTilt)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Rebranchement en vie privée, ordres ignorés au démarrage : renvoyés jusqu'au tilt")
    func replugIgnoredEnforceIsResent() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        camera.isPresent = false
        let controller = makeController()
        camera.isPresent = true
        camera.ignoreAbsoluteCommands = 1 + PTZController.maxResends
        controller.cameraPresenceChanged(true)
        scheduler.advance(by: PTZController.settleDelay)
        for delay in PTZController.privacyBackoff {
            scheduler.advance(by: delay)
        }
        #expect(camera.absoluteCommands.count == 2 + PTZController.maxResends)
        #expect(controller.snapshot.tilt == PrivacyReconciler.privacyTilt)
    }

    @Test("Fin de la coupure du suivi IA en vie privée : ordre de vie privée renvoyé et revérifié")
    func controlFinishReenforcesPrivacy() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands.count == 1)
        #expect(controller.snapshot.control == .taking)
        scheduler.advance(by: PTZController.settleDelay)
        // Le suivi IA a remonté l'objectif pendant la coupure.
        camera.position = PanTiltPosition(pan: 12, tilt: 10)
        runner.finish(.success)
        #expect(controller.snapshot.control == .ready)
        #expect(camera.absoluteCommands == Array(repeating: PanTiltPosition(pan: 12, tilt: PrivacyReconciler.privacyTilt), count: 2))
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyReconciler.privacyTilt)
        // Un échec de l'utilitaire réapplique aussi (rebranchement en vie privée : réapplication, puis coupure).
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands.count == 3)
        runner.finish(.sdkError)
        #expect(controller.snapshot.control == .taking)
        scheduler.advance(by: ControlTaker.retryDelay)
        runner.finish(.sdkError)
        #expect(controller.snapshot.control == .failed)
        #expect(camera.absoluteCommands.count == 4)
    }

    @Test("Fin de la coupure hors vie privée : aucun ordre absolu")
    func controlFinishOutsidePrivacy() {
        let controller = makeController()
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        _ = controller.handle(.move(pan: 0, tilt: 0), from: 1)
        runner.finish(.success)
        #expect(camera.absoluteCommands.isEmpty)
    }

    @Test("Un mouvement du joystick après la sortie annule la vérification")
    func userMoveCancelsVerification() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        scheduler.advance(by: PTZController.settleDelay)
        _ = controller.handle(.privacy(on: false), from: 1)
        let sent = camera.absoluteCommands.count
        camera.position = PanTiltPosition(pan: 40, tilt: 10)
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(camera.absoluteCommands.count == sent)
    }

    @Test("En vie privée, un pan relu décalé ne déclenche pas de renvoi")
    func privacyChecksTiltOnly() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        camera.position = PanTiltPosition(pan: camera.position.pan + 10, tilt: PrivacyReconciler.privacyTilt)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(camera.absoluteCommands.count == 1)
        #expect(!log.lines.contains { $0.contains("ignoré") })
    }
}

@MainActor
@Suite("Contrôleur : exposition automatique (§ 6.11)")
struct PTZControllerExposureTests {
    let camera = FakeCamera()
    let scheduler = FakeScheduler()
    let runner = FakeAIRunner()
    let store = MemoryStateStore()
    let log = LogRecorder()
    let errors = ClientErrorBox()

    private static let manual31 = ExposureSetting(shutter: 31, auto: false)
    private static let auto31 = ExposureSetting(shutter: 31, auto: true)

    init() {
        runner.nativePrivacyAvailable = true
    }

    private func makeController() -> PTZController {
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

    @Test("autoExposure(on: true) : l'état publié passe à « on » tout de suite, la caméra est lue puis réglée")
    func activation() {
        let controller = makeController()
        #expect(controller.snapshot.autoExposure == .off)
        var states: [AutoExposure?] = []
        controller.onStateChange = { states.append($0.autoExposure) }
        #expect(controller.handle(.autoExposure(on: true), from: 1) == nil)
        #expect(controller.snapshot.autoExposure == .on)
        #expect(states == [.on])
        runner.answer(.exposureStatus)
        runner.answer(.exposure(Self.auto31))
        #expect(runner.exposure == Self.auto31)
        #expect(controller.snapshot.autoExposure == .on)
        #expect(errors.values.isEmpty)
        #expect(controller.handle(.autoExposure(on: false), from: 1) == nil)
        runner.answer(.exposure(Self.manual31))
        #expect(controller.snapshot.autoExposure == .off)
        #expect(runner.exposure == Self.manual31)
    }

    @Test("Sans SDK : l'état publié est « unavailable » et la demande est refusée (uvcFailed)")
    func withoutSDK() {
        runner.nativePrivacyAvailable = false
        let controller = makeController()
        #expect(controller.snapshot.autoExposure == .unavailable)
        let refusal = controller.handle(.autoExposure(on: true), from: 1)
        #expect(refusal?.code == .uvcFailed)
        #expect(refusal?.message == ExposureFailureText.noSDK)
    }

    @Test("Caméra absente : cameraAbsent")
    func cameraAbsent() {
        camera.isPresent = false
        let controller = makeController()
        #expect(controller.handle(.autoExposure(on: true), from: 1)?.code == .cameraAbsent)
        #expect(runner.received.isEmpty)
    }

    @Test("Pendant la vie privée : l'interrupteur reste utilisable (choix retenu et publié), mais aucun ordre n'est donné")
    func duringPrivacy() {
        let controller = makeController()
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(controller.snapshot.privacy)
        #expect(controller.handle(.autoExposure(on: true), from: 1) == nil)
        #expect(controller.snapshot.autoExposure == .on)
        // Un seul ordre à la fois : jamais d'ordre refusé par l'utilitaire, chacun répond à son tour.
        var guardRail = 0
        while let order = runner.inFlight, guardRail < 20 {
            runner.answer(order)
            guardRail += 1
        }
        #expect(runner.refused.isEmpty)
        #expect(runner.exposureReads == 0)
        #expect(runner.exposureOrders.isEmpty)
        #expect(controller.snapshot.autoExposure == .on)
    }

    @Test("Exposition et vie privée partagent la file : un ordre d'exposition en cours ne croise jamais la vie privée, et rien d'autre ne part ensuite")
    func neverCrossesPrivacy() {
        let controller = makeController()
        _ = controller.handle(.autoExposure(on: true), from: 1)
        #expect(runner.inFlight == .exposureStatus)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(runner.inFlight == .exposureStatus)
        runner.answer(.exposureStatus)
        #expect(runner.refused.isEmpty)
        var guardRail = 0
        while let order = runner.inFlight, guardRail < 30 {
            runner.answer(order)
            guardRail += 1
        }
        #expect(runner.refused.isEmpty)
        // L'exposition a été abandonnée à l'entrée en vie privée : aucun ordre d'exposition après la lecture.
        #expect(runner.exposureOrders.isEmpty)
    }

    @Test("Démarrage et branchement : l'exposition voulue est réappliquée avec l'origine retenue, sans relire le réglage")
    func reapplyOnPlug() {
        store.state = PersistedState(privacy: false, saved: nil, autoExposure: true, exposureOrigin: Self.manual31)
        let controller = makeController()
        #expect(controller.snapshot.autoExposure == .on)
        controller.cameraPresenceChanged(true)
        // L'utilitaire repart : l'ordre part sur la session neuve.
        #expect(runner.inFlight == .exposure(Self.auto31))
        runner.answer(.exposure(Self.auto31))
        #expect(runner.exposureReads == 0)
        #expect(runner.exposure == Self.auto31)

        // Rebranchement : la caméra a redémarré et oublié le mode automatique.
        controller.cameraPresenceChanged(false)
        runner.powerCycle()
        controller.cameraPresenceChanged(true)
        #expect(runner.exposure == Self.manual31)
        runner.answer(.exposure(Self.auto31))
        #expect(runner.exposure == Self.auto31)
        #expect(errors.values.isEmpty)
    }

    @Test("Débranchement pendant un ordre : la réponse perdue n'est pas une erreur, la caméra rebranchée est réglée")
    func unplugDuringOrder() {
        let controller = makeController()
        _ = controller.handle(.autoExposure(on: true), from: 1)
        runner.answer(.exposureStatus)
        controller.cameraPresenceChanged(false)
        #expect(errors.values.isEmpty)
        #expect(controller.snapshot.autoExposure == .on)
        camera.isPresent = true
        controller.cameraPresenceChanged(true)
        #expect(runner.inFlight == .exposure(Self.auto31))
        runner.answer(.exposure(Self.auto31))
        #expect(runner.exposure == Self.auto31)
    }

    @Test("aiUpdated : l'exposition voulue est réappliquée sur l'utilitaire neuf")
    func reapplyOnAIUpdated() {
        store.state = PersistedState(privacy: false, saved: nil, autoExposure: true, exposureOrigin: Self.manual31)
        let controller = makeController()
        controller.aiUpdated()
        #expect(runner.inFlight == .exposure(Self.auto31))
        runner.answer(.exposure(Self.auto31))
        #expect(runner.exposure == Self.auto31)
    }

    @Test("I2 : aiUpdated caméra absente fait retomber « en cours de mise à jour » ; l'ordre part au branchement")
    func aiUpdatedWithoutCamera() {
        store.state = PersistedState(privacy: false, saved: nil, autoExposure: true, exposureOrigin: Self.manual31)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.answer(.exposure(Self.auto31), .unknownOrder)
        #expect(controller.snapshot.autoExposure == .unavailable)
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        controller.aiUpdated()
        #expect(controller.snapshot.autoExposure == .on)
        camera.isPresent = true
        controller.cameraPresenceChanged(true)
        #expect(runner.inFlight == .exposure(Self.auto31))
        runner.answer(.exposure(Self.auto31))
        #expect(runner.exposure == Self.auto31)
    }

    @Test("La vie privée réécrit state.json sans effacer l'exposition automatique")
    func privacyKeepsExposureFields() {
        runner.nativePrivacyAvailable = false
        store.state = PersistedState(privacy: false, saved: nil, autoExposure: true, exposureOrigin: Self.manual31)
        let controller = makeController()
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(store.state.privacy)
        #expect(store.state.autoExposure)
        #expect(store.state.exposureOrigin == Self.manual31)
        _ = controller.handle(.privacy(on: false), from: 1)
        #expect(!store.state.privacy)
        #expect(store.state.autoExposure)
        #expect(store.state.exposureOrigin == Self.manual31)
    }

    @Test("Échec de l'activation : erreur uvcFailed au client qui l'a demandée, état « off »")
    func activationFailureReachesClient() {
        let controller = makeController()
        _ = controller.handle(.autoExposure(on: true), from: 9)
        runner.answer(.exposureStatus, .sdkError)
        #expect(errors.values.count == 1)
        #expect(errors.values.first?.0 == 9)
        #expect(errors.values.first?.1 == .uvcFailed)
        #expect(errors.values.first?.2 == ExposureFailureText.readFailed)
        #expect(controller.snapshot.autoExposure == .off)
    }
}

@MainActor
@Suite("Contrôleur : exposition automatique et vie privée native (§ 6.11)")
struct PTZControllerExposurePrivacyTests {
    let camera = FakeCamera()
    let scheduler = FakeScheduler()
    let runner = FakeAIRunner()
    let store = MemoryStateStore()
    let log = LogRecorder()
    let errors = ClientErrorBox()

    private static let manual31 = ExposureSetting(shutter: 31, auto: false)
    private static let auto31 = ExposureSetting(shutter: 31, auto: true)

    init() {
        runner.nativePrivacyAvailable = true
        runner.attach(camera: camera, scheduler: scheduler)
    }

    private func makeController() -> PTZController {
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

    /// Caméra branchée, suivi IA déjà coupé, utilitaire prêt : la vie privée prend le chemin rapide.
    private func ready() -> PTZController {
        camera.position = PanTiltPosition(pan: 12, tilt: 4)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.aiTracking(on: false), from: 1)
        runner.answer(.tracking(false))
        return controller
    }

    private func enterNative(_ controller: PTZController) {
        runner.autoReads = true
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.answer(.privacy(true))
        scheduler.advance(by: FakeAIRunner.descentTime + 0.1)
    }

    private func exitNative(_ controller: PTZController) {
        runner.autoReads = true
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.answer(.privacy(false))
        scheduler.advance(by: FakeAIRunner.wakeStateTime + PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin)
    }

    @Test("C1 : vie privée native en service, l'interrupteur est publié mais aucun ordre n'est donné ; à la sortie, la lecture puis le réglage partent")
    func noOrderUntilPrivacyEnds() {
        let controller = ready()
        enterNative(controller)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(controller.handle(.autoExposure(on: true), from: 2) == nil)
        #expect(controller.snapshot.autoExposure == .on)
        scheduler.advance(by: 90)
        #expect(runner.exposureReads == 0)
        #expect(runner.exposureOrders.isEmpty)
        #expect(!store.state.autoExposure)
        #expect(runner.exposure == Self.manual31)
        exitNative(controller)
        #expect(!controller.snapshot.privacy)
        #expect(runner.inFlight == .exposureStatus)
        runner.answer(.exposureStatus)
        runner.answer(.exposure(Self.auto31))
        #expect(runner.exposure == Self.auto31)
        #expect(controller.snapshot.autoExposure == .on)
        #expect(errors.values.isEmpty)
        #expect(runner.refused.isEmpty)
    }

    @Test("C1 : démarrage de ptzd (ou aiUpdated, rebranchement) en vie privée native avec l'exposition voulue : aucun ordre d'exposition avant la sortie")
    func noReapplyWhilePrivacy() {
        camera.position = PanTiltPosition(pan: 12, tilt: 4)
        store.state = PersistedState(
            privacy: true,
            saved: SavedPosition(pan: 12, tilt: 4, zoom: 33),
            native: true,
            autoExposure: true,
            exposureOrigin: Self.manual31
        )
        runner.state = .privacy
        runner.autoReads = true
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        scheduler.advance(by: 30)
        controller.aiUpdated()
        scheduler.advance(by: 30)
        // Rebranchement : la caméra a redémarré, éveillée et droite ; la vie privée reprend, l'exposition attend toujours.
        controller.cameraPresenceChanged(false)
        runner.powerCycle()
        controller.cameraPresenceChanged(true)
        for _ in 0..<300 {
            while let order = runner.inFlight {
                runner.answer(order)
            }
            scheduler.advance(by: 0.1)
        }
        #expect(controller.snapshot.privacy)
        #expect(runner.exposureReads == 0)
        #expect(runner.exposureOrders.isEmpty)
        #expect(controller.snapshot.autoExposure == .on)
        #expect(runner.refused.isEmpty)
    }

    @Test("I1 : entrée en vie privée pendant un ordre d'exposition lent : −70° tout de suite, puis le mode natif quand la file est libre")
    func privacyEntryDuringSlowExposureOrder() {
        let controller = ready()
        #expect(controller.handle(.autoExposure(on: true), from: 2) == nil)
        runner.answer(.exposureStatus)
        // Le passage en automatique est parti et tarde à répondre.
        #expect(runner.inFlight == .exposure(Self.auto31))
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        // Le chemin rapide aurait attendu derrière lui : −70° part sans attendre.
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyReconciler.privacyTilt)])
        #expect(log.lines.contains { $0.contains("chemin de repli") && $0.contains("ordre d'exposition en cours") })
        #expect(runner.inFlight == .exposure(Self.auto31))
        // Un ordre parti n'est pas interrompu ; sa réponse arrive, puis la vie privée native part.
        runner.answer(.exposure(Self.auto31))
        scheduler.advance(by: PrivacyReconciler.settleDelay + PrivacyReconciler.pollInterval)
        #expect(runner.inFlight == .privacy(true))
        runner.autoReads = true
        runner.answer(.privacy(true))
        scheduler.advance(by: FakeAIRunner.descentTime + 0.1)
        #expect(controller.snapshot.privacyMode == .native)
        // Aucun ordre d'exposition n'est parti vers la caméra endormie.
        #expect(runner.exposureOrders == [Self.auto31])
        #expect(runner.refused.isEmpty)
        #expect(errors.values.isEmpty)
    }

    @Test("I1 : la vie privée voulue pendant la lecture d'exposition : le passage en automatique n'est jamais envoyé à la caméra endormie")
    func queuedExposureOrderDroppedByPrivacy() {
        let controller = ready()
        #expect(controller.handle(.autoExposure(on: true), from: 2) == nil)
        #expect(runner.inFlight == .exposureStatus)
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        runner.answer(.exposureStatus)
        runner.autoReads = true
        for _ in 0..<100 {
            while let order = runner.inFlight {
                runner.answer(order)
            }
            scheduler.advance(by: 0.1)
        }
        #expect(controller.snapshot.privacy)
        #expect(runner.exposureOrders.isEmpty)
        #expect(runner.refused.isEmpty)
        // Le choix reste publié ; à la sortie, la lecture repart.
        #expect(controller.snapshot.autoExposure == .on)
        exitNative(controller)
        #expect(runner.exposureReads == 2)
    }
}

/// Erreurs transmises par `onClientError` (tests).
@MainActor
final class ClientErrorBox {
    var values: [(ClientID, ErrorCode, String)] = []
}
