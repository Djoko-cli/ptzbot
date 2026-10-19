import Foundation
import NacelleProtocol
import Testing
@testable import PTZCore

/// Vie privée V2 vue du contrôleur (spec § 6.5 bis) : protection à −70° d'abord, mode natif par-dessus, état réel lu,
/// un seul pilote de la position, sortie en séquence. L'utilitaire simulé est fidèle au vrai : un ordre à la fois,
/// réponses retardées, perdues ou en échec, état réel de la caméra. Les constats de la relecture du premier prototype
/// (C1, I1 à I6, mineurs) ont chacun leur scénario.
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

    /// Entrée jusqu'au mode natif constaté ; la caméra est alors à 90° (pose du mode natif).
    private func enterNative(_ controller: PTZController, from client: ClientID = 1) {
        _ = controller.handle(.privacy(on: true), from: client)
        settle()
        runner.answer(.privacy(true))
        runner.answer(.status)
        camera.position = PanTiltPosition(pan: 12, tilt: 90)
    }

    /// Sortie jusqu'au réveil constaté ; la caméra revient d'elle-même à −70°, sa position en entrant en mode natif.
    private func wake(_ controller: PTZController, from client: ClientID = 1) {
        _ = controller.handle(.privacy(on: false), from: client)
        runner.answer(.privacy(false))
        runner.answer(.status)
        camera.position = Self.down
    }

    // MARK: - Entrée

    @Test("Entrée avec le SDK : −70° tout de suite, attente de la position, privacy on, lecture ; natif publié après la lecture seulement")
    func enterNativeSequence() {
        let controller = ready()
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        // Protection immédiate : l'inclinaison, avant tout ordre à l'utilitaire.
        #expect(camera.absoluteCommands == [Self.down])
        #expect(runner.inFlight == nil)
        #expect(controller.snapshot.privacy)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason == nil)
        #expect(store.state == PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 4, zoom: 33)))
        // Attente que la caméra soit à −70° : deux relectures stables.
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: PrivacyReconciler.pollInterval)
        #expect(runner.inFlight == .privacy(true))
        // Dès l'ordre parti, la caméra peut être en mode natif : retenu, pour qu'aucun ordre de position ne parte.
        #expect(store.state.native)
        runner.answer(.privacy(true))
        #expect(runner.inFlight == .status)
        #expect(controller.snapshot.privacyMode == .tilt)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(controller.snapshot.privacyReason == nil)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(scheduler.pendingCount == 0)
        #expect(errors.values.isEmpty)
        #expect(runner.refused.isEmpty)
    }

    @Test("I2 : « image et micro coupés » n'est jamais publié avant une lecture privacy, même utilitaire froid et coupure du suivi en cours")
    func nativeNeverPublishedBeforeReading() {
        camera.position = Self.before
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        // Suivi IA inconnu : la coupure part d'abord, l'utilitaire est froid (aucune réponse).
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
        #expect(published.values.allSatisfy { $0.privacyMode != .native })
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(runner.refused.isEmpty)
    }

    @Test("Sans le SDK : l'inclinaison seule (spec § 6.5), raison noSDK, aucun ordre natif")
    func enterWithoutSDK() {
        let controller = ready(sdk: false)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(controller.snapshot.privacyMode == .tilt)
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

    @Test("L'inclinaison n'est pas atteinte : le mode natif part quand même après le délai maximal")
    func tiltWaitLimit() {
        let controller = ready()
        camera.ignoreAbsoluteCommands = 1
        _ = controller.handle(.privacy(on: true), from: 1)
        scheduler.advance(by: PrivacyReconciler.tiltWaitLimit - 0.1)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: 0.1)
        #expect(runner.inFlight == .privacy(true))
        #expect(log.lines.contains { $0.contains("non stabilisée") })
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

    @Test("Pendant la vie privée : move, zoom et suivi IA refusés ; aucun ordre de position en mode natif")
    func commandsRefused() {
        let controller = ready()
        enterNative(controller)
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.zoom(value: 5), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.aiTracking(on: true), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.move(pan: 0, tilt: 0), from: 1) == nil)
        scheduler.advance(by: 600)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(camera.relativeCommands.isEmpty)
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

    // MARK: - Second essai, repli

    @Test("Ordre natif sans effet (lecture run) : jamais natif publié, inclinaison remise, second essai dans les 10 s ; réussi : natif")
    func secondAttempt() {
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 1)
        settle()
        // L'utilitaire répond « ok » mais la caméra n'a pas basculé : rien n'est supposé.
        runner.answer(.privacy(true), effect: false)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .tilt)
        let failedAt = scheduler.now
        // Elle pouvait être en mode natif : on attend qu'elle soit stable avant tout ordre de position.
        settle()
        #expect(runner.inFlight == .privacy(true))
        #expect(scheduler.now - failedAt < 10)
        #expect(runner.privacyOrders == [true, true])
        runner.answer(.privacy(true))
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(errors.values.isEmpty)
        #expect(camera.absoluteCommands == [Self.down])
    }

    @Test("Deux essais ratés : avertissement au demandeur, raison failed, −70° remis et vérifié sans fin")
    func fallbackToTilt() {
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 7)
        settle()
        runner.answer(.privacy(true), .sdkError)
        runner.answer(.status)
        settle()
        runner.answer(.privacy(true), .sdkError)
        // Le second essai a fait bouger la caméra.
        camera.position = PanTiltPosition(pan: 12, tilt: 10)
        runner.answer(.status)
        #expect(errors.values.count == 1)
        #expect(errors.values.first?.0 == 7)
        #expect(errors.values.first?.1 == .uvcFailed)
        #expect(errors.values.first?.2 == PrivacyFailureText.fallbackToTilt)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason == .failed)
        #expect(!store.state.native)
        // Pas d'ordre de position avant la fin de son mouvement (délai maximal, elle reste à 10°), puis −70°, que la
        // caméra ignore une fois : la vérification du § 6.5 le renvoie.
        #expect(camera.absoluteCommands == [Self.down])
        camera.ignoreAbsoluteCommands = 1
        scheduler.advance(by: PrivacyReconciler.riseWaitLimit)
        #expect(camera.absoluteCommands == [Self.down, Self.down])
        scheduler.advance(by: PrivacyReconciler.settleDelay)
        #expect(camera.absoluteCommands == [Self.down, Self.down, Self.down])
        scheduler.advance(by: PrivacyReconciler.privacyBackoff[0])
        #expect(controller.snapshot.tilt == PrivacyReconciler.privacyTilt)
        #expect(runner.privacyOrders == [true, true])
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Réponse perdue alors que la caméra a basculé : la lecture constate le mode natif, pas de second essai")
    func lostReplyButSwitched() {
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 1)
        settle()
        runner.lose(.privacy(true))
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(runner.privacyOrders == [true])
        #expect(errors.values.isEmpty)
    }

    // MARK: - C1 : sortie pendant une entrée

    enum EntryOutcome: CaseIterable, Sendable {
        case lateSuccess, lostButSwitched, timeoutWithoutEffect, sdkError
    }

    @Test("C1 : sortie pendant une entrée native, utilitaire froid : aucun ordre croisé, privacy off après la réponse, caméra éveillée et position rétablie", arguments: EntryOutcome.allCases)
    func exitDuringEntry(outcome: EntryOutcome) {
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 1)
        settle()
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
        // La sortie part, quel que soit le résultat de l'entrée.
        #expect(runner.inFlight == .privacy(false))
        runner.answer(.privacy(false))
        runner.answer(.status)
        #expect(controller.snapshot.privacy)
        settle()
        #expect(!controller.snapshot.privacy)
        #expect(controller.snapshot.privacyMode == nil)
        #expect(runner.state == .run)
        #expect(camera.absoluteCommands == [Self.down, Self.before])
        #expect(camera.zoomCommands == [33])
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
        runner.answer(.privacy(false))
        runner.answer(.status)
        settle()
        #expect(!controller.snapshot.privacy)
        #expect(runner.state == .run)
        #expect(camera.absoluteCommands.last == PanTiltPosition(pan: 12, tilt: 3))
        #expect(runner.refused.isEmpty)
    }

    // MARK: - I1 : sortie native

    @Test("I1 : réponse de privacy off perdue alors que la caméra s'est réveillée : la lecture constate run, la sortie aboutit")
    func exitLostReplyButAwake() {
        let controller = ready()
        enterNative(controller)
        _ = controller.handle(.privacy(on: false), from: 1)
        runner.lose(.privacy(false))
        runner.answer(.status)
        // Elle revient d'elle-même de 90° : aucun ordre de position pendant ce temps.
        scheduler.advance(by: 3)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(controller.snapshot.privacy)
        camera.position = Self.down
        settle()
        #expect(!controller.snapshot.privacy)
        #expect(camera.absoluteCommands == [Self.down, Self.before])
        #expect(errors.values.isEmpty)
    }

    @Test("I1 : caméra restée en vie privée après deux essais : vie privée en vigueur, publiée native (vrai), erreur au demandeur")
    func exitFailsCameraStaysPrivate() {
        let controller = ready()
        enterNative(controller)
        _ = controller.handle(.privacy(on: false), from: 9)
        runner.answer(.privacy(false), .sdkError)
        runner.answer(.status)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: PrivacyReconciler.retryDelay)
        runner.answer(.privacy(false), .sdkError)
        runner.answer(.status)
        #expect(controller.snapshot.privacy)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(store.state.privacy)
        #expect(store.state.native)
        #expect(errors.values.count == 1)
        #expect(errors.values.first?.0 == 9)
        #expect(errors.values.first?.2 == PrivacyFailureText.exitFailed)
        #expect(camera.absoluteCommands == [Self.down])
        // Un nouvel essai de l'utilisateur repart de zéro.
        _ = controller.handle(.privacy(on: false), from: 9)
        #expect(runner.inFlight == .privacy(false))
    }

    @Test("I1 : état illisible pendant la sortie : jamais « natif » ni « levée » sur une image peut-être en direct ; relectures jusqu'à un état sûr")
    func exitWithUnreadableState() {
        let controller = ready()
        enterNative(controller)
        published.values.removeAll()
        _ = controller.handle(.privacy(on: false), from: 9)
        runner.lose(.privacy(false))
        runner.answer(.status, .timeout)
        scheduler.advance(by: PrivacyReconciler.retryDelay)
        runner.answer(.privacy(false))
        runner.answer(.status, .timeout)
        // Deux essais : la vie privée reste en vigueur, l'erreur est montrée.
        #expect(errors.values.map(\.2) == [PrivacyFailureText.exitFailed])
        #expect(controller.snapshot.privacy)
        // Vers un état sûr : relecture, puis un ordre natif (sans effet si elle y est déjà), puis relecture.
        scheduler.advance(by: PrivacyReconciler.retryDelay)
        runner.answer(.status, .timeout)
        #expect(controller.snapshot.privacyReason == .failed)
        scheduler.advance(by: PrivacyReconciler.retryDelay)
        runner.answer(.privacy(true))
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(controller.snapshot.privacyReason == nil)
        // Pendant tout ce temps : ni « natif » publié, ni la vie privée levée, ni aucun ordre de position.
        let beforeTruth = published.values.dropLast()
        #expect(beforeTruth.allSatisfy { $0.privacy && $0.privacyMode == .tilt })
        #expect(camera.absoluteCommands == [Self.down])
        #expect(runner.refused.isEmpty)
    }

    // MARK: - I2 : branchement

    @Test("I2 : branchement, vie privée par l'inclinaison retenue : −70° tout de suite, puis le mode natif")
    func replugWithTiltRetained() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(runner.inFlight == .tracking(false))
        runner.answer(.tracking(false))
        settle()
        runner.answer(.privacy(true))
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(store.state.saved == SavedPosition(pan: 12, tilt: 3, zoom: nil))
    }

    @Test("Démarrage, mode natif retenu, caméra encore en vie privée : l'état réel seulement ; ni inclinaison, ni coupure du suivi")
    func startupStillNative() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        runner.state = .privacy
        let controller = makeController()
        #expect(controller.snapshot.privacy)
        controller.cameraPresenceChanged(true)
        #expect(runner.inFlight == .status)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        scheduler.advance(by: 600)
        #expect(camera.absoluteCommands.isEmpty)
        #expect(runner.received == [.status])
        #expect(controller.snapshot.aiTracking == .unknown)
    }

    @Test("Démarrage, mode natif retenu, caméra redémarrée éveillée : stable d'abord, puis coupure du suivi, −70°, mode natif")
    func startupRebootedAwake() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(runner.inFlight == .tracking(false))
        #expect(camera.absoluteCommands.isEmpty)
        settle()
        #expect(camera.absoluteCommands == [Self.down])
        runner.answer(.tracking(false))
        settle()
        runner.answer(.privacy(true))
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
    }

    @Test("Sans SDK, mode natif retenu : l'inclinaison directement (rien ne peut lire ni réveiller la caméra)")
    func startupNativeWithoutSDK() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil), native: true)
        let controller = makeController(sdk: false)
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(controller.snapshot.privacyReason == .noSDK)
        #expect(!store.state.native)
    }

    // MARK: - I3, I6 : obsbot-ai ancien

    @Test("I3 : premier ordre sur l'ancien obsbot-ai : « ordre inconnu », raison updating, protection à −70°, sans avertissement ; aiUpdated : mode natif")
    func staleUtilityThenUpdated() {
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 1)
        settle()
        runner.answer(.privacy(true), .unknownOrder)
        #expect(controller.snapshot.privacyMode == .tilt)
        #expect(controller.snapshot.privacyReason == .updating)
        #expect(errors.values.isEmpty)
        #expect(!store.state.native)
        // Pas de second essai sur cet utilitaire, et l'inclinaison reste vérifiée.
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
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(errors.values.isEmpty)
    }

    @Test("I3 : vie privée active d'une 1.1.0 (state.json sans native) pendant la recompilation : réapplication, raison updating, aucun repli annoncé")
    func staleUtilityAtStartup() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == [Self.down])
        runner.answer(.tracking(false))
        settle()
        runner.answer(.privacy(true), .unknownOrder)
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
        #expect(camera.absoluteCommands == [Self.down, Self.before])
        // Nouvelle entrée : la protection à −70°, sans nouvel « ordre inconnu » ni attente.
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(camera.absoluteCommands.last == Self.down)
        #expect(controller.snapshot.privacyReason == .updating)
        scheduler.advance(by: 60)
        #expect(runner.privacyOrders == [true])
        #expect(errors.values.isEmpty)
    }

    // MARK: - I4, I5

    @Test("I4 : inclinaison retenue puis passage au mode natif, puis sortie : la position d'avant la vie privée est rétablie")
    func exitAfterPromotionRestoresSaved() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: 40))
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        runner.answer(.tracking(false))
        settle()
        runner.answer(.privacy(true))
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        camera.position = PanTiltPosition(pan: 12, tilt: 90)
        wake(controller)
        settle()
        #expect(!controller.snapshot.privacy)
        #expect(camera.absoluteCommands.last == PanTiltPosition(pan: 12, tilt: 3))
        #expect(camera.zoomCommands.last == 40)
    }

    @Test("I5 : entrée qui a pris sans réponse, lecture ratée, second essai en échec : la lecture constate le mode natif, aucun PanTilt à la caméra endormie")
    func neverFallBackWhileAsleep() {
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 1)
        settle()
        runner.lose(.privacy(true))
        runner.answer(.status, .timeout)
        scheduler.advance(by: PrivacyReconciler.retryDelay)
        runner.answer(.privacy(true), .sdkError)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(errors.values.isEmpty)
    }

    @Test("I5 : sortie après un repli : privacy off part quand même (quel que soit le mode noté)")
    func exitAfterFallbackSendsPrivacyOff() {
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 1)
        settle()
        runner.answer(.privacy(true), .sdkError)
        runner.answer(.status)
        settle()
        runner.answer(.privacy(true), .sdkError)
        runner.answer(.status)
        settle()
        #expect(controller.snapshot.privacyReason == .failed)
        _ = controller.handle(.privacy(on: false), from: 1)
        #expect(runner.inFlight == .privacy(false))
        runner.answer(.privacy(false))
        runner.answer(.status)
        settle()
        #expect(!controller.snapshot.privacy)
        #expect(camera.absoluteCommands.last == Self.before)
    }

    // MARK: - Le dernier choix gagne, débranchement, coupure du suivi

    @Test("M2 : retour à la vie privée pendant la remontée : elle va à son terme, puis le mode natif ; saved reste celle d'avant")
    func reenterDuringRise() {
        let controller = ready()
        enterNative(controller)
        wake(controller)
        camera.position = PanTiltPosition(pan: 12, tilt: 90)
        scheduler.advance(by: 1)
        #expect(controller.handle(.privacy(on: true), from: 2) == nil)
        camera.position = Self.down
        settle()
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true))
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.absoluteCommands == [Self.down])
        #expect(store.state.saved == SavedPosition(pan: 12, tilt: 4, zoom: 33))
    }

    @Test("M3 : débranchement pendant une sortie : la réponse est écartée, la sortie reprend au branchement")
    func unplugDuringExit() {
        let controller = ready()
        enterNative(controller)
        _ = controller.handle(.privacy(on: false), from: 1)
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        #expect(controller.snapshot.privacy)
        #expect(store.state.privacy)
        camera.isPresent = true
        controller.cameraPresenceChanged(true)
        #expect(runner.inFlight == .privacy(false))
        runner.answer(.privacy(false))
        runner.answer(.status)
        camera.position = Self.down
        settle()
        #expect(!controller.snapshot.privacy)
        #expect(camera.absoluteCommands.last == Self.before)
    }

    @Test("Débranchement pendant l'entrée : la réponse est écartée ; au branchement, l'état réel est lu avant tout ordre de position")
    func unplugDuringEntry() {
        let controller = ready()
        _ = controller.handle(.privacy(on: true), from: 1)
        settle()
        #expect(runner.inFlight == .privacy(true))
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        #expect(runner.inFlight == nil)
        scheduler.advance(by: 60)
        #expect(controller.snapshot.privacy)
        // L'ordre a pu basculer la caméra : au branchement, rien avant la lecture de l'état réel.
        camera.isPresent = true
        runner.state = .privacy
        controller.cameraPresenceChanged(true)
        #expect(runner.inFlight == .status)
        #expect(camera.absoluteCommands == [Self.down])
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(errors.values.isEmpty)
    }

    @Test("M12 : coupure du suivi pendant le mode natif : l'état réel est relu ; réveillée, la vie privée est réappliquée")
    func trackingCutDuringNativeRereads() {
        camera.position = Self.before
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        // La coupure échoue : son nouvel essai partira dans 3 s, pendant le mode natif.
        runner.answer(.tracking(false), .sdkError)
        settle()
        runner.answer(.privacy(true))
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        scheduler.advance(by: ControlTaker.retryDelay)
        #expect(runner.inFlight == .tracking(false))
        // Elle a réveillé la caméra (essai de banc 3).
        runner.state = .run
        runner.answer(.tracking(false))
        #expect(runner.inFlight == .status)
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .tilt)
        settle()
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true))
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
        #expect(camera.absoluteCommands == [Self.down])
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
        runner.answer(.privacy(true), .sdkError)
        runner.answer(.status)
        settle()
        runner.answer(.privacy(true))
        runner.answer(.status)
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

    @Test("Avec le SDK, inclinaison refusée : le mode natif protège quand même")
    func tiltRefusedWithSDK() {
        let controller = ready()
        camera.failNextWrite = .ioKit(-536870212)
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true))
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
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
        #expect(camera.absoluteCommands == [Self.down])
        #expect(log.lines.contains { $0.contains("state.json") })
        settle()
        runner.answer(.privacy(true))
        runner.answer(.status)
        #expect(controller.snapshot.privacyMode == .native)
    }
}

/// États publiés (tests).
@MainActor
final class SnapshotBox {
    var values: [StateSnapshot] = []
}
