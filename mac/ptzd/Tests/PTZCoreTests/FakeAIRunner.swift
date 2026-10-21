import Foundation
import Testing
@testable import PTZCore

/// obsbot-ai simulé, fidèle au vrai `ResidentAIRunner` et à la vraie caméra (spec § 6.5 bis, mesures du 19/10) :
/// - **l'exposition** (spec § 6.11) : un réglage simulé (`exposure`), que `exposure set` change quand il agit, et que
///   `exposure status` lit (ou `exposureUnreadable`) ; une coupure d'alimentation (`powerCycle`) fait oublier le mode
///   automatique à la caméra, comme le ferait un redémarrage ;
/// - **un seul ordre à la fois** : un ordre donné pendant un autre est refusé tout de suite (`launchFailed`), comme le
///   vrai, et noté dans `refused` ;
/// - la réponse arrive quand le test le décide : réussie, en échec, en retard, ou perdue (l'ordre agit sur la caméra,
///   mais le vrai runner rend `timeout` faute de réponse) ; les lectures peuvent aussi répondre seules (`autoReads`) ;
/// - les **sessions du SDK** : le vrai utilitaire repart d'une session neuve (4 s) après un `err 2` d'ordre, un
///   `err 3`, un délai dépassé ou une réinitialisation ; une lecture ratée la garde. Le SDK n'est **prêt** (`isReady`)
///   qu'une fois que la session a répondu à un ordre ;
/// - un **état réel simulé** de la caméra (`state`), que les ordres de vie privée changent quand ils agissent, et que
///   `privacy status` lit avec le second témoin, l'inclinaison de la nacelle ;
/// - **les mouvements propres de la caméra**, avec `attach(camera:scheduler:)` : la bascule (état 3 en 0,5 s), la
///   descente vers 85° (1,1 s) depuis la position où l'ordre la trouve, pan et zoom inchangés, la remontée à cette
///   même position d'entrée, l'état 1 vers 1,7 s après le réveil, et le retour éveillé et droit après une coupure
///   d'alimentation (`powerCycle`). Sans caméra liée, la bascule est immédiate ;
/// - **la remontée suit la course** : 0,5 s au moins (15° mesurés, 85° vers 70°), 1,1 s pour 87° (85° vers −2°, mesuré
///   le 19/10 après le banc), à `riseSpeed`, la position changeant par paliers de `riseStep` ;
/// - **l'invariant « un seul pilote »** : avec une caméra liée, `FakeCamera` fait échouer tout test où un ordre UVC part
///   pendant que la caméra gère seule sa position (mode natif, bascule, remontée), hors rebranchement.
@MainActor
final class FakeAIRunner: AIRunner {
    enum Order: Equatable {
        case tracking(Bool)
        case privacy(Bool)
        case status
        case exposureStatus
        case exposure(ExposureSetting)
    }

    private enum Completion {
        case result(@MainActor @Sendable (AIResult) -> Void)
        case reading(@MainActor @Sendable (PrivacyReading) -> Void)
        case exposureReading(@MainActor @Sendable (ExposureReading) -> Void)
    }

    /// Délais mesurés sur la vraie caméra (19/10).
    static let switchTime: TimeInterval = 0.5
    static let descentTime: TimeInterval = 1.1
    static let riseTime: TimeInterval = 0.5
    /// Paliers de la remontée : assez fins pour que deux relectures serrées (0,15 s) ne tombent pas sur le même.
    static let riseStep: TimeInterval = 0.05
    static let wakeStateTime: TimeInterval = 1.7
    /// Une session neuve du SDK met environ 4 s à trouver la caméra (mesuré).
    static let loadTime: TimeInterval = 4
    /// La pose du mode natif, en degrés UVC (85° vers le bas).
    static let nativeTilt: Double = -85

