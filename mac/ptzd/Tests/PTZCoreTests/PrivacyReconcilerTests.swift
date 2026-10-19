import Foundation
import NacelleProtocol
import Testing
@testable import PTZCore

/// Vie privée V2 vue du contrôleur (spec § 6.5 bis) : entrée rapide (mode natif directement, SDK prêt et caméra
/// éveillée) ou repli (−70° d'abord), état réel lu par relectures serrées, un seul pilote de la position, sortie rapide
/// (la caméra reprend d'elle-même sa position d'entrée) ou position mémorisée renvoyée. L'utilitaire et la caméra simulés
/// sont fidèles aux vrais et aux mesures du 19/10 : un ordre à la fois, sessions du SDK, bascule et mouvements propres de
/// la caméra, réponses retardées, perdues ou en échec. Les constats des relectures (C1, I1 à I6, A à D, mineurs) ont
/// chacun leur scénario.
@MainActor
@Suite("Vie privée V2 : réconciliateur")
struct PrivacyReconcilerTests {
    let camera = FakeCamera()
    let scheduler = FakeScheduler()
    let runner = FakeAIRunner()
    let store = MemoryStateStore()
    let log = LogRecorder()
    let errors = ClientErrorBox()
    let published = SnapshotBox()

    /// La position d'avant la vie privée dans la plupart des scénarios (zoom 33 de `FakeCamera`).
    static let before = PanTiltPosition(pan: 12, tilt: 4)
    static let down = PanTiltPosition(pan: 12, tilt: PrivacyReconciler.privacyTilt)
    /// La pose du mode natif (85° vers le bas).
    static let native = PanTiltPosition(pan: 12, tilt: FakeAIRunner.nativeTilt)

