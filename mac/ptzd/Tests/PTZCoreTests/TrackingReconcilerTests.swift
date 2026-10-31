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

    /// Démarrage avec le suivi voulu, mais la caméra ne tient pas la relance : la lecture de confirmation la lit coupée.
    /// Aucune lecture n'a jamais lu « activé » : une relecture périodique qui lit « coupé » relance.
    private func trackingNeverHeld() -> PTZController {
        let controller = started(wanted: true)
        runner.answer(.tracking(true), effect: false)
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
        // Voulu coupé : la relecture part quand même (elle confirme l'état), et ne relance rien.
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(runner.inFlight == nil)
        #expect(runner.orders == [true, false])
        #expect(controller.snapshot.aiTracking == .off)
    }

    @Test("Joystick pendant une relance partie : la relance aboutit, le suivi est recoupé derrière elle, jamais rallumé")
    func joystickDuringResumeInFlight() {
        let controller = trackingNeverHeld()
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        runner.answer(.trackingStatus)
        #expect(runner.inFlight == .tracking(true))
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        #expect(!store.state.aiTracking)
        runner.answer(.tracking(true))
        #expect(runner.inFlight == .tracking(false))
        runner.answer(.tracking(false))
        for _ in 0..<10 {
            scheduler.advance(by: TrackingReconciler.rereadInterval)
            while let order = runner.inFlight {
                runner.answer(order)
            }
        }
        #expect(runner.orders == [true, true, false])
        #expect(!store.state.aiTracking)
        #expect(controller.snapshot.aiTracking == .off)
        #expect(runner.refused.isEmpty)
    }

    @Test("Joystick pendant une relance encore en file : la coupure passe devant, la relance ne part jamais")
    func joystickDuringQueuedResume() {
        let exposure = ExposureSetting(shutter: 31, auto: true)
        store.state = PersistedState(privacy: false, saved: nil, autoExposure: true, exposureOrigin: Self.manual31, aiTracking: true)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        // L'exposition voulue est partie la première ; la relance attend derrière elle.
        #expect(runner.inFlight == .exposure(exposure))
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        #expect(!store.state.aiTracking)
        runner.answer(.exposure(exposure))
        #expect(runner.inFlight == .tracking(false))
        runner.answer(.tracking(false))
        for _ in 0..<10 {
            scheduler.advance(by: TrackingReconciler.rereadInterval)
            while let order = runner.inFlight {
                runner.answer(order)
            }
        }
        #expect(runner.orders == [false])
        #expect(controller.snapshot.aiTracking == .off)
        #expect(runner.refused.isEmpty)
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

    @Test("Réveil du Mac, suivi voulu : l'état est lu d'abord ; lu coupé, il est relancé, puis relu")
    func wakeResumesAndRereads() {
        let controller = trackingOn()
        // La caméra a perdu son suivi pendant la veille (bus USB endormi).
        runner.aiMode = .off
        controller.systemWoke()
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(log.lines.contains("Suivi IA : lu coupé alors qu'il est voulu, relancé."))
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        scheduler.advance(by: TrackingReconciler.settleDelay)
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(controller.snapshot.aiTracking == .on)
        #expect(runner.orders == [true, true])
    }

    @Test("Réveil du Mac sur une caméra déjà en suivi : lue activée, aucun « on » ne part")
    func wakeOnTrackingCameraSendsNothing() {
        let controller = trackingOn()
        controller.systemWoke()
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(runner.inFlight == nil)
        #expect(runner.orders == [true])
        #expect(controller.snapshot.aiTracking == .on)
        #expect(!log.lines.contains { $0.contains("Suivi IA : relance") && $0.contains("sortie de veille") })
    }

    @Test("obsbot-ai mis à jour (aiUpdated) : l'état est lu d'abord, « on » seulement s'il est lu coupé")
    func utilityUpdateReadsBeforeResuming() {
        let controller = trackingOn()
        controller.aiUpdated()
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(runner.inFlight == nil)
        #expect(runner.orders == [true])
        runner.aiMode = .off
        controller.aiUpdated()
        runner.answer(.trackingStatus)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(runner.orders == [true, true])
    }

    @Test("Réveil, lectures impossibles (utilitaire ancien) : le « on » part tout de suite, sans lecture")
    func wakeWithoutReadsResumesDirectly() {
        let controller = started(wanted: false)
        runner.answer(.trackingStatus, .unknownOrder)
        _ = controller.handle(.aiTracking(on: true), from: 1)
        runner.answer(.tracking(true))
        controller.systemWoke()
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(runner.trackingReads == 1)
        #expect(runner.orders == [true, true])
    }

    @Test("Réveil, lecture ratée : on s'en remet au « on » direct, sans attendre la relecture lente")
    func wakeReadFailureFallsBackToResume() {
        let controller = trackingOn()
        controller.systemWoke()
        runner.answer(.trackingStatus, .sdkError)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(controller.snapshot.aiTracking == .on)
        #expect(runner.orders == [true, true])
    }

    @Test("Réveil, premier « switching » puis lecture ratée : le « on » direct part tout de suite")
    func wakeSwitchingThenFailedReadResumes() {
        let controller = trackingOn()
        controller.systemWoke()
        runner.aiMode = .switching
        runner.answer(.trackingStatus)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: TrackingReconciler.settleDelay)
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus, .sdkError)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(runner.orders == [true, true])
        withExtendedLifetime(controller) {}
    }

    @Test("Réveil, lecture écartée (condition fausse au départ) : la raison est gardée, la lecture suivante ratée relance")
    func wakeDiscardedReadKeepsReason() {
        let queue = AIOrderQueue(runner: runner)
        let control = ControlTaker(runner: queue, scheduler: scheduler, isObsbotCenterRunning: { false }, log: log.sink)
        store.state = PersistedState(privacy: false, saved: nil, aiTracking: true)
        let tracking = TrackingReconciler(control: control, queue: queue, scheduler: scheduler, store: store, log: log.sink)
        let flicker = Flag(false)
        tracking.canOrder = {
            if flicker.value {
                flicker.value = false
                return false
            }
            return true
        }
        // Un ordre étranger occupe l'utilitaire : la lecture attend derrière lui.
        queue.run(on: true) { _ in }
        #expect(runner.inFlight == .tracking(true))
        tracking.reapply(reason: "sortie de veille", readFirst: true)
        // La condition se révèle fausse au départ de la lecture, puis redevient vraie : lecture écartée.
        flicker.value = true
        runner.answer(.tracking(true))
        #expect(runner.inFlight == nil)
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus, .sdkError)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
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
        // La lecture d'avant ne disait pas « activé » (la relance n'a pas tenu) : lu coupé, c'est un suivi perdu.
        let controller = trackingNeverHeld()
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(log.lines.contains("Suivi IA : lu coupé alors qu'il est voulu, relancé."))
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(controller.snapshot.aiTracking == .on)
        #expect(runner.orders == [true, true])
    }

    @Test("Relecture périodique : lu activé puis lu coupé → coupure hors de PTZBot adoptée, persistée, jamais relancée")
    func periodicOffAfterOnIsAdopted() {
        let controller = trackingOn()
        // Geste de la main (ou OBSBOT Center) : la caméra a perdu son suivi sans qu'aucun événement ne le signale.
        runner.aiMode = .off
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        #expect(runner.inFlight == .trackingStatus)
        runner.answer(.trackingStatus)
        #expect(runner.inFlight == nil)
        #expect(runner.orders == [true])
        #expect(!store.state.aiTracking)
        #expect(controller.snapshot.aiTracking == .off)
        #expect(log.lines.contains("Suivi IA : coupé hors de PTZBot (lu coupé après une lecture active), choix retenu « coupé »."))
        #expect(!log.lines.contains("Suivi IA : lu coupé alors qu'il est voulu, relancé."))
        // Les relectures suivantes ne relancent rien.
        for _ in 0..<3 {
            scheduler.advance(by: TrackingReconciler.rereadInterval)
            if let order = runner.inFlight {
                runner.answer(order)
            }
        }
        #expect(runner.orders == [true])
        // Au rebranchement suivant, rien ne repart : le choix est « coupé ».
        controller.cameraPresenceChanged(false)
        controller.cameraPresenceChanged(true)
        if let order = runner.inFlight {
            runner.answer(order)
        }
        #expect(runner.orders == [true])
        #expect(!store.state.aiTracking)
    }

    @Test("Lu coupé après un réveil, alors que la lecture précédente lisait activé → relancé (événement)")
    func offAfterWakeIsRelaunchedEvenAfterActiveRead() {
        let controller = trackingOn()
        runner.aiMode = .off
        controller.systemWoke()
        runner.answer(.trackingStatus)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(store.state.aiTracking)
        #expect(runner.orders == [true, true])
        #expect(!log.lines.contains { $0.contains("coupé hors de PTZBot") })
        withExtendedLifetime(controller) {}
    }

    @Test("Lu coupé après un rebranchement : le « on » repart sans lecture et le choix reste « activé »")
    func offAfterReplugIsRelaunched() {
        let controller = trackingOn()
        runner.aiMode = .off
        controller.cameraPresenceChanged(false)
        controller.cameraPresenceChanged(true)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(store.state.aiTracking)
        #expect(runner.orders == [true, true])
        #expect(!log.lines.contains { $0.contains("coupé hors de PTZBot") })
    }

    @Test("« on » envoyé par PTZBot que la caméra n'a pas tenu, puis lu coupé → relancé, pas adopté")
    func offAfterSentOnIsRelaunched() {
        let controller = trackingOn()
        // Les apps coupent puis rallument ; la caméra ne tient pas le dernier « on ». La dernière lecture lisait pourtant
        // « activé » avant ces deux ordres : elle ne vaut plus.
        _ = controller.handle(.aiTracking(on: false), from: 1)
        runner.answer(.tracking(false))
        _ = controller.handle(.aiTracking(on: true), from: 1)
        runner.answer(.tracking(true), effect: false)
        #expect(store.state.aiTracking)
        for _ in 0..<2 {
            scheduler.advance(by: TrackingReconciler.rereadInterval)
            if runner.inFlight == .trackingStatus {
                runner.answer(.trackingStatus)
            }
            if runner.inFlight == .tracking(true) {
                break
            }
        }
        #expect(runner.inFlight == .tracking(true))
        #expect(store.state.aiTracking)
        #expect(!log.lines.contains { $0.contains("coupé hors de PTZBot") })
        runner.answer(.tracking(true))
    }

    @Test("Relance sans effet, lue coupée deux fois de suite (jamais lue activée) → relancée, pas adoptée")
    func neverReadOnIsNotAdopted() {
        let controller = trackingNeverHeld()
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        runner.answer(.trackingStatus)
        #expect(runner.inFlight == .tracking(true))
        #expect(store.state.aiTracking)
        #expect(controller.snapshot.aiTracking == .off)
        #expect(!log.lines.contains { $0.contains("coupé hors de PTZBot") })
    }

    @Test("Relecture : voulu activé, toujours lu coupé juste après la relance → pas de nouvelle relance avant la relecture suivante")
    func rereadDoesNotLoop() {
        let controller = trackingNeverHeld()
        #expect(runner.inFlight == nil)
        scheduler.advance(by: TrackingReconciler.rereadInterval - 1)
        #expect(runner.orders == [true])
        scheduler.advance(by: 1)
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
        // L'utilitaire recompilé sait peut-être lire : la lecture reprend, et passe avant le « on ».
        controller.aiUpdated()
        #expect(runner.inFlight == .trackingStatus)
        #expect(runner.trackingReads == 2)
        runner.answer(.trackingStatus)
        #expect(runner.inFlight == nil)
        #expect(controller.snapshot.aiTracking == .on)
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

    // MARK: - Vérification de la position rétablie (sortie par le repli)

    /// Entrée en vie privée par le repli (−70° d'abord) : le SDK n'est plus prêt, la caméra reviendra à −70° au réveil.
    private func enterByFallback(_ controller: PTZController) {
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
    }

    /// Sortie demandée à `request` (horloge du test), puis attente de la fin de la sortie : la position mémorisée vient
    /// d'être renvoyée, sa vérification (2 s) commence.
    private func exitByFallback(_ controller: PTZController, requestedAt request: TimeInterval) {
        scheduler.advance(by: request - scheduler.now)
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.answer(.privacy(false))
        for _ in 0..<40 where controller.snapshot.privacy {
            scheduler.advance(by: 0.1)
        }
        #expect(!controller.snapshot.privacy)
    }

    /// Vérification de la position en cours : aucun ordre de suivi ne part, quoi qu'il arrive, pendant `duration`.
    private func expectNoTrackingOrder(for duration: TimeInterval) {
        var elapsed = 0.0
        while elapsed < duration {
            scheduler.advance(by: 0.1)
            elapsed += 0.1
            if runner.inFlight == .trackingStatus {
                runner.answer(.trackingStatus)
            }
            #expect(runner.inFlight != .tracking(true))
            #expect(runner.orders == [true, false])
        }
    }

    @Test("Vérification de la position rétablie : la minuterie de relecture qui tombe pendant ce temps ne relance pas le suivi")
    func readTimerDuringVerificationSendsNothing() {
        let controller = trackingOn()
        // La relecture lente tombe à 32 s (2 s + 30 s). La sortie est demandée pour que sa vérification (2 s) la contienne.
        enterByFallback(controller)
        exitByFallback(controller, requestedAt: 29)
        let verificationStart = scheduler.now
        #expect(verificationStart > 30.5 && verificationStart < 31.5)
        expectNoTrackingOrder(for: 32.5 - verificationStart)
        #expect(!controller.snapshot.privacy)
        // La vérification finie, le suivi reprend.
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(runner.refused.isEmpty)
    }

    @Test("Vérification de la position rétablie : le réveil du Mac pendant ce temps ne relance pas le suivi ; la fin de la vérification le fait")
    func wakeDuringVerificationSendsNothing() {
        let controller = trackingOn()
        enterByFallback(controller)
        exitByFallback(controller, requestedAt: 12)
        controller.systemWoke()
        expectNoTrackingOrder(for: 1.5)
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
        #expect(camera.position == PanTiltPosition(pan: 12, tilt: 4))
        #expect(runner.refused.isEmpty)
    }

    @Test("Un arrêt du joystick (move 0,0) pendant la vérification de la position ne fait pas reprendre le suivi")
    func joystickReleaseDuringVerificationSendsNothing() {
        let controller = trackingOn()
        enterByFallback(controller)
        exitByFallback(controller, requestedAt: 12)
        _ = controller.handle(.move(pan: 0, tilt: 0), from: 1)
        expectNoTrackingOrder(for: 1.5)
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true))
    }

    @Test("Réapplication reportée pendant un ordre des apps : elle part à la fin de cet ordre, une seule fois")
    func deferredReapplyStartsWhenOrderEnds() {
        let controller = trackingOn()
        enterByFallback(controller)
        exitByFallback(controller, requestedAt: 12)
        // Un ordre des apps part pendant la vérification, et dure plus qu'elle.
        #expect(controller.handle(.aiTracking(on: true), from: 1) == nil)
        #expect(runner.inFlight == .tracking(true))
        scheduler.advance(by: PrivacyReconciler.settleDelay + 0.1)
        // La position est rétablie : la reprise attend l'ordre en cours.
        let before = runner.orders.count
        #expect(runner.inFlight == .tracking(true))
        runner.answer(.tracking(true), .sdkError)
        #expect(runner.inFlight == .tracking(true))
        #expect(runner.orders.count == before + 1)
        runner.answer(.tracking(true))
        #expect(controller.snapshot.aiTracking == .on)
        scheduler.advance(by: TrackingReconciler.settleDelay)
        runner.answer(.trackingStatus)
        #expect(runner.orders.count == before + 1)
        #expect(runner.refused.isEmpty)
    }

    @Test("Relance « on » partie au moment de l'entrée en vie privée : repli d'abord, puis « off », puis la vie privée, dans cet ordre")
    func privacyEntryWithResumeInFlight() {
        let controller = started(wanted: true)
        #expect(runner.inFlight == .tracking(true))
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        // Un ordre est en vol : la protection à −70° part tout de suite, par le chemin de repli.
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyReconciler.privacyTilt)])
        runner.answer(.tracking(true))
        #expect(runner.inFlight == .tracking(false))
        runner.answer(.tracking(false))
        // L'ordre de vie privée native part une fois la protection placée.
        for _ in 0..<60 where runner.inFlight != .privacy(true) {
            scheduler.advance(by: 0.1)
        }
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true))
        #expect(runner.orders == [true, false])
        #expect(runner.privacyOrders == [true])
        #expect(runner.refused.isEmpty)
        #expect(store.state.aiTracking)
    }

    // MARK: - Cadence de la relecture

    @Test("Relecture : après 5 « switching » de suite, retour à la cadence de 30 s")
    func switchingReadsAreCapped() {
        let controller = started(wanted: false)
        defer { withExtendedLifetime(controller) {} }
        runner.aiMode = .switching
        runner.answer(.trackingStatus)
        for _ in 1..<TrackingReconciler.maxSwitchingReads {
            scheduler.advance(by: TrackingReconciler.settleDelay)
            #expect(runner.inFlight == .trackingStatus)
            runner.answer(.trackingStatus)
        }
        #expect(runner.trackingReads == TrackingReconciler.maxSwitchingReads)
        scheduler.advance(by: TrackingReconciler.settleDelay)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: TrackingReconciler.rereadInterval - TrackingReconciler.settleDelay)
        #expect(runner.inFlight == .trackingStatus)
        // Le compte repart de zéro dès qu'une lecture dit autre chose.
        runner.aiMode = .off
        runner.answer(.trackingStatus)
        runner.aiMode = .switching
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        runner.answer(.trackingStatus)
        scheduler.advance(by: TrackingReconciler.settleDelay)
        #expect(runner.inFlight == .trackingStatus)
    }

    @Test("Une relecture qui retourne tôt (rien ne peut partir) réarme quand même la minuterie : la boucle de 30 s ne meurt pas")
    func earlyReadRearmsTimer() {
        let queue = AIOrderQueue(runner: runner)
        let control = ControlTaker(runner: queue, scheduler: scheduler, isObsbotCenterRunning: { false }, log: log.sink)
        let tracking = TrackingReconciler(control: control, queue: queue, scheduler: scheduler, store: store, log: log.sink)
        let allowed = Flag(true)
        tracking.canOrder = { allowed.value }
        tracking.reapply(reason: "essai")
        runner.answer(.trackingStatus)
        allowed.value = false
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        #expect(runner.inFlight == nil)
        #expect(runner.trackingReads == 1)
        // Rien ne la relance : la minuterie tourne toujours, et la lecture part dès que c'est permis.
        allowed.value = true
        scheduler.advance(by: TrackingReconciler.rereadInterval)
        #expect(runner.inFlight == .trackingStatus)
    }
}

/// Un drapeau partagé avec une fermeture du réconciliateur.
@MainActor
private final class Flag {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}