    /// État réel simulé de la caméra.
    var state: CameraRunState = .run
    /// L'utilitaire reste chargé tant que ptzd tourne (ptzd lancé avec le SDK, spec § 6.9) : `prewarm` ouvre alors une
    /// session, prête au bout de `loadTime` (4 s mesurés), sans aucun ordre. Faux : `prewarm` ne fait que compter, comme
    /// avant, et seul un ordre ouvre une session.
    var keepsWarm = false
    /// L'utilitaire existe (SDK installé) : sans lui, la vie privée native n'est pas proposée.
    var nativePrivacyAvailable = false
    var supportsNativePrivacy: Bool { nativePrivacyAvailable }
    /// `privacy status` ne sait pas lire l'état (vieux micrologiciel) : `err 2`, avec l'inclinaison si elle se lit.
    var stateUnreadable = false
    /// L'inclinaison ne se lit pas par le SDK.
    var pitchUnreadable = false
    /// Les lectures de l'état répondent seules, tout de suite, avec l'état simulé.
    var autoReads = false
    /// Réglage d'exposition simulé de la caméra : manuel, obturation 31 au départ (essai du 20/10).
    var exposure = ExposureSetting(shutter: 31, auto: false)
    /// `exposure status` ne sait pas lire le réglage : `err 2`.
    var exposureUnreadable = false
    /// Vitesse de la remontée (degrés par seconde) : 87° en 1,1 s, mesuré le 19/10. Un test peut la ralentir (m4).
    var riseSpeed: Double = 80

    /// Ordres acceptés, dans l'ordre.
    private(set) var received: [Order] = []
    /// Ordres refusés parce qu'un autre était en cours : le vrai utilitaire les refuse aussi. Jamais attendu.
    private(set) var refused: [Order] = []
    /// Nombre de préparations demandées.
    private(set) var prewarms = 0
    /// Réinitialisations demandées (branchement ou débranchement de la caméra, recompilation).
    private(set) var resets = 0
    /// Sessions du SDK ouvertes (chacune coûte environ 4 s à la vraie caméra).
    private(set) var sessions = 0
    private var sessionOpen = false
    /// La session ouverte a déjà répondu : le SDK a trouvé la caméra.
    private var sessionAnswered = false
    /// Change à chaque session ouverte ou fermée : le « ready » d'une session qui n'existe plus est écarté.
    private var sessionGeneration = 0

    /// Le SDK est prêt, comme au vrai utilitaire après « ready » : une session ouverte, qui a déjà répondu.
    var isReady: Bool { sessionOpen && sessionAnswered }
    private var current: (order: Order, completion: Completion)?

    private weak var camera: FakeCamera?
    private var scheduler: FakeScheduler?
    /// L'état vers lequel la caméra va pendant une bascule (nil : aucune en cours) ; les mouvements d'un ordre remplacé
    /// sont abandonnés.
    private var heading: CameraRunState?
    private var motionGeneration = 0
    /// La position d'avant le mode natif, que la caméra reprend d'elle-même au réveil.
    private var beforeNative: PanTiltPosition?
    /// La remontée propre de la caméra dure jusqu'à cet instant.
    private var risingUntil: TimeInterval = 0

    /// L'ordre en cours, sans réponse encore.
    var inFlight: Order? { current?.order }
    /// Ordres de suivi IA reçus (true : on).
    var orders: [Bool] {
        received.compactMap { if case let .tracking(on) = $0 { on } else { nil } }
    }
    var runCount: Int { orders.count }
    /// Ordres de vie privée native reçus (true : privacy on).
    var privacyOrders: [Bool] {
        received.compactMap { if case let .privacy(on) = $0 { on } else { nil } }
    }
    /// Ordres d'exposition reçus (`exposure set`), dans l'ordre.
    var exposureOrders: [ExposureSetting] {
        received.compactMap { if case let .exposure(setting) = $0 { setting } else { nil } }
    }
    /// Lectures du réglage d'exposition reçues.
    var exposureReads: Int {
        received.filter { $0 == .exposureStatus }.count
    }
    /// Lectures de l'état réel reçues.
    var statusReads: Int {
        received.filter { $0 == .status }.count
    }
    /// Le second témoin : l'inclinaison lue par le SDK, positive vers le bas ; nil sans caméra liée.
    var pitch: Double? {
        guard !pitchUnreadable, let camera else { return nil }
        return -camera.position.tilt
    }