    init() {
        runner.attach(camera: camera, scheduler: scheduler)
    }

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
        controller.onStateChange = { [published] in published.values.append($0) }
        return controller
    }

    /// Caméra branchée hors vie privée (position et zoom lus), suivi IA déjà coupé : la vie privée ne commence par
    /// aucune coupure.
    private func ready(sdk: Bool = true) -> PTZController {
        camera.position = Self.before
        let controller = makeController(sdk: sdk)
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.aiTracking(on: false), from: 1)
        runner.answer(.tracking(false))
        return controller
    }

    /// Attente d'une position stable : deux relectures (à 2 s puis 0,5 s plus tard).
    private func settle() {
        scheduler.advance(by: PrivacyReconciler.settleDelay + PrivacyReconciler.pollInterval)
    }

    /// Entrée rapide jusqu'au mode natif constaté, lectures automatiques : privacy on tout de suite (SDK prêt, caméra
    /// éveillée) ; la caméra est alors dans la pose du mode natif, au pan d'avant.
    private func enterNative(_ controller: PTZController, from client: ClientID = 1) {
        runner.autoReads = true
        _ = controller.handle(.privacy(on: true), from: client)
        runner.answer(.privacy(true))
        scheduler.advance(by: FakeAIRunner.descentTime + 0.1)
    }

    /// Après un ordre natif : la lecture en cours reçoit sa réponse, puis relectures serrées automatiques jusqu'à la
    /// bascule de la caméra simulée (0,5 s).
    private func untilSwitched() {
        if runner.inFlight == .status {
            runner.answer(.status)
        }
        runner.autoReads = true
        scheduler.advance(by: FakeAIRunner.switchTime + PrivacyReconciler.pollInterval)
    }

    /// Sortie jusqu'à la position rétablie, lectures automatiques : réveil, remontée, état `run` vers 1,7 s, marge.
    private func exit(_ controller: PTZController, from client: ClientID = 1) {
        runner.autoReads = true
        _ = controller.handle(.privacy(on: false), from: client)
        runner.answer(.privacy(false))
        scheduler.advance(by: FakeAIRunner.wakeStateTime + PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin)
    }

    /// Mène les ordres de l'utilitaire pendant `seconds` : chaque ordre reçoit `reply(ordre)`, le temps avance par
    /// dixièmes de seconde.
    private func drive(_ seconds: Double, reply: (FakeAIRunner.Order) -> AIResult = { _ in .success }) {
        for _ in 0..<Int(seconds * 10) {
            while let order = runner.inFlight {
                runner.answer(order, reply(order))
            }
            scheduler.advance(by: 0.1)
        }
    }

    // MARK: - Entrée

    @Test("Entrée par le repli (SDK pas encore prêt) : −70° tout de suite (« protection en cours »), attente de la position par relectures serrées, privacy on, relectures jusqu'à la bascule ; natif publié après la lecture seulement")
    func enterNativeSequence() {
        let controller = ready()
        // L'utilitaire s'est arrêté après son délai d'inactivité : un ordre attendrait une session neuve.
        runner.idleStop()
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        // Protection immédiate : l'inclinaison, avant tout ordre à l'utilitaire. Pas encore vue à −70°.
        #expect(camera.absoluteCommands == [Self.down])
        #expect(runner.inFlight == nil)
        #expect(controller.snapshot.privacy)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason == .pending)
        #expect(store.state == PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 4, zoom: 33)))
        #expect(log.lines.contains { $0.contains("chemin de repli") && $0.contains("SDK pas encore prêt") })
        // Attente que la caméra soit à −70° : deux relectures stables, à 2 s puis 0,15 s plus tard.
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: PrivacyReconciler.pollInterval)
        #expect(runner.inFlight == .privacy(true))
        // Vue à −70° : l'objectif est détourné.
        #expect(controller.snapshot.privacyReason == nil)
        // Dès l'ordre parti, la caméra peut être en mode natif : retenu, pour qu'aucun ordre de position ne parte.
        #expect(store.state.native)
        runner.answer(.privacy(true))
        // Relectures serrées : la première 0,15 s après la réponse.
        scheduler.advance(by: PrivacyReconciler.switchDelay - 0.01)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: 0.01)
        #expect(runner.inFlight == .status)
        // Lue avant la bascule (0,5 s) : encore run, simplement relue.
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(runner.privacyOrders == [true])
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
        #expect(controller.snapshot.privacyReason == nil)
        // La caméra descend d'elle-même vers 85° ; aucun ordre de position.
        scheduler.advance(by: 1)
        #expect(camera.position == Self.native)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(errors.values.isEmpty)
        #expect(runner.refused.isEmpty)
        #expect(runner.sessions == 2)
    }

    @Test("I2 : « image et micro coupés » n'est jamais publié avant une lecture privacy, même utilitaire froid et coupure du suivi en cours")
    func nativeNeverPublishedBeforeReading() {
        camera.position = Self.before
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        // Suivi IA inconnu : la coupure part d'abord, l'utilitaire est froid (aucune réponse) : le repli.
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(runner.inFlight == .tracking(false))
        #expect(camera.absoluteCommands == [Self.down])
        settle()
        // privacy on attend dans la file, derrière la coupure : jamais refusé, jamais croisé.
        #expect(runner.inFlight == .tracking(false))
        scheduler.advance(by: 20)
        runner.answer(.tracking(false))
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true))
        scheduler.advance(by: PrivacyReconciler.switchDelay)
        #expect(published.values.allSatisfy { $0.privacyMode != .native })
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
        #expect(runner.refused.isEmpty)
    }

    @Test("Sans le SDK : l'inclinaison seule (spec § 6.5), « protection en cours » jusqu'à −70° vu, puis raison noSDK ; aucun ordre natif")
    func enterWithoutSDK() {
        let controller = ready(sdk: false)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason == .pending)
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(controller.snapshot.privacyReason == .noSDK)
        scheduler.advance(by: 120)
        #expect(runner.privacyOrders.isEmpty)
        #expect(runner.statusReads == 0)
        #expect(errors.values.isEmpty)
    }

    @Test("Hors vie privée, ni mode ni raison publiés")
    func nothingOutsidePrivacy() {
        let controller = makeController()
        #expect(controller.snapshot.privacyMode == nil)
        #expect(controller.snapshot.privacyReason == nil)
    }

    @Test("Repli, l'inclinaison n'est pas atteinte : le mode natif part quand même après le délai maximal, « protection en cours » jusqu'à la lecture")
    func tiltWaitLimit() {
        let controller = ready()
        runner.idleStop()
        camera.ignoreAbsoluteCommands = 1
        _ = controller.handle(.privacy(on: true), from: 1)
        scheduler.advance(by: PrivacyReconciler.tiltWaitLimit - 0.2)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: 0.2 + PrivacyReconciler.pollInterval)
        #expect(runner.inFlight == .privacy(true))
        #expect(log.lines.contains { $0.contains("non stabilisée") })
        #expect(controller.snapshot.privacyReason == .pending)
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
    }

    @Test("La coupure du suivi finit pendant l'attente de l'inclinaison : −70° renvoyé, l'attente reprend")
    func trackingCutDuringTiltWait() {
        camera.position = Self.before
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        scheduler.advance(by: 1)
        // Le suivi a remonté l'objectif pendant la coupure.
        camera.position = PanTiltPosition(pan: 12, tilt: 10)
        runner.answer(.tracking(false))
        #expect(camera.absoluteCommands == [Self.down, Self.down])
        settle()
        #expect(runner.inFlight == .privacy(true))
    }

    @Test("Pendant la vie privée : move, zoom et suivi IA refusés ; aucun ordre de position en mode natif, relectures lentes sur la même session")
    func commandsRefused() {
        let controller = ready()
        enterNative(controller)
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.zoom(value: 5), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.aiTracking(on: true), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.move(pan: 0, tilt: 0), from: 1) == nil)
        let reads = runner.statusReads
        scheduler.advance(by: 600)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(camera.relativeCommands.isEmpty)
        #expect(controller.snapshot.privacyMode == .native)
        // Une lecture toutes les 30 s, sans session neuve : une lecture ne réveille pas la caméra (mesuré).
        #expect(runner.statusReads - reads == Int(600 / PrivacyReconciler.rereadInterval))
        #expect(runner.sessions == 1)
    }

    @Test("Un zoom en attente du prochain créneau ne part pas une fois la vie privée demandée")
    func pendingZoomDropped() {
        let controller = ready()
        _ = controller.handle(.zoom(value: 10), from: 1)
        _ = controller.handle(.zoom(value: 20), from: 1)
        _ = controller.handle(.privacy(on: true), from: 1)
        scheduler.advance(by: 1)
        #expect(camera.zoomCommands == [10])
    }

    @Test("m6 : un arrêt du mouvement refusé n'est plus retenté une fois le mode natif demandé")
    func stopRetryCancelled() {
        let controller = ready()
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        camera.refuseRelative = true
        _ = controller.handle(.privacy(on: true), from: 1)
        settle()
        #expect(runner.inFlight == .privacy(true))
        let attempts = camera.relativeAttempts
        runner.autoReads = true
        runner.answer(.privacy(true))
        scheduler.advance(by: 60)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.relativeAttempts == attempts)
    }

    // MARK: - Second essai, repli

    @Test("Ordre natif sans effet (lu run jusqu'au bout de la bascule) : jamais natif publié, second essai direct dans les 10 s, sans ordre de position ; réussi : natif")
    func secondAttempt() {
        let controller = ready()
        runner.autoReads = true
        _ = controller.handle(.privacy(on: true), from: 1)
        let sentAt = scheduler.now
        // L'utilitaire répond « ok » mais la caméra ne bascule pas : rien n'est supposé.
        runner.answer(.privacy(true), effect: false)
        scheduler.advance(by: PrivacyReconciler.switchLimit - 0.1)
        #expect(runner.inFlight == nil)
        #expect(controller.snapshot.privacyMode == .tilt)
        scheduler.advance(by: 0.1 + PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin)
        #expect(runner.inFlight == .privacy(true))
        #expect(scheduler.now - sentAt < 10)
        #expect(runner.privacyOrders == [true, true])
        runner.answer(.privacy(true))
        scheduler.advance(by: FakeAIRunner.switchTime + PrivacyReconciler.pollInterval)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(errors.values.isEmpty)
        #expect(camera.absoluteCommands.isEmpty)
    }

    @Test("Deux essais ratés (erreurs du SDK) : avertissement au demandeur, raison failed, −70° posé et vérifié sans fin")
    func fallbackToTilt() {
        let controller = ready()
        runner.autoReads = true
        _ = controller.handle(.privacy(on: true), from: 7)
        runner.answer(.privacy(true), .sdkError)
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin)
        // Le second essai a fait bouger la caméra.
        runner.answer(.privacy(true), .sdkError)
        camera.position = PanTiltPosition(pan: 12, tilt: 10)
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval)
        #expect(errors.values.count == 1)
        #expect(errors.values.first?.0 == 7)
        #expect(errors.values.first?.1 == .uvcFailed)
        #expect(errors.values.first?.2 == PrivacyFailureText.fallbackToTilt)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(!store.state.native)
        // Pas d'ordre de position avant la marge de la remontée, puis −70°, que la caméra ignore une fois : la
        // vérification du § 6.5 le renvoie.
        #expect(camera.absoluteCommands.isEmpty)
        camera.ignoreAbsoluteCommands = 1
        scheduler.advance(by: PrivacyReconciler.riseMargin)
        #expect(camera.absoluteCommands == [Self.down])
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(camera.absoluteCommands == [Self.down, Self.down])
        scheduler.advance(by: PrivacyReconciler.privacyBackoff[0])
        #expect(controller.snapshot.tilt == PrivacyReconciler.privacyTilt)
        #expect(controller.snapshot.privacyReason == .failed)
        #expect(runner.privacyOrders == [true, true])
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Lecture pendant la bascule (encore run juste après privacy on) : relue, aucun ordre de position, aucun second essai")
    func lateStatusDuringSwitch() {
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 1)
        // L'ordre a pris, mais la caméra bascule plus lentement que mesuré.
        runner.answer(.privacy(true), effect: false)
        scheduler.advance(by: PrivacyReconciler.switchDelay)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .tilt)
        runner.state = .privacy
        scheduler.advance(by: PrivacyReconciler.pollInterval)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        runner.autoReads = true
        scheduler.advance(by: 60)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(runner.privacyOrders == [true])
    }

    @Test("Réponse perdue alors que la caméra a basculé : la lecture constate le mode natif, pas de second essai")
    func lostReplyButSwitched() {
        let controller = ready()
        runner.autoReads = true
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.lose(.privacy(true))
        scheduler.advance(by: FakeAIRunner.switchTime + PrivacyReconciler.pollInterval)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(runner.privacyOrders == [true])
        #expect(errors.values.isEmpty)
        // Le délai dépassé a coûté une session neuve, comme au vrai utilitaire.
        #expect(runner.sessions == 2)
    }

    // MARK: - C1 : sortie pendant une entrée

    enum EntryOutcome: CaseIterable, Sendable {
        case lateSuccess, lostButSwitched, timeoutWithoutEffect, sdkError
    }

    @Test("C1 : sortie pendant une entrée native : aucun ordre croisé, privacy off après la réponse, caméra éveillée à sa position d'avant, rien renvoyé", arguments: EntryOutcome.allCases)
    func exitDuringEntry(outcome: EntryOutcome) {
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(runner.inFlight == .privacy(true))
        scheduler.advance(by: 1)
        #expect(controller.handle(.privacy(on: false), from: 2) == nil)
        // L'ordre parti n'est pas annulé : la sortie attend sa réponse, rien n'est refusé.
        #expect(runner.inFlight == .privacy(true))
        #expect(runner.refused.isEmpty)
        #expect(controller.snapshot.privacy)
        switch outcome {
        case .lateSuccess: runner.answer(.privacy(true))
        case .lostButSwitched: runner.lose(.privacy(true))
        case .timeoutWithoutEffect: runner.answer(.privacy(true), .timeout, effect: false)
        case .sdkError: runner.answer(.privacy(true), .sdkError)
        }
        // La sortie part tout de suite, quel que soit le résultat de l'entrée.
        #expect(runner.inFlight == .privacy(false))
        runner.autoReads = true
        runner.answer(.privacy(false))
        #expect(controller.snapshot.privacy)
        scheduler.advance(by: FakeAIRunner.wakeStateTime + PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin)
        #expect(!controller.snapshot.privacy)
        #expect(controller.snapshot.privacyMode == nil)
        #expect(runner.state == .run)
        // L'entrée n'avait pas encore agi, ou la caméra a repris d'elle-même sa position d'entrée : rien à renvoyer.
        #expect(camera.position == Self.before)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(camera.zoomCommands.isEmpty)
        #expect(store.state == PersistedState(privacy: false, saved: nil))
        #expect(runner.refused.isEmpty)
        #expect(errors.values.isEmpty)
    }

    @Test("C1, variante : réapplication native en cours au branchement, sortie : privacy off après la réponse, jamais d'image noire laissée")
    func exitDuringReapplication() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: false)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.answer(.tracking(false))
        settle()
        #expect(runner.inFlight == .privacy(true))
        _ = controller.handle(.privacy(on: false), from: 2)
        runner.answer(.privacy(true))
        #expect(runner.inFlight == .privacy(false))
        runner.autoReads = true
        runner.answer(.privacy(false))
        scheduler.advance(by: 5)
        #expect(!controller.snapshot.privacy)
        #expect(runner.state == .run)
        #expect(camera.absoluteCommands.last == PanTiltPosition(pan: 12, tilt: 3))
        #expect(runner.refused.isEmpty)
    }

    // MARK: - I1, D : sortie native

    @Test("Sortie native : privacy off, relectures serrées jusqu'à run (vers 1,7 s), aucun ordre de position pendant la remontée ; revenue d'elle-même à sa position d'avant, rien n'est renvoyé")
    func exitNativeSequence() {
        let controller = ready()
        enterNative(controller)
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.answer(.privacy(false))
        // La caméra remonte d'elle-même à sa position d'entrée en 1,1 s, l'état passe à run vers 1,7 s.
        scheduler.advance(by: FakeAIRunner.wakeStateTime)
        #expect(camera.position == Self.before)
        #expect(controller.snapshot.privacy)
        scheduler.advance(by: 2 * PrivacyReconciler.pollInterval)
        #expect(!controller.snapshot.privacy)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(camera.zoomCommands.isEmpty)
        #expect(runner.sessions == 1)
    }

    @Test("I1 : réponse de privacy off perdue alors que la caméra s'est réveillée : la lecture constate run, la sortie aboutit")
    func exitLostReplyButAwake() {
        let controller = ready()
        enterNative(controller)
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.lose(.privacy(false))
        scheduler.advance(by: 1.5)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(controller.snapshot.privacy)
        scheduler.advance(by: 1.5)
        #expect(!controller.snapshot.privacy)
        #expect(camera.position == Self.before)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(errors.values.isEmpty)
    }

    @Test("I1 : caméra restée en vie privée après deux essais : vie privée en vigueur, publiée native (vrai), erreur exacte ; un nouvel ordre de sortie retente")
    func exitFailsCameraStaysPrivate() {
        let controller = ready()
        enterNative(controller)
        _ = controller.handle(.privacy(on: false), from: 9)
        runner.answer(.privacy(false), .sdkError)
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval + PrivacyReconciler.retryDelay)
        runner.answer(.privacy(false), .sdkError)
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval)
        #expect(controller.snapshot.privacy)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(store.state.privacy)
        #expect(store.state.native)
        #expect(errors.values.count == 1)
        #expect(errors.values.first?.0 == 9)
        #expect(errors.values.first?.2 == PrivacyFailureText.exitFailed)
        #expect(camera.absoluteCommands.isEmpty)
        // Un nouvel essai de l'utilisateur repart de zéro.
        scheduler.advance(by: 1)
        _ = controller.handle(.privacy(on: false), from: 9)
        #expect(runner.inFlight == .privacy(false))
        runner.answer(.privacy(false))
        scheduler.advance(by: 5)
        #expect(!controller.snapshot.privacy)
    }

    @Test("D : état et inclinaison illisibles pendant la sortie : jamais « natif » ni « levée » ; erreur « état illisible » ; vers un état sûr ; un nouvel ordre de sortie retente")
    func exitWithUnreadableState() {
        let controller = ready()
        enterNative(controller)
        published.values.removeAll()
        runner.stateUnreadable = true
        runner.pitchUnreadable = true
        _ = controller.handle(.privacy(on: false), from: 9)
        runner.answer(.privacy(false))
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval + PrivacyReconciler.retryDelay)
        runner.answer(.privacy(false))
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval)
        // Deux essais : la vie privée reste en vigueur, l'erreur exacte est montrée.
        #expect(errors.values.map(\.2) == [PrivacyFailureText.exitUnreadable])
        #expect(controller.snapshot.privacy)
        // Vers un état sûr : relectures, puis un ordre natif (sans effet si elle y est déjà).
        scheduler.advance(by: 2 * PrivacyReconciler.retryDelay)
        #expect(runner.inFlight == .privacy(true))
        runner.stateUnreadable = false
        runner.answer(.privacy(true))
        scheduler.advance(by: 2)
        #expect(controller.snapshot.privacyMode == .native)
        // Pendant tout ce temps : ni « natif » publié, ni la vie privée levée, ni aucun ordre de position, et les
        // lectures ratées n'ont pas rouvert de session.
        let beforeTruth = published.values.prefix { $0.privacyMode != .native }
        #expect(beforeTruth.allSatisfy { $0.privacy && $0.privacyMode == .tilt })
        #expect(camera.absoluteCommands.isEmpty)
        #expect(runner.refused.isEmpty)
        #expect(runner.sessions == 1)
        // Plus d'état sans issue : la sortie se retente, et aboutit une fois l'état lisible.
        _ = controller.handle(.privacy(on: false), from: 9)
        runner.answer(.privacy(false))
        scheduler.advance(by: 5)
        #expect(!controller.snapshot.privacy)
    }

    @Test("D : état illisible (vieux micrologiciel) mais inclinaison lue : la pose de 85° confirme l'entrée, le retour à la position d'entrée confirme la sortie, sans session neuve")
    func witnessConfirms() {
        runner.stateUnreadable = true
        let controller = ready()
        runner.autoReads = true
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.answer(.privacy(true))
        // Avant la descente (1,1 s), la nacelle est encore à sa position d'entrée : hors de la pose du mode natif.
        scheduler.advance(by: 1)
        #expect(controller.snapshot.privacyMode == .tilt)
        scheduler.advance(by: 0.3)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(log.lines.contains { $0.contains("pose du mode natif") })
        // Sortie : la nacelle remonte en 1,1 s, mais l'état ne passe à run que vers 1,7 s ; le seul témoin ne confirme
        // le réveil qu'après `witnessWakeDelay`.
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.answer(.privacy(false))
        scheduler.advance(by: PrivacyReconciler.witnessWakeDelay - 0.1)
        #expect(controller.snapshot.privacy)
        #expect(camera.absoluteCommands.isEmpty)
        scheduler.advance(by: 0.1 + 2 * PrivacyReconciler.pollInterval)
        #expect(!controller.snapshot.privacy)
        // Revenue d'elle-même à sa position d'entrée (inclinaison du SDK comprise) : rien n'est renvoyé.
        #expect(camera.position == Self.before)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(errors.values.isEmpty)
        #expect(runner.sessions == 1)
    }

    // MARK: - C : rebranchement, démarrage

    @Test("C : coupure d'alimentation en mode natif : au rebranchement, −70° tout de suite (« protection en cours »), puis le mode natif, sans lecture d'abord")
    func replugAfterPowerCut() {
        let controller = ready()
        enterNative(controller)
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        runner.powerCycle()
        published.values.removeAll()
        camera.isPresent = true
        let commands = runner.received.count
        controller.cameraPresenceChanged(true)
        // Aucune lecture d'abord (4 s de session neuve) : l'inclinaison part dans le même tour (repli).
        #expect(camera.absoluteCommands == [Self.down])
        #expect(!store.state.native)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason == .pending)
        #expect(log.lines.contains { $0.contains("chemin de repli") && $0.contains("branchée") })
        // Le suivi IA a pu revenir avec le redémarrage : recoupé.
        #expect(Array(runner.received.dropFirst(commands)) == [.tracking(false)])
        scheduler.advance(by: 4)
        runner.answer(.tracking(false))
        #expect(runner.inFlight == .privacy(true))
        #expect(controller.snapshot.privacyReason == nil)
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
        // « Objectif détourné » seulement après −70° vu, « image et micro coupés » seulement après la lecture.
        let shown = published.values.filter(\.privacy).map { $0.privacyReason }
        #expect(shown.first == .pending)
        #expect(published.values.prefix { $0.privacyReason != nil }.allSatisfy { $0.privacyMode == .tilt })
        #expect(runner.refused.isEmpty)
    }

    @Test("Démarrage, mode natif retenu, caméra encore en vie privée : l'état réel seulement ; ni inclinaison, ni coupure du suivi")
    func startupStillNative() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        runner.state = .privacy
        camera.position = Self.native
        let controller = makeController()
        #expect(controller.snapshot.privacy)
        controller.cameraPresenceChanged(true)
        // État inconnu : ni « objectif détourné », ni « image et micro coupés ».
        #expect(controller.snapshot.privacyReason == .pending)
        #expect(runner.inFlight == .status)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        runner.autoReads = true
        scheduler.advance(by: 600)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(runner.privacyOrders.isEmpty)
        #expect(runner.orders.isEmpty)
        #expect(controller.snapshot.aiTracking == .unknown)
    }

    @Test("Démarrage, mode natif retenu, caméra redémarrée éveillée : lue run, marge, coupure du suivi, puis le mode natif directement (SDK prêt)")
    func startupRebootedAwake() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        camera.position = PanTiltPosition(pan: 0, tilt: 0)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason == .pending)
        #expect(camera.absoluteCommands.isEmpty)
        scheduler.advance(by: PrivacyReconciler.riseMargin)
        #expect(runner.inFlight == .tracking(false))
        // Lue éveillée, la session du SDK a répondu : le chemin rapide, privacy on derrière la coupure, sans −70°.
        #expect(camera.absoluteCommands.isEmpty)
        runner.answer(.tracking(false))
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.absoluteCommands.isEmpty)
    }

    @Test("I2 : branchement, vie privée par l'inclinaison retenue : −70° tout de suite, puis le mode natif")
    func replugWithTiltRetained() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        let down = PanTiltPosition(pan: 12, tilt: PrivacyReconciler.privacyTilt)
        #expect(camera.absoluteCommands == [down])
        #expect(runner.inFlight == .tracking(false))
        runner.answer(.tracking(false))
        settle()
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
        #expect(store.state.saved == SavedPosition(pan: 12, tilt: 3, zoom: nil))
    }

    @Test("Sans SDK, mode natif retenu : l'inclinaison directement (rien ne peut lire ni réveiller la caméra)")
    func startupNativeWithoutSDK() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        let controller = makeController(sdk: false)
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyReconciler.privacyTilt)])
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(controller.snapshot.privacyReason == .noSDK)
        #expect(!store.state.native)
    }

    // MARK: - A, I3, I6 : obsbot-ai ancien

    @Test("A : ancien obsbot-ai, −70° ignoré une fois par la caméra : « ordre inconnu », puis −70° renvoyé et vérifié, caméra à −70°")
    func staleIgnoredTilt() {
        let controller = ready()
        camera.ignoreAbsoluteCommands = 1
        _ = controller.handle(.privacy(on: true), from: 1)
        scheduler.advance(by: PrivacyReconciler.tiltWaitLimit)
        runner.answer(.privacy(true), .unknownOrder)
        #expect(controller.snapshot.privacyReason == .pending)
        scheduler.advance(by: 300)
        #expect(camera.absoluteCommands.count >= 2)
        #expect(camera.absoluteCommands.allSatisfy { $0 == Self.down })
        #expect(camera.position == Self.down)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason == .updating)
        #expect(runner.privacyOrders == [true])
    }

    @Test("A, variante : ancien obsbot-ai, inclinaison refusée : « ordre inconnu », puis −70° renvoyé et vérifié, caméra à −70°")
    func staleRefusedTilt() {
        let controller = ready()
        camera.failNextWrite = .ioKit(-536870212)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true), .unknownOrder)
        scheduler.advance(by: 300)
        #expect(camera.absoluteCommands.last == Self.down)
        #expect(camera.position == Self.down)
        #expect(controller.snapshot.privacyReason == .updating)
    }

    @Test("I3 : premier ordre sur l'ancien obsbot-ai (chemin rapide), −70° ignoré : raison updating une fois −70° vu, sans avertissement ; aiUpdated : mode natif")
    func staleUtilityThenUpdated() {
        let controller = ready()
        camera.ignoreAbsoluteCommands = 1
        _ = controller.handle(.privacy(on: true), from: 1)
        // Chemin rapide : privacy on tout de suite ; l'ancien utilitaire ne le connaît pas.
        runner.answer(.privacy(true), .unknownOrder)
        // −70° tout de suite (ignoré par la caméra), puis vérifié et renvoyé.
        #expect(camera.absoluteCommands == [Self.down])
        #expect(controller.snapshot.privacyReason == .pending)
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(camera.absoluteCommands == [Self.down, Self.down])
        scheduler.advance(by: PrivacyReconciler.privacyBackoff[0])
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason == .updating)
        #expect(errors.values.isEmpty)
        #expect(!store.state.native)
        // Pas de second essai sur cet utilitaire.
        scheduler.advance(by: 60)
        #expect(runner.privacyOrders == [true])
        #expect(runner.statusReads == 0)
        // PTZBot a recompilé obsbot-ai : utilitaire relancé, mode natif retenté.
        let resets = runner.resets
        controller.aiUpdated()
        #expect(runner.resets == resets + 1)
        #expect(runner.inFlight == .privacy(true))
        #expect(controller.snapshot.privacyReason == nil)
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
        #expect(errors.values.isEmpty)
    }

    @Test("I3 : vie privée active d'une 1.1.0 (state.json sans native) pendant la recompilation : réapplication, raison updating, aucun repli annoncé")
    func staleUtilityAtStartup() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyReconciler.privacyTilt)])
        runner.answer(.tracking(false))
        settle()
        runner.answer(.privacy(true), .unknownOrder)
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(controller.snapshot.privacyReason == .updating)
        #expect(!log.lines.contains { $0.contains("impossible") })
    }

    @Test("I6 : obsbot-ai durablement ancien : chaque entrée protège à −70°, un seul « ordre inconnu », sortie directe sans privacy off")
    func durablyStaleUtility() {
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 1)
        settle()
        runner.answer(.privacy(true), .unknownOrder)
        scheduler.advance(by: 2)
        // La sortie va directement à la position mémorisée : cet utilitaire n'a pas pu mettre la caméra en mode natif.
        #expect(controller.handle(.privacy(on: false), from: 1) == nil)
        #expect(!controller.snapshot.privacy)
        #expect(camera.absoluteCommands.last == Self.before)
        // Nouvelle entrée : la protection à −70°, sans nouvel « ordre inconnu » ni attente.
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(camera.absoluteCommands.last == Self.down)
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(controller.snapshot.privacyReason == .updating)
        scheduler.advance(by: 60)
        #expect(runner.privacyOrders == [true])
        #expect(errors.values.isEmpty)
    }

    @Test("m7 : obsbot-ai redevenu ancien alors que la caméra peut être en mode natif : la sortie échoue avec « obsbot-ai n'est pas à jour »")
    func exitNeedsUpdate() {
        let controller = ready()
        enterNative(controller)
        _ = controller.handle(.privacy(on: false), from: 4)
        runner.answer(.privacy(false), .unknownOrder)
        #expect(errors.values.map(\.2) == [PrivacyFailureText.exitNeedsUpdate])
        #expect(controller.snapshot.privacy)
        #expect(camera.absoluteCommands.isEmpty)
    }

    // MARK: - Inclinaison refusée

    @Test("Repli avec le SDK, inclinaison refusée : le mode natif part tout de suite, « protection en cours » jusqu'à la lecture")
    func tiltRefusedWithSDK() {
        let controller = ready()
        runner.idleStop()
        camera.failNextWrite = .ioKit(-536870212)
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        #expect(runner.inFlight == .privacy(true))
        #expect(camera.absoluteCommands.isEmpty)
        #expect(controller.snapshot.privacyReason == .pending)
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
    }

    @Test("A : inclinaison refusée (repli) et mode natif qui ne prend pas, deux essais : −70° renvoyé et vérifié dès le repli")
    func tiltRefusedThenNativeFails() {
        let controller = ready()
        runner.idleStop()
        runner.autoReads = true
        runner.pitchUnreadable = true
        camera.failNextWrite = .ioKit(-536870212)
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.answer(.privacy(true), effect: false)
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin)
        // Un échec du mode natif : le second essai, direct.
        #expect(camera.absoluteCommands.isEmpty)
        runner.answer(.privacy(true), effect: false)
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(camera.position == Self.down)
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(controller.snapshot.privacyReason == .failed)
    }

    // MARK: - I4, I5

    @Test("I4 : inclinaison retenue puis passage au mode natif, puis sortie : la position d'avant la vie privée est rétablie")
    func exitAfterPromotionRestoresSaved() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: 40))
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.answer(.tracking(false))
        settle()
        runner.autoReads = true
        runner.answer(.privacy(true))
        scheduler.advance(by: 2)
        #expect(controller.snapshot.privacyMode == .native)
        exit(controller)
        #expect(!controller.snapshot.privacy)
        #expect(camera.absoluteCommands.last == PanTiltPosition(pan: 12, tilt: 3))
        #expect(camera.zoomCommands.last == 40)
    }

    @Test("I5 : entrée qui a pris sans réponse, lectures ratées, second essai en échec : la lecture constate le mode natif, aucun PanTilt à la caméra endormie")
    func neverFallBackWhileAsleep() {
        let controller = ready()
        runner.pitchUnreadable = true
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.lose(.privacy(true))
        drive(PrivacyReconciler.switchLimit + 3 * PrivacyReconciler.retryDelay) { $0 == .status ? .timeout : .sdkError }
        #expect(runner.privacyOrders == [true, true])
        runner.autoReads = true
        drive(PrivacyReconciler.readBackoff[0] + 1)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.absoluteCommands.isEmpty)
    }

    @Test("I5 : sortie après un repli : privacy off part quand même (quel que soit le mode noté), puis la position mémorisée")
    func exitAfterFallbackSendsPrivacyOff() {
        let controller = ready()
        runner.autoReads = true
        _ = controller.handle(.privacy(on: true), from: 1)
        runner.answer(.privacy(true), .sdkError)
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin)
        runner.answer(.privacy(true), .sdkError)
        scheduler.advance(
            by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin
                + PrivacyReconciler.settleDelay
        )
        #expect(controller.snapshot.privacyReason == .failed)
        _ = controller.handle(.privacy(on: false), from: 1)
        #expect(runner.inFlight == .privacy(false))
        runner.answer(.privacy(false))
        // Deux inclinaisons de suite pour juger la nacelle immobile (m4) : la seconde lecture, 0,15 s après la première.
        scheduler.advance(by: PrivacyReconciler.switchDelay + PrivacyReconciler.pollInterval)
        #expect(!controller.snapshot.privacy)
        #expect(camera.absoluteCommands.last == Self.before)
    }

    // MARK: - B : relecture de l'état réel

    @Test("B : réveil par un autre moyen pendant le mode natif : vu à la relecture lente, puis le mode natif directement (SDK prêt, caméra lue éveillée)")
    func externalWakeReprotects() {
        let controller = ready()
        enterNative(controller)
        runner.wakeExternally()
        scheduler.advance(by: FakeAIRunner.wakeStateTime)
        #expect(controller.snapshot.privacyMode == .native)
        scheduler.advance(by: PrivacyReconciler.rereadInterval)
        // Lue éveillée : plus jamais « image et micro coupés », la reprotection part.
        #expect(controller.snapshot.privacyMode == .tilt)
        scheduler.advance(by: PrivacyReconciler.riseMargin)
        #expect(runner.inFlight == .privacy(true))
        #expect(log.lines.contains { $0.contains("reprotection") })
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(runner.sessions == 1)
    }

    @Test("B : à la connexion d'un client, au réveil du Mac, et à une entrée répétée, l'état est relu tout de suite", arguments: [0, 1, 2])
    func immediateReread(trigger: Int) {
        let controller = ready()
        enterNative(controller)
        runner.wakeExternally()
        scheduler.advance(by: FakeAIRunner.wakeStateTime)
        switch trigger {
        case 0: controller.clientConnected()
        case 1: controller.systemWoke()
        default: _ = controller.handle(.privacy(on: true), from: 2)
        }
        #expect(controller.snapshot.privacyMode == .tilt)
        scheduler.advance(by: PrivacyReconciler.riseMargin)
        #expect(runner.inFlight == .privacy(true))
    }

    @Test("B : en mode natif, une relecture qui confirme ne change rien à l'état publié")
    func rereadKeepsPublishedState() {
        let controller = ready()
        enterNative(controller)
        published.values.removeAll()
        controller.clientConnected()
        scheduler.advance(by: 300)
        #expect(published.values.isEmpty)
        #expect(controller.snapshot.privacyMode == .native)
    }

    // MARK: - Le dernier choix gagne, débranchement, coupure du suivi

    @Test("M2 : retour à la vie privée pendant la bascule de la sortie : elle va à son terme, puis le mode natif ; saved reste celle d'avant")
    func reenterDuringRise() {
        let controller = ready()
        enterNative(controller)
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.answer(.privacy(false))
        scheduler.advance(by: 1)
        #expect(controller.handle(.privacy(on: true), from: 2) == nil)
        scheduler.advance(by: 1.5)
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(store.state.saved == SavedPosition(pan: 12, tilt: 4, zoom: 33))
    }

    @Test("Sortie pendant l'attente de l'inclinaison (repli) : l'attente va à son terme, privacy off (jamais en mode natif), puis la position d'avant, sans ordre croisé")
    func exitDuringTiltSettle() {
        let controller = ready()
        runner.idleStop()
        runner.autoReads = true
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(camera.absoluteCommands == [Self.down])
        scheduler.advance(by: 1)
        _ = controller.handle(.privacy(on: false), from: 1)
        scheduler.advance(by: 1.5)
        #expect(runner.inFlight == .privacy(false))
        runner.answer(.privacy(false))
        // Jamais en mode natif : la première lecture est déjà `run`, la nacelle est jugée immobile à la seconde (m4).
        scheduler.advance(by: PrivacyReconciler.switchDelay + PrivacyReconciler.pollInterval)
        #expect(!controller.snapshot.privacy)
        #expect(runner.privacyOrders == [false])
        #expect(camera.absoluteCommands == [Self.down, Self.before])
        #expect(runner.refused.isEmpty)
    }

    @Test("M3, m2 : débranchement pendant une sortie : la réponse est écartée, la sortie reprend au rebranchement, sans attente de 12 s")
    func unplugDuringExit() {
        let controller = ready()
        enterNative(controller)
        _ = controller.handle(.privacy(on: false), from: 1)
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        runner.powerCycle()
        #expect(controller.snapshot.privacy)
        #expect(store.state.privacy)
        camera.isPresent = true
        controller.cameraPresenceChanged(true)
        #expect(runner.inFlight == .privacy(false))
        runner.answer(.privacy(false))
        // Deux inclinaisons de suite pour juger la nacelle immobile (m4) : la seconde lecture, 0,5 s après la première.
        scheduler.advance(by: PrivacyReconciler.switchDelay + PrivacyReconciler.pollInterval)
        #expect(!controller.snapshot.privacy)
        #expect(camera.absoluteCommands.last == Self.before)
    }

    @Test("Débranchement pendant l'entrée : la réponse est écartée ; au rebranchement (éveillée et droite), −70° tout de suite puis le mode natif")
    func unplugDuringEntry() {
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(runner.inFlight == .privacy(true))
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: 60)
        #expect(controller.snapshot.privacy)
        runner.powerCycle()
        camera.isPresent = true
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == [Self.down])
        runner.autoReads = true
        drive(10)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(errors.values.isEmpty)
    }

    @Test("M12 : coupure du suivi pendant le mode natif : l'état réel est relu ; réveillée, la vie privée est réappliquée")
    func trackingCutDuringNativeRereads() {
        camera.position = Self.before
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        // La coupure échoue au bout d'1 s : son nouvel essai partira 3 s plus tard, pendant le mode natif.
        scheduler.advance(by: 1)
        runner.answer(.tracking(false), .sdkError)
        // Le suivi a pu détourner l'objectif : −70° renvoyé, l'attente reprend ; privacy on ensuite.
        settle()
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
        runner.autoReads = false
        scheduler.advance(by: ControlTaker.retryDelay)
        #expect(runner.inFlight == .tracking(false))
        // Elle a réveillé la caméra.
        runner.wakeExternally()
        scheduler.advance(by: FakeAIRunner.wakeStateTime)
        runner.answer(.tracking(false))
        #expect(runner.inFlight == .status)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .tilt)
        scheduler.advance(by: PrivacyReconciler.riseMargin)
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.absoluteCommands.allSatisfy { $0 == Self.down })
    }

    @Test("m1 : aiUpdated pendant la coupure du suivi de l'entrée : la coupure est refaite")
    func aiUpdatedDuringEntryCut() {
        camera.position = Self.before
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(runner.inFlight == .tracking(false))
        controller.aiUpdated()
        #expect(runner.inFlight == .tracking(false))
        runner.answer(.tracking(false))
        #expect(controller.snapshot.aiTracking == .off)
        #expect(runner.orders == [false, false])
    }

    @Test("m5 : pendant une sortie, la raison failed n'est jamais publiée")
    func noFailedReasonDuringExit() {
        let controller = ready()
        enterNative(controller)
        runner.stateUnreadable = true
        runner.pitchUnreadable = true
        published.values.removeAll()
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.answer(.privacy(false))
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval + PrivacyReconciler.retryDelay)
        runner.answer(.privacy(false))
        scheduler.advance(by: PrivacyReconciler.switchLimit - 0.1)
        #expect(published.values.allSatisfy { $0.privacyReason != .failed })
    }

    // MARK: - Position mémorisée et state.json

    @Test("saved n'est écrit qu'à une entrée demandée : ni réapplication, ni repli, ni passage au natif")
    func savedOnlyOnUserEntry() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: 40))
        camera.position = PanTiltPosition(pan: 50, tilt: 20)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.answer(.tracking(false))
        settle()
        runner.autoReads = true
        runner.answer(.privacy(true), .sdkError)
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin)
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
        #expect(store.state.saved == SavedPosition(pan: 12, tilt: 3, zoom: 40))
    }

    @Test("state.json du premier prototype (mode native) : l'état réel est lu avant tout ordre de position")
    func prototypeStateFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ptzd-proto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "state.json")
        try Data(#"{"mode":"native","privacy":true,"saved":{"pan":12,"tilt":3,"zoom":null}}"#.utf8).write(to: url)
        runner.nativePrivacyAvailable = true
        runner.state = .privacy
        let controller = PTZController(
            camera: camera, scheduler: scheduler, ai: runner, store: JSONFileStateStore(url: url, log: { _ in }),
            settings: MotionSettings(), isObsbotCenterRunning: { false }, log: log.sink
        )
        controller.cameraPresenceChanged(true)
        #expect(runner.inFlight == .status)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.absoluteCommands.isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Sans SDK (spec § 6.5)

    @Test("Sans SDK, entrée refusée par la caméra : rien n'est activé, l'enregistrement est annulé")
    func entryRefusedWithoutSDK() {
        let controller = ready(sdk: false)
        camera.failNextWrite = .ioKit(-536870212)
        #expect(controller.handle(.privacy(on: true), from: 1)?.code == .uvcFailed)
        #expect(!controller.snapshot.privacy)
        #expect(!store.state.privacy)
    }

    @Test("Sans SDK, sortie refusée : la vie privée reste en vigueur et l'erreur remonte")
    func exitRefusedWithoutSDK() {
        let controller = ready(sdk: false)
        _ = controller.handle(.privacy(on: true), from: 1)
        camera.failNextWrite = .ioKit(-536870212)
        #expect(controller.handle(.privacy(on: false), from: 1)?.code == .uvcFailed)
        #expect(controller.snapshot.privacy)
        #expect(store.state.privacy)
    }

    @Test("Zoom refusé à la sortie : l'objectif reste tourné vers le bas")
    func zoomRefusedAtExit() {
        let controller = ready(sdk: false)
        _ = controller.handle(.privacy(on: true), from: 1)
        camera.failNextWrite = .ioKit(-536870212)
        _ = controller.handle(.privacy(on: false), from: 1)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(controller.snapshot.privacy)
    }

    @Test("Position inconnue : pan 0 à l'entrée, 0°/0° à la sortie, zoom inchangé")
    func unknownPosition() {
        camera.failReads = true
        let controller = makeController(sdk: false)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 0, tilt: PrivacyReconciler.privacyTilt)])
        _ = controller.handle(.privacy(on: false), from: 1)
        #expect(camera.absoluteCommands.last == PanTiltPosition(pan: 0, tilt: 0))
        #expect(camera.zoomCommands.isEmpty)
    }

    @Test("Un échec d'écriture de state.json n'empêche pas de protéger l'image")
    func saveFailureStillProtects() {
        store.failSaves = true
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(runner.inFlight == .privacy(true))
        #expect(log.lines.contains { $0.contains("state.json") })
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
    }

    // MARK: - Troisième relecture : I1, m1, m2, m4, m11, réserve 1

    @Test("I1 : mode natif constaté, relectures ratées et caméra réveillée par un autre moyen : « image et micro coupés » ne reste jamais affiché au-delà de deux relectures lentes ; privacy on ensuite")
    func steadyReadsFailThenWake() {
        let controller = ready()
        enterNative(controller)
        let resets = runner.resets
        runner.stateUnreadable = true
        runner.pitchUnreadable = true
        runner.wakeExternally()
        // Deux relectures lentes ratées au plus : la première dans les 30 s, la seconde 30 s plus tard.
        scheduler.advance(by: 2 * PrivacyReconciler.rereadInterval + 1)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason != nil)
        #expect(runner.resets == resets + 1)
        let shown = published.values.count
        scheduler.advance(by: 600)
        // Plus jamais « natif » tant que rien ne se lit ; lecture, puis un nouvel ordre natif, sans aucun ordre de position.
        #expect(published.values.dropFirst(shown).allSatisfy { $0.privacyMode != .native })
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(runner.privacyOrders.count > 1)
        #expect(camera.absoluteCommands.isEmpty)
    }

    @Test("I1 : deux lectures ratées de suite en mode natif : « protection en cours », session du SDK neuve pour la lecture suivante, qui republie « natif » si la caméra y est")
    func steadyReadsFailNewSession() {
        let controller = ready()
        enterNative(controller)
        runner.autoReads = false
        #expect(runner.sessions == 1)
        let resets = runner.resets
        runner.stateUnreadable = true
        runner.pitchUnreadable = true
        // Première lecture ratée : rien ne change, la même session sert encore.
        scheduler.advance(by: PrivacyReconciler.rereadInterval)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(runner.resets == resets)
        // Seconde, de suite : plus d'affirmation, session neuve.
        scheduler.advance(by: PrivacyReconciler.rereadInterval)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason == .pending)
        #expect(runner.resets == resets + 1)
        #expect(runner.inFlight == .status)
        #expect(runner.sessions == 2)
        runner.stateUnreadable = false
        runner.pitchUnreadable = false
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(controller.snapshot.privacyReason == nil)
        #expect(runner.privacyOrders == [true])
        #expect(camera.absoluteCommands.isEmpty)
    }

    @Test("I1 : une lecture ratée isolée, puis réussie, ne change rien : même session, « natif » toujours publié")
    func isolatedFailedReadChangesNothing() {
        let controller = ready()
        enterNative(controller)
        runner.autoReads = false
        let resets = runner.resets
        published.values.removeAll()
        runner.stateUnreadable = true
        runner.pitchUnreadable = true
        scheduler.advance(by: PrivacyReconciler.rereadInterval)
        runner.answer(.status)
        runner.stateUnreadable = false
        runner.pitchUnreadable = false
        scheduler.advance(by: PrivacyReconciler.rereadInterval)
        runner.answer(.status)
        // Le compte des échecs repart à zéro : un échec de plus ne suffit pas.
        runner.stateUnreadable = true
        runner.pitchUnreadable = true
        scheduler.advance(by: PrivacyReconciler.rereadInterval)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(published.values.allSatisfy { $0.privacyMode == .native })
        #expect(runner.resets == resets)
        #expect(runner.sessions == 1)
    }

    @Test("m1 : caméra absente au démarrage de ptzd (mode natif retenu), puis branchée : elle sort d'une mise sous tension, −70° tout de suite, sans lecture d'abord")
    func absentAtStartupThenPlugged() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        camera.isPresent = false
        let controller = makeController()
        controller.cameraAbsentAtStartup()
        runner.powerCycle()
        camera.isPresent = true
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyReconciler.privacyTilt)])
        #expect(!store.state.native)
        #expect(controller.snapshot.privacyReason == .pending)
        #expect(runner.inFlight == .tracking(false))
        runner.answer(.tracking(false))
        settle()
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
    }

    @Test("m1, contraste : caméra présente au démarrage (mode natif retenu), puis redémarrée par ptzd : l'état réel d'abord, aucun ordre de position")
    func presentAtStartupReadsFirst() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        runner.state = .privacy
        camera.position = Self.native
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(runner.inFlight == .status)
    }

    @Test("m2 : entrée répétée par un second client, mode natif possible : la coupure du suivi attend que la caméra soit vue éveillée, aucun ordre à la caméra endormie")
    func repeatedEntryWhileNativeDefersTrackingCut() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        runner.state = .privacy
        camera.position = Self.native
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(controller.handle(.privacy(on: true), from: 2) == nil)
        // L'état réel est relu ; rien d'autre ne part.
        #expect(runner.inFlight == .status)
        runner.autoReads = true
        runner.answer(.status)
        scheduler.advance(by: 2 * PrivacyReconciler.rereadInterval)
        #expect(runner.orders.isEmpty)
        #expect(controller.snapshot.privacyMode == .native)
        // Réveillée par un autre moyen, puis lue éveillée à la relecture lente : la coupure du suivi part alors.
        runner.wakeExternally()
        scheduler.advance(by: 2 * PrivacyReconciler.rereadInterval)
        #expect(runner.orders == [false])
    }

    @Test("m4 : sortie d'un mode natif avec une remontée plus longue que l'état run : la position n'est relue qu'une fois la nacelle immobile, à sa position d'entrée ; rien renvoyé")
    func exitAfterLongRise() {
        let controller = ready()
        // Remontée lente : 89° à 30°/s, environ 3 s, alors que l'état `run` se lit vers 1,7 s.
        runner.riseSpeed = 30
        enterNative(controller)
        #expect(camera.position == Self.native)
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.answer(.privacy(false))
        scheduler.advance(by: 2.5)
        // Nacelle encore en mouvement : rien n'est relu ni renvoyé (le faux signale tout ordre pendant la remontée).
        #expect(controller.snapshot.privacy)
        scheduler.advance(by: 10)
        #expect(!controller.snapshot.privacy)
        #expect(camera.position == Self.before)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(camera.zoomCommands.isEmpty)
        #expect(log.lines.contains { $0.contains("rien à renvoyer") })
    }

    @Test("m11 : le faux signale tout ordre UVC pendant le mode natif, mais pas après un rebranchement")
    func fakeFlagsOrdersWhileNative() {
        let controller = ready()
        enterNative(controller)
        withKnownIssue {
            try? camera.setPanTiltAbsolute(panDegrees: 0, tiltDegrees: 0)
        }
        withKnownIssue {
            try? camera.setPanTiltRelative(PanTiltRelative(panDirection: 0, panSpeed: 0, tiltDirection: 0, tiltSpeed: 0))
        }
        withKnownIssue {
            try? camera.setZoom(10)
        }
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        runner.powerCycle()
        camera.isPresent = true
        // Rebranchée : éveillée et droite, les ordres sont permis (aucun problème signalé).
        try? camera.setPanTiltAbsolute(panDegrees: 0, tiltDegrees: PrivacyReconciler.privacyTilt)
    }

    @Test("Réserve 1 : une caméra branchée juste après la sortie de veille du Mac est traitée comme un démarrage : l'état réel d'abord, pas de −70° immédiat")
    func replugRightAfterMacWake() {
        let controller = ready()
        enterNative(controller)
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        controller.systemWoke()
        runner.powerCycle()
        runner.autoReads = false
        scheduler.advance(by: 5)
        camera.isPresent = true
        let commands = camera.absoluteCommands
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == commands)
        #expect(runner.inFlight == .status)
        #expect(store.state.native)
        #expect(controller.snapshot.privacyReason == .pending)
        // Lue éveillée (elle sort de la veille du Mac) : marge, coupure du suivi, puis le mode natif directement.
        runner.answer(.status)
        scheduler.advance(by: PrivacyReconciler.riseMargin)
        runner.answer(.tracking(false))
        #expect(runner.inFlight == .privacy(true))
        #expect(camera.absoluteCommands == commands)
        runner.answer(.privacy(true))
        untilSwitched()
        #expect(controller.snapshot.privacyMode == .native)
    }

    // MARK: - Accélération (spec § 6.5 bis, banc du 19/10)

    @Test("Entrée rapide : SDK prêt et caméra éveillée, privacy on tout de suite, aucun ordre UVC ; natif lu à la première relecture serrée qui suit la bascule")
    func fastEntry() {
        let controller = ready()
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        // Ni −70° ni attente : le mode natif part de la position courante.
        #expect(runner.inFlight == .privacy(true))
        #expect(camera.absoluteCommands.isEmpty)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason == .pending)
        #expect(store.state.native)
        runner.answer(.privacy(true))
        // Relectures serrées : la première 0,15 s après la réponse.
        scheduler.advance(by: PrivacyReconciler.pollInterval - 0.01)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: 0.01)
        #expect(runner.inFlight == .status)
        runner.autoReads = true
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .tilt)
        // La caméra simulée bascule en 0,5 s : natif lu à la relecture de 0,6 s, pas plus tard.
        scheduler.advance(by: FakeAIRunner.switchTime + PrivacyReconciler.pollInterval - 0.15)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(controller.snapshot.privacyReason == nil)
        // Elle descend d'elle-même vers 85°, pan inchangé.
        scheduler.advance(by: 1)
        #expect(camera.position == Self.native)
        scheduler.advance(by: 120)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(camera.relativeCommands.isEmpty)
        #expect(camera.zoomCommands.isEmpty)
        #expect(runner.privacyOrders == [true])
        #expect(runner.refused.isEmpty)
        #expect(runner.sessions == 1)
        #expect(errors.values.isEmpty)
    }

    @Test("Repli après deux échecs du mode natif (entrée rapide) : second essai direct, puis −70° et sa vérification, avertissement")
    func fastEntryFallsBackAfterTwoFailures() {
        let controller = ready()
        runner.autoReads = true
        _ = controller.handle(.privacy(on: true), from: 7)
        // L'utilitaire répond « ok », mais la caméra ne bascule pas.
        runner.answer(.privacy(true), effect: false)
        // Dernière relecture serrée après le délai de la bascule, puis la marge.
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin)
        // Second essai, direct lui aussi : aucun ordre de position entre les deux.
        #expect(runner.inFlight == .privacy(true))
        #expect(camera.absoluteCommands.isEmpty)
        runner.answer(.privacy(true), effect: false)
        scheduler.advance(by: PrivacyReconciler.switchLimit + PrivacyReconciler.pollInterval)
        #expect(errors.values.map(\.2) == [PrivacyFailureText.fallbackToTilt])
        #expect(camera.absoluteCommands.isEmpty)
        // Repli : −70° après la marge, puis vérifié.
        scheduler.advance(by: PrivacyReconciler.riseMargin)
        #expect(camera.absoluteCommands == [Self.down])
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason == .failed)
        #expect(controller.snapshot.tilt == PrivacyReconciler.privacyTilt)
        #expect(runner.privacyOrders == [true, true])
        #expect(log.lines.contains { $0.contains("repli") })
    }

    @Test("Sortie rapide : privacy off, run lu, position et zoom relus à moins de 2° de saved : aucun ordre UVC, vie privée levée vers 1,9 s")
    func fastExitWithoutResend() {
        let controller = ready()
        enterNative(controller)
        let start = scheduler.now
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.autoReads = true
        runner.answer(.privacy(false))
        // La caméra reprend d'elle-même sa position d'entrée ; l'état run se lit vers 1,7 s, la nacelle immobile.
        scheduler.advance(by: FakeAIRunner.wakeStateTime - 0.1)
        #expect(controller.snapshot.privacy)
        scheduler.advance(by: 0.1 + 2 * PrivacyReconciler.pollInterval)
        #expect(!controller.snapshot.privacy)
        #expect(scheduler.now - start < 2.1)
        #expect(camera.position == Self.before)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(camera.zoomCommands.isEmpty)
        #expect(store.state == PersistedState(privacy: false, saved: nil))
        // Rien à vérifier ensuite : aucun ordre n'est parti.
        scheduler.advance(by: 60)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(controller.snapshot.pan == Self.before.pan)
        #expect(controller.snapshot.tilt == Self.before.tilt)
        #expect(controller.snapshot.zoom == 33)
        #expect(errors.values.isEmpty)
    }

    @Test("Sortie après une entrée par repli (utilitaire pas encore prêt) : la caméra revient à −70°, la position mémorisée est renvoyée et vérifiée")
    func exitAfterFallbackEntryResends() {
        camera.position = Self.before
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        // Suivi IA inconnu, utilitaire froid : la coupure part, le SDK n'est pas prêt, −70° tout de suite.
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(runner.inFlight == .tracking(false))
        #expect(camera.absoluteCommands == [Self.down])
        #expect(log.lines.contains { $0.contains("repli") })
        runner.answer(.tracking(false))
        settle()
        runner.autoReads = true
        runner.answer(.privacy(true))
        scheduler.advance(by: FakeAIRunner.descentTime + 0.1)
        #expect(controller.snapshot.privacyMode == .native)
        let entry = camera.absoluteCommands
        #expect(!entry.isEmpty && entry.allSatisfy { $0 == Self.down })
        exit(controller)
        #expect(!controller.snapshot.privacy)
        #expect(Array(camera.absoluteCommands.dropFirst(entry.count)) == [Self.before])
        #expect(camera.zoomCommands == [33])
        #expect(log.lines.contains { $0.contains("position mémorisée renvoyée") })
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(camera.position == Self.before)
        #expect(Array(camera.absoluteCommands.dropFirst(entry.count)) == [Self.before])
    }

    @Test("Sortie rapide, zoom changé pendant le mode natif : zoom et position mémorisés renvoyés")
    func fastExitZoomChanged() {
        let controller = ready()
        enterNative(controller)
        // L'app OBSBOT a changé le zoom pendant le mode natif.
        camera.zoomValue = 50
        exit(controller)
        #expect(!controller.snapshot.privacy)
        #expect(camera.zoomCommands == [33])
        #expect(camera.absoluteCommands == [Self.before])
    }

    @Test("Sortie rapide, inclinaison du SDK loin de saved (relecture UVC périmée) : la position mémorisée est renvoyée")
    func fastExitWitnessDisagrees() {
        let controller = ready()
        enterNative(controller)
        // La caméra s'arrête plus haut que sa position d'entrée ; la relecture UVC, elle, rend encore l'ancienne valeur.
        runner.riseSpeed = 1000
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.autoReads = true
        runner.answer(.privacy(false))
        scheduler.advance(by: FakeAIRunner.wakeStateTime - 0.2)
        camera.position = PanTiltPosition(pan: 12, tilt: 10)
        camera.staleRead = Self.before
        scheduler.advance(by: 0.2 + 2 * PrivacyReconciler.pollInterval + PrivacyReconciler.riseMargin)
        #expect(!controller.snapshot.privacy)
        #expect(camera.absoluteCommands == [Self.before])
    }

    @Test("Repli quand l'état réel ne se lit pas (témoin seul) : l'entrée suivante incline à −70° d'abord")
    func unreadableStateFallsBack() {
        runner.stateUnreadable = true
        let controller = ready()
        enterNative(controller)
        scheduler.advance(by: 1)
        #expect(controller.snapshot.privacyMode == .native)
        exit(controller)
        scheduler.advance(by: 2)
        #expect(!controller.snapshot.privacy)
        let sent = camera.absoluteCommands
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(camera.absoluteCommands == sent + [Self.down])
        #expect(runner.inFlight == nil)
        #expect(log.lines.contains { $0.contains("illisible") && $0.contains("repli") })
    }

    @Test("Sortie rapide depuis une position d'entrée très basse (dans la zone de la pose native) : réveil accepté, rien renvoyé")
    func fastExitFromLowPose() {
        let low = PanTiltPosition(pan: 12, tilt: -83)
        camera.position = low
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.aiTracking(on: false), from: 1)
        runner.answer(.tracking(false))
        enterNative(controller)
        #expect(controller.snapshot.privacyMode == .native)
        exit(controller)
        #expect(!controller.snapshot.privacy)
        #expect(camera.position == low)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(errors.values.isEmpty)
    }

    @Test("Branchement sans SDK (repli retenu), SDK installé ensuite, mode natif, sortie : l'entrée suivante reprend le chemin rapide")
    func plugReasonDoesNotLinger() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 4, zoom: 33))
        let controller = makeController(sdk: false)
        controller.cameraPresenceChanged(true)
        settle()
        #expect(controller.snapshot.privacyReason == .noSDK)
        // PTZBot installe et compile obsbot-ai.
        runner.nativePrivacyAvailable = true
        controller.aiUpdated()
        runner.autoReads = true
        drive(5)
        #expect(controller.snapshot.privacyMode == .native)
        exit(controller)
        drive(5)
        #expect(!controller.snapshot.privacy)
        let sent = camera.absoluteCommands
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(camera.absoluteCommands == sent)
        #expect(runner.inFlight == .privacy(true))
    }

    @Test("Journal : une ligne par étape de l'entrée et de la sortie, avec les durées ; rien aux relectures lentes")
    func journal() {
        let controller = ready()
        let before = log.lines.count
        enterNative(controller)
        let entry = Array(log.lines.dropFirst(before))
        #expect(entry.contains { $0.contains("entrée demandée") })
        #expect(entry.contains { $0.contains("chemin rapide") })
        #expect(entry.contains { $0.contains("privacy on envoyé") })
        #expect(entry.contains { $0.contains("privacy on rendu") && $0.contains(" s") })
        #expect(entry.contains { $0.contains("état privacy lu") && $0.contains(" s") })
        #expect(entry.contains { $0.contains("au total") })
        let quiet = log.lines.count
        scheduler.advance(by: 10 * PrivacyReconciler.rereadInterval)
        #expect(log.lines.count == quiet, "\(log.lines)")
        exit(controller)
        let exitLines = Array(log.lines.dropFirst(quiet))
        #expect(exitLines.contains { $0.contains("sortie demandée") })
        #expect(exitLines.contains { $0.contains("privacy off envoyé") })
        #expect(exitLines.contains { $0.contains("état run lu") })
        #expect(exitLines.contains { $0.contains("position relue") && $0.contains("mémorisée") })
        #expect(exitLines.contains { $0.contains("levée") && $0.contains("au total") })
        // Une ligne par étape : pas une par relecture serrée.
        #expect(entry.count <= 8)
        #expect(exitLines.count <= 8)
        // Aucune adresse dans le journal.
        #expect(log.lines.allSatisfy { $0.firstMatch(of: #/\d{1,3}(\.\d{1,3}){3}/#) == nil })
    }

    @Test("Réserve 1, contraste : un rebranchement longtemps après la sortie de veille reste une coupure d'alimentation : −70° tout de suite")
    func replugLongAfterMacWake() {
        let controller = ready()
        enterNative(controller)
        controller.systemWoke()
        scheduler.advance(by: PrivacyReconciler.wakeWindow + 1)
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        runner.powerCycle()
        camera.isPresent = true
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(controller.snapshot.privacyReason == .pending)
    }
    // MARK: - vp6 : utilitaire toujours chaud, I3, journal du démarrage

    /// ptzd lancé avec le SDK : l'utilitaire reste chargé tant que ptzd tourne (spec § 6.9).
    private func makeWarmController() -> PTZController {
        runner.keepsWarm = true
        camera.position = Self.before
        return makeController()
    }

    @Test("Toujours chaud : à la présence de la caméra au démarrage, l'utilitaire est préparé, et prêt 4 s plus tard sans aucun pilotage")
    func warmAtStartup() {
        let controller = makeWarmController()
        #expect(runner.prewarms == 0)
        controller.cameraPresenceChanged(true)
        #expect(runner.prewarms == 1)
        #expect(!runner.isReady)
        #expect(runner.received.isEmpty)
        scheduler.advance(by: FakeAIRunner.loadTime + 0.1)
        #expect(runner.isReady)
        #expect(runner.received.isEmpty)
        #expect(runner.sessions == 1)
        // Des heures sans client : toujours prêt.
        scheduler.advance(by: 6 * 3600)
        #expect(runner.isReady)
        #expect(runner.sessions == 1)
    }

    @Test("Toujours chaud : la première entrée, utilitaire jamais piloté, prend le chemin rapide (aucun ordre UVC), derrière la coupure du suivi")
    func firstEntryIsFast() {
        let controller = makeWarmController()
        controller.cameraPresenceChanged(true)
        scheduler.advance(by: 60)
        #expect(runner.isReady)
        runner.autoReads = true
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        // Suivi IA inconnu : coupé d'abord (file), puis privacy on directement, sans −70°.
        #expect(camera.absoluteCommands.isEmpty)
        #expect(runner.inFlight == .tracking(false))
        runner.answer(.tracking(false))
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true))
        scheduler.advance(by: FakeAIRunner.descentTime + 0.1)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(log.lines.contains { $0.contains("chemin rapide") })
        #expect(!log.lines.contains { $0.contains("chemin de repli") })
    }

    @Test("Toujours chaud : rebranchement, mise à jour d'obsbot-ai et connexion d'un client relancent l'utilitaire ; caméra absente, rien")
    func warmAgainAfterRestartEvents() {
        let controller = makeWarmController()
        controller.cameraPresenceChanged(true)
        scheduler.advance(by: 5)
        #expect(runner.isReady)
        // Débranchement : session perdue, mais rien à chercher sans caméra.
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        runner.powerCycle()
        scheduler.advance(by: 300)
        #expect(runner.prewarms == 1)
        #expect(!runner.isReady)
        // Rebranchement : session neuve, préparée aussitôt.
        camera.isPresent = true
        controller.cameraPresenceChanged(true)
        #expect(runner.prewarms == 2)
        scheduler.advance(by: 5)
        #expect(runner.isReady)
        // Mise à jour d'obsbot-ai : l'utilitaire repart du nouveau programme.
        controller.aiUpdated()
        #expect(runner.prewarms == 3)
        #expect(!runner.isReady)
        scheduler.advance(by: 5)
        #expect(runner.isReady)
        #expect(runner.sessions == 3)
    }

    @Test("Toujours chaud : un utilitaire mort seul est relancé par la veille de ptzd, client ou non")
    func warmWatchdog() {
        let controller = makeWarmController()
        controller.cameraPresenceChanged(true)
        scheduler.advance(by: 5)
        runner.idleStop()
        #expect(!runner.isReady)
        scheduler.advance(by: PTZController.warmCheckInterval + FakeAIRunner.loadTime + 0.1)
        #expect(runner.isReady)
        #expect(runner.sessions == 2)
        // Un client qui se connecte le relance sans attendre la veille.
        runner.idleStop()
        controller.clientConnected()
        scheduler.advance(by: FakeAIRunner.loadTime + 0.1)
        #expect(runner.isReady)
        #expect(runner.sessions == 3)
    }

    @Test("Toujours chaud : en vie privée aussi, un message d'un client prépare l'utilitaire ; caméra absente, jamais")
    func warmInPrivacy() {
        let controller = makeWarmController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        let before = runner.prewarms
        controller.prewarmAI()
        #expect(runner.prewarms == before + 1)
        camera.isPresent = false
        controller.prewarmAI()
        #expect(runner.prewarms == before + 1)
    }

    @Test("Pas toujours chaud (par défaut) : la présence de la caméra ne prépare rien, comme avant")
    func notWarmByDefault() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        controller.aiUpdated()
        scheduler.advance(by: 600)
        #expect(runner.prewarms == 0)
    }

    @Test("I3 : sortie rapide, inclinaison du SDK illisible : rien n'est conclu, la position mémorisée est renvoyée et vérifiée")
    func fastExitPitchUnreadable() {
        let controller = ready()
        enterNative(controller)
        runner.pitchUnreadable = true
        exit(controller)
        #expect(!controller.snapshot.privacy)
        // La relecture UVC seule ne suffit pas : renvoi, comme avant la sortie rapide.
        #expect(camera.absoluteCommands == [Self.before])
        #expect(log.lines.contains { $0.contains("inclinaison SDK illisible") && $0.contains("position mémorisée renvoyée") })
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(camera.position == Self.before)
        #expect(errors.values.isEmpty)
    }

    @Test("Journal du démarrage, mode natif retenu et caméra lue en vie privée : « état lu : privacy, rien à faire », aucun privacy on")
    func startupLogsNativeState() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        runner.state = .privacy
        camera.position = Self.native
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.answer(.status)
        #expect(log.lines.contains { $0.contains("état lu : privacy, rien à faire") })
        runner.autoReads = true
        scheduler.advance(by: 600)
        #expect(runner.privacyOrders.isEmpty)
        #expect(camera.absoluteCommands.isEmpty)
        // La relecture lente ne répète pas la ligne.
        #expect(log.lines.filter { $0.contains("état lu :") }.count == 1)
    }

    @Test("Journal du démarrage, état dit par le témoin seul : « état lu : privacy (témoin) », toujours aucun privacy on")
    func startupLogsWitnessedState() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        runner.state = .privacy
        runner.stateUnreadable = true
        camera.position = Self.native
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.answer(.status)
        #expect(log.lines.contains { $0.contains("état lu : privacy (témoin), rien à faire") })
        #expect(runner.privacyOrders.isEmpty)
    }

    @Test("Journal du démarrage, caméra lue éveillée : « état lu : run, reprotection », puis le mode natif")
    func startupLogsAwakeState() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        camera.position = PanTiltPosition(pan: 0, tilt: 0)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        #expect(!log.lines.contains { $0.contains("état lu :") })
        runner.answer(.status)
        #expect(log.lines.contains { $0.contains("état lu : run, reprotection") })
        #expect(runner.privacyOrders.isEmpty)
        scheduler.advance(by: PrivacyReconciler.riseMargin)
        runner.answer(.tracking(false))
        #expect(runner.inFlight == .privacy(true))
    }

    @Test("Journal du démarrage, deux lectures ratées de suite : dit que l'état n'a pas été lu avant le privacy on de précaution")
    func startupLogsUnreadableState() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        runner.state = .privacy
        camera.position = Self.native
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.pitchUnreadable = true
        runner.stateUnreadable = true
        runner.answer(.status)
        scheduler.advance(by: PrivacyReconciler.retryDelay)
        runner.answer(.status)
        scheduler.advance(by: PrivacyReconciler.retryDelay)
        #expect(runner.inFlight == .privacy(true))
        #expect(log.lines.contains { $0.contains("état réel illisible") })
        #expect(log.lines.contains { $0.contains("état lu : illisible") && $0.contains("privacy on") })
    }

}

/// États publiés (tests).
@MainActor
final class SnapshotBox {
    var values: [StateSnapshot] = []
}
