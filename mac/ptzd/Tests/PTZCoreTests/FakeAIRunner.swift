import Testing
@testable import PTZCore

/// obsbot-ai simulé, fidèle au vrai `ResidentAIRunner` (spec § 6.5 bis) :
/// - **un seul ordre à la fois** : un ordre donné pendant un autre est refusé tout de suite (`launchFailed`), comme le
///   vrai, et noté dans `refused` ;
/// - la réponse arrive quand le test le décide : réussie, en échec, en retard, ou perdue (l'ordre agit sur la caméra,
///   mais le vrai runner rend `timeout` faute de réponse) ;
/// - un **état réel simulé** de la caméra (`state`), que les ordres de vie privée changent quand ils agissent, et que
///   `privacy status` lit.
@MainActor
final class FakeAIRunner: AIRunner {
    enum Order: Equatable {
        case tracking(Bool)
        case privacy(Bool)
        case status
    }

    private enum Completion {
        case result(@MainActor @Sendable (AIResult) -> Void)
        case reading(@MainActor @Sendable (PrivacyReading) -> Void)
    }

    /// État réel simulé de la caméra.
    var state: CameraRunState = .run
    /// L'utilitaire existe (SDK installé) : sans lui, la vie privée native n'est pas proposée.
    var nativePrivacyAvailable = false
    var supportsNativePrivacy: Bool { nativePrivacyAvailable }

    /// Ordres acceptés, dans l'ordre.
    private(set) var received: [Order] = []
    /// Ordres refusés parce qu'un autre était en cours : le vrai utilitaire les refuse aussi. Jamais attendu.
    private(set) var refused: [Order] = []
    /// Nombre de préparations demandées.
    private(set) var prewarms = 0
    /// Réinitialisations demandées (branchement ou débranchement de la caméra, recompilation).
    private(set) var resets = 0
    private var current: (order: Order, completion: Completion)?

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
    /// Lectures de l'état réel reçues.
    var statusReads: Int {
        received.filter { $0 == .status }.count
    }

    func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        accept(.tracking(on), .result(completion))
    }

    func runPrivacy(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        accept(.privacy(on), .result(completion))
    }

    func readPrivacy(completion: @escaping @MainActor @Sendable (PrivacyReading) -> Void) {
        accept(.status, .reading(completion))
    }

    func prewarm() {
        prewarms += 1
    }

    /// Comme le vrai : l'utilitaire est arrêté, l'ordre en cours échoue.
    func reset() {
        resets += 1
        respond(.launchFailed("utilitaire réinitialisé"), effect: false)
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
            case let .reading(done): done(.failed(refusal))
            }
            return
        }
        received.append(order)
        current = (order, completion)
    }

    private func respond(_ result: AIResult, effect: Bool) {
        guard let pending = current else { return }
        current = nil
        if effect, case let .privacy(on) = pending.order {
            state = on ? .privacy : .run
        }
        switch pending.completion {
        case let .result(done):
            done(result)
        case let .reading(done):
            done(result == .success ? .state(state) : .failed(result))
        }
    }
}