    /// Lie la caméra simulée et l'horloge : la caméra bouge alors d'elle-même, aux délais mesurés.
    func attach(camera: FakeCamera, scheduler: FakeScheduler) {
        self.camera = camera
        self.scheduler = scheduler
        camera.drivesItsOwnPosition = { [weak self] in self?.drivesItsOwnPosition ?? false }
    }

    /// La caméra gère seule sa position : mode natif, bascule en cours, ou remontée propre pas finie.
    var drivesItsOwnPosition: Bool {
        state == .privacy || heading != nil || (scheduler.map { $0.now < risingUntil } ?? false)
    }

    /// Coupure d'alimentation : la caméra revient éveillée et droite (mesuré), et la session du SDK ne vaut plus.
    func powerCycle() {
        motionGeneration += 1
        state = .run
        heading = nil
        risingUntil = 0
        beforeNative = nil
        sessionOpen = false
        camera?.position = PanTiltPosition(pan: 0, tilt: 0)
        // Le redémarrage fait oublier à la caméra le mode automatique (le gain et l'obturation restent).
        exposure.auto = false
    }

    /// L'utilitaire s'est arrêté après son délai d'inactivité : la session est fermée, le SDK n'est plus prêt ; le
    /// prochain ordre en ouvre une neuve.
    func idleStop() {
        sessionOpen = false
    }

    /// Réveil par un autre moyen (bouton, télécommande, app OBSBOT) : la caméra reprend sa position d'avant.
    func wakeExternally() {
        move(toPrivacy: false)
    }

