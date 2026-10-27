import Foundation
import NacelleProtocol
import Testing
@testable import PTZCore

/// Le suivi IA retenu et relu (spec § 6.4 bis) : le choix voulu survit aux rebranchements, aux veilles du Mac et à la vie
/// privée ; l'état réel est relu par `tracking status`, par la même file que la vie privée, qui reste prioritaire.
@MainActor
@Suite("Suivi IA retenu et relu")
struct TrackingReconcilerTests {
    let camera = FakeCamera()
    let scheduler = FakeScheduler()
    let runner = FakeAIRunner()
    let store = MemoryStateStore()
    let log = LogRecorder()
    let errors = ClientErrorBox()

    private static let manual31 = ExposureSetting(shutter: 31, auto: false)

    init() {
        // ptzd lancé avec le SDK : l'utilitaire existe et reste chaud (spec § 6.9).
        runner.nativePrivacyAvailable = true
        runner.keepsWarm = true
        runner.attach(camera: camera, scheduler: scheduler)
        camera.position = PanTiltPosition(pan: 12, tilt: 4)
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

    /// Démarrage de ptzd caméra branchée (le guetteur USB signale la présence), avec le choix retenu `wanted`.
    private func started(wanted: Bool) -> PTZController {
        store.state = PersistedState(privacy: false, saved: nil, aiTracking: wanted)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        return controller
    }

    /// Démarrage avec le suivi voulu : la relance, puis la relecture qui la confirme.
    private func trackingOn() -> PTZController {
        let controller = started(wanted: true)
        runner.answer(.tracking(true))
        scheduler.advance(by: TrackingReconciler.settleDelay)
        runner.answer(.trackingStatus)
        return controller
    }

    private func enterNative(_ controller: PTZController) {
        runner.autoReads = true
        _ = controller.handle(.privacy(on: true), from: 1)
        // La vie privée coupe le suivi d'abord.
        runner.answer(.tracking(false))
        runner.answer(.privacy(true))
        scheduler.advance(by: FakeAIRunner.descentTime + 0.1)
    }

    private func exitNative(_ controller: PTZController) {
        runner.autoReads = true
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.answer(.privacy(false))
        scheduler.advance(by: FakeAIRunner.wakeStateTime + PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin)
    }

    // MARK: - Le choix retenu

    @Test("Interrupteur des apps : un ordre réussi est retenu dans state.json ; un ordre échoué ne change rien")
    func appChoiceIsPersisted() {
        let controller = started(wanted: false)
        runner.answer(.trackingStatus)
        #expect(controller.handle(.aiTracking(on: true), from: 1) == nil)
        runner.answer(.tracking(true))
        #expect(store.state.aiTracking)
        _ = controller.handle(.aiTracking(on: false), from: 1)
        runner.answer(.tracking(false), .sdkError)
        #expect(store.state.aiTracking)
        _ = controller.handle(.aiTracking(on: false), from: 1)
        runner.answer(.tracking(false))
        #expect(!store.state.aiTracking)
    }

    @Test("Joystick : le premier mouvement coupe le suivi et retient « coupé » ; la relecture suivante ne le relance pas")
    func joystickRemembersOff() {
        let controller = trackingOn()
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        #expect(runner.inFlight == .tracking(false))
        #expect(!store.state.aiTracking)
        runner.answer(.tracking(false))
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        if runner.inFlight == .trackingStatus {
            runner.answer(.trackingStatus)
        }
        #expect(runner.orders == [true, false])
        #expect(controller.snapshot.aiTracking == .off)
    }

    // MARK: - Réapplication

    @Test("Branchement (et démarrage de ptzd), suivi voulu : relancé, puis relu ; l'état publié n'est plus « inconnu »")
    func plugResumes() {
        let controller = started(wanted: true)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(controller.snapshot.aiTracking == .on)
        // La caméra bascule en 0,5 s environ (mesuré) : la relecture attend.
        #expect(runner.trackingReads == 0)
        scheduler.advance(by: TrackingReconciler.settleDelay)
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(controller.snapshot.aiTracking == .on)
        #expect(runner.orders == [true])
        #expect(store.state.aiTracking)
        #expect(log.lines.contains { $0.hasPrefix("Suivi IA : relance") && $0.contains("caméra branchée") })
    }

    @Test("Branchement, suivi voulu coupé : rien n'est envoyé ; la relecture publie « coupé »")
    func plugWithTrackingOffSendsNothing() {
        let controller = started(wanted: false)
        #expect(controller.snapshot.aiTracking == .unknown)
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(controller.snapshot.aiTracking == .off)
        #expect(runner.orders.isEmpty)
    }

    @Test("Réveil du Mac, suivi voulu : relancé, puis relu")
    func wakeResumesAndRereads() {
        let controller = trackingOn()
        // La caméra a perdu son suivi pendant la veille (bus USB endormi).
        runner.aiMode = .off
        controller.systemWoke()
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        scheduler.advance(by: TrackingReconciler.settleDelay)
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(controller.snapshot.aiTracking == .on)
        #expect(runner.orders == [true, true])
    }

    @Test("Relance refusée : un nouvel essai 3 s plus tard, puis on s'en remet à la relecture périodique")
    func resumeFailureRetriesOnce() {
        let controller = started(wanted: true)
        runner.answer(.tracking(true), .sdkError)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: ControlTaker.retryDelay)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true), .sdkError)
        scheduler.advance(by: ControlTaker.retryDelay)
        #expect(runner.inFlight == nil)
        #expect(runner.orders == [true, true])
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        // Lu coupé alors qu'il est voulu : relancé.
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(controller.snapshot.aiTracking == .on)
        #expect(errors.values.isEmpty)
    }

    // MARK: - Relecture

    @Test("Relecture : voulu activé, lu coupé → relancé, avec sa ligne de journal")
    func rereadRelaunches() {
        let controller = trackingOn()
        runner.aiMode = .off
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(log.lines.contains("Suivi IA : lu coupé alors qu'il est voulu, relancé."))
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(controller.snapshot.aiTracking == .on)
        #expect(runner.orders == [true, true])
    }

    @Test("Relecture : voulu activé, toujours lu coupé juste après la relance → pas de nouvelle relance avant la relecture suivante")
    func rereadDoesNotLoop() {
        let controller = trackingOn()
        runner.aiMode = .off
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        runner.answer(.trackingStatus)
        // La relance agit, mais la caméra n'en tient pas compte.
        runner.answer(.tracking(true), effect: false)
        scheduler.advance(by: TrackingReconciler.settleDelay)
        runner.answer(.trackingStatus)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: TrackingReconciler.rereadInterval - 1)
        #expect(runner.orders == [true, true])
        scheduler.advance(by: 1)
        runner.answer(.trackingStatus)
        #expect(runner.orders == [true, true, true])
        #expect(controller.snapshot.aiTracking == .off)
    }

    @Test("Relecture : voulu coupé, lu activé (geste sur la caméra) → état réel adopté, retenu et publié, rien n'est envoyé")
    func rereadAdoptsRealState() {
        let controller = started(wanted: false)
        runner.answer(.trackingStatus)
        runner.aiMode = .on
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        runner.answer(.trackingStatus)
        #expect(controller.snapshot.aiTracking == .on)
        #expect(store.state.aiTracking)
        #expect(runner.orders.isEmpty)
    }

    @Test("Relecture : switching → rien n'est conclu, relu un peu plus tard")
    func switchingConcludesNothing() {
        let controller = started(wanted: false)
        runner.aiMode = .switching
        runner.answer(.trackingStatus)
        #expect(controller.snapshot.aiTracking == .unknown)
        #expect(!store.state.aiTracking)
        #expect(runner.orders.isEmpty)
        runner.aiMode = .off
        scheduler.advance(by: TrackingReconciler.settleDelay)
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(controller.snapshot.aiTracking == .off)
    }

    @Test("Utilitaire ancien (unknownOrder) : plus de relecture jusqu'à aiUpdated ; la réapplication continue")
    func oldUtilityStopsRereads() {
        let controller = started(wanted: false)
        runner.answer(.trackingStatus, .unknownOrder)
        scheduler.advance(by: TrackingReconciler.rereadInterval * 4)
        #expect(runner.trackingReads == 1)
        _ = controller.handle(.aiTracking(on: true), from: 1)
        runner.answer(.tracking(true))
        controller.cameraPresenceChanged(false)
        controller.cameraPresenceChanged(true)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        #expect(runner.trackingReads == 1)
        controller.aiUpdated()
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        scheduler.advance(by: TrackingReconciler.settleDelay)
        #expect(runner.inFlight == .trackingStatus)
        #expect(runner.trackingReads == 2)
    }

    @Test("Relecture jamais pendant un ordre de suivi, ni juste après : la caméra bascule encore")
    func noRereadDuringOrder() {
        let controller = started(wanted: false)
        runner.answer(.trackingStatus)
        _ = controller.handle(.aiTracking(on: true), from: 1)
        #expect(runner.inFlight == .tracking(true))
        // L'ordre tarde ; la relecture périodique arrive à échéance pendant ce temps.
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        runner.answer(.tracking(true))
        #expect(runner.inFlight == nil)
        #expect(runner.trackingReads == 1)
        scheduler.advance(by: TrackingReconciler.settleDelay)
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(controller.snapshot.aiTracking == .on)
        #expect(runner.orders == [true])
    }

    @Test("Après une lecture réussie, l'état publié n'est plus jamais « inconnu » (réveil, lecture ratée), hors rebranchement")
    func neverUnknownAfterRead() {
        let controller = started(wanted: false)
        var published: [AITracking] = []
        runner.answer(.trackingStatus)
        controller.onStateChange = { published.append($0.aiTracking) }
        controller.systemWoke()
        runner.answer(.trackingStatus, .sdkError)
        for _ in 0..<4 {
            scheduler.advance(by: TrackingReconciler.rereadInterval)
            if let order = runner.inFlight {
                runner.answer(order)
            }
        }
        #expect(controller.snapshot.aiTracking == .off)
        #expect(!published.contains(.unknown))
    }

    // MARK: - Vie privée

    @Test("Vie privée : coupe le suivi à l'entrée sans changer le choix ; rien pendant (ni relance ni relecture) ; reprise à la sortie")
    func privacyKeepsChoiceAndResumesAfter() {
        let controller = trackingOn()
        enterNative(controller)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(store.state.aiTracking)
        let reads = runner.trackingReads
        // Pendant la vie privée : réveil du Mac, mise à jour d'obsbot-ai, relectures lentes : aucun ordre de suivi.
        controller.systemWoke()
        scheduler.advance(by: 45)
        controller.aiUpdated()
        scheduler.advance(by: 90)
        #expect(runner.orders == [true, false])
        #expect(runner.trackingReads == reads)
        #expect(controller.snapshot.privacy)
        exitNative(controller)
        #expect(!controller.snapshot.privacy)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(controller.snapshot.aiTracking == .on)
        #expect(runner.refused.isEmpty)
        #expect(errors.values.isEmpty)
    }

    @Test("Sortie de la vie privée par le repli : la reprise attend que la position mémorisée soit rétablie et vérifiée")
    func privacyResumeWaitsForRestoredPosition() {
        let controller = trackingOn()
        // Le SDK n'est plus prêt : l'entrée passe par le repli (−70° d'abord), la caméra reviendra à −70° au réveil.
        runner.idleStop()
        runner.autoReads = true
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.answer(.tracking(false))
        for _ in 0..<60 {
            if let order = runner.inFlight {
                runner.answer(order)
            }
            scheduler.advance(by: 0.1)
        }
        #expect(controller.snapshot.privacyMode == .native)
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.answer(.privacy(false))
        for _ in 0..<40 where controller.snapshot.privacy {
            scheduler.advance(by: 0.1)
        }
        // La position mémorisée vient d'être renvoyée : sa vérification (2 s) d'abord, le suivi ensuite.
        #expect(!controller.snapshot.privacy)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(camera.position == PanTiltPosition(pan: 12, tilt: 4))
        #expect(runner.refused.isEmpty)
    }

    @Test("Vie privée voulue pendant qu'une relance attend dans la file : elle n'est jamais envoyée")
    func queuedResumeDroppedByPrivacy() {
        store.state = PersistedState(privacy: false, saved: nil, autoExposure: true, exposureOrigin: Self.manual31, aiTracking: true)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        // L'exposition voulue est partie la première ; la relance attend derrière elle.
        #expect(runner.inFlight == .exposure(ExposureSetting(shutter: 31, auto: true)))
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        runner.autoReads = true
        for _ in 0..<100 {
            while let order = runner.inFlight {
                runner.answer(order)
            }
            scheduler.advance(by: 0.1)
        }
        #expect(controller.snapshot.privacy)
        #expect(!runner.orders.contains(true))
        #expect(store.state.aiTracking)
        #expect(runner.refused.isEmpty)
    }

    @Test("Relecture partie au moment de l'entrée en vie privée : la vie privée ne l'attend pas, −70° tout de suite")
    func privacyDoesNotWaitForTrackingRead() {
        let controller = trackingOn()
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        #expect(runner.inFlight == .trackingStatus)
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyReconciler.privacyTilt)])
        #expect(log.lines.contains { $0.contains("chemin de repli") && $0.contains("suivi IA") })
        runner.answer(.trackingStatus)
        #expect(runner.inFlight == .tracking(false))
        #expect(store.state.aiTracking)
    }
}