    func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        accept(.tracking(on), .result(completion))
    }

    func runPrivacy(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        accept(.privacy(on), .result(completion))
    }

    func readPrivacy(completion: @escaping @MainActor @Sendable (PrivacyReading) -> Void) {
        accept(.status, .reading(completion))
        if autoReads, current?.order == .status {
            respond(.success, effect: false)
        }
    }

    func readExposure(completion: @escaping @MainActor @Sendable (ExposureReading) -> Void) {
        accept(.exposureStatus, .exposureReading(completion))
    }

    func runExposure(_ setting: ExposureSetting, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        accept(.exposure(setting), .result(completion))
    }

    func prewarm() {
        prewarms += 1
        guard keepsWarm, !sessionOpen else { return }
        openSession()
        // Le SDK cherche la caméra : « ready » au bout de `loadTime` (tout de suite sans horloge liée).
        guard let scheduler else {
            sessionAnswered = true
            return
        }
        let generation = sessionGeneration
        scheduler.schedule(after: Self.loadTime) { [weak self] in
            guard let self, generation == sessionGeneration, sessionOpen else { return }
            sessionAnswered = true
        }
    }

    private func openSession() {
        sessionOpen = true
        sessionAnswered = false
        sessionGeneration += 1
        sessions += 1
    }

    /// Comme le vrai : l'utilitaire est arrêté, l'ordre en cours échoue.
    func reset() {
        resets += 1
        respond(.launchFailed("utilitaire réinitialisé"), effect: false)
        sessionOpen = false
    }

    /// Répond à l'ordre en cours, quel qu'il soit ; sans effet s'il n'y en a pas. Un ordre de vie privée réussi agit sur
    /// la caméra ; une lecture réussie rend l'état simulé.
    func finish(_ result: AIResult) {
        respond(result, effect: result == .success)
    }

    /// Répond à l'ordre en cours, qui doit être `expected`. `effect` : l'ordre a agi sur la caméra (par défaut : s'il a
    /// réussi).
    func answer(
        _ expected: Order,
        _ result: AIResult = .success,
        effect: Bool? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard current?.order == expected else {
            Issue.record("Ordre en cours : \(String(describing: current?.order)), attendu : \(expected)", sourceLocation: sourceLocation)
            return
        }
        respond(result, effect: effect ?? (result == .success))
    }

    /// L'ordre agit sur la caméra, mais sa réponse se perd : le vrai runner rend `timeout` à l'échéance.
    func lose(_ expected: Order, sourceLocation: SourceLocation = #_sourceLocation) {
        answer(expected, .timeout, effect: true, sourceLocation: sourceLocation)
    }

    private func accept(_ order: Order, _ completion: Completion) {
        guard current == nil else {
            refused.append(order)
            let refusal = AIResult.launchFailed("ordre précédent encore en cours")
            switch completion {
            case let .result(done): done(refusal)
            case let .reading(done): done(.failed(refusal, pitch: nil))
            case let .exposureReading(done): done(.failed(refusal))
            }
            return
        }
        if !sessionOpen {
            openSession()
        }
        received.append(order)
        current = (order, completion)
    }

    private func respond(_ result: AIResult, effect: Bool) {
        guard let pending = current else { return }
        current = nil
        // Comme le vrai : session neuve après un délai dépassé, un ordre inconnu, ou une erreur du SDK sur un ordre ; une
        // lecture ratée garde la session.
        switch result {
        case .timeout, .unknownOrder:
            sessionOpen = false
        case .sdkError where pending.order != .status && pending.order != .exposureStatus:
            sessionOpen = false
        case .launchFailed:
            break
        default:
            sessionAnswered = true
        }
        if effect, case let .privacy(on) = pending.order {
            move(toPrivacy: on)
        }
        if effect, case let .exposure(setting) = pending.order {
            exposure = setting
        }
        switch pending.completion {
        case let .result(done):
            done(result)
        case let .reading(done):
            if result == .success, !stateUnreadable {
                done(.state(state, pitch: pitch))
            } else if result == .success || result == .sdkError {
                done(.failed(.sdkError, pitch: pitch))
            } else {
                done(.failed(result, pitch: nil))
            }
        case let .exposureReading(done):
            if result == .success, !exposureUnreadable {
                done(.setting(exposure))
            } else {
                done(.failed(result == .success ? .sdkError : result))
            }
        }
    }

    /// La bascule et les mouvements propres de la caméra ; deux entrées ou deux réveils de suite ne font rien de plus.
    private func move(toPrivacy on: Bool) {
        let target: CameraRunState = on ? .privacy : .run
        guard (heading ?? state) != target else { return }
        guard let camera, let scheduler else {
            state = target
            return
        }
        motionGeneration += 1
        if !on, state == .run {
            // L'entrée n'avait pas encore agi (l'état est resté `run`, la nacelle n'a pas bougé) : ce réveil ne change rien.
            heading = nil
            return
        }
        heading = target
        let generation = motionGeneration
        if on {
            let before = camera.position
            beforeNative = before
            scheduler.schedule(after: Self.switchTime) { [weak self] in
                guard let self, motionGeneration == generation else { return }
                state = .privacy
                heading = nil
            }
            scheduler.schedule(after: Self.descentTime) { [weak self, weak camera] in
                guard let self, motionGeneration == generation else { return }
                camera?.position = PanTiltPosition(pan: before.pan, tilt: Self.nativeTilt)
            }
        } else {
            // Sans position notée (état posé par le test), celle où ptzd la met toujours avant le mode natif : −70°.
            let back = beforeNative ?? PanTiltPosition(pan: camera.position.pan, tilt: PrivacyReconciler.privacyTilt)
            // La remontée dure plus longtemps pour une course plus longue (m4) : la position change par paliers.
            let duration = max(Self.riseTime, abs(back.tilt - camera.position.tilt) / riseSpeed)
            let start = camera.position
            risingUntil = scheduler.now + duration
            let steps = duration <= Self.riseTime + 1e-9 ? 1 : max(1, Int((duration / Self.riseStep).rounded()))
            for step in 1...steps {
                let fraction = Double(step) / Double(steps)
                scheduler.schedule(after: duration * fraction) { [weak self, weak camera] in
                    guard let self, motionGeneration == generation else { return }
                    camera?.position = step == steps
                        ? back
                        : PanTiltPosition(
                            pan: start.pan + (back.pan - start.pan) * fraction,
                            tilt: start.tilt + (back.tilt - start.tilt) * fraction
                        )
                }
            }
            scheduler.schedule(after: Self.wakeStateTime) { [weak self] in
                guard let self, motionGeneration == generation else { return }
                state = .run
                heading = nil
            }
        }
    }
}
