@testable import PTZCore

/// obsbot-ai simulé : le test décide quand et comment il se termine.
@MainActor
final class FakeAIRunner: AIRunner {
    private(set) var runCount = 0
    /// Ordres reçus, dans l'ordre (true : on).
    private(set) var orders: [Bool] = []
    /// Nombre de préparations demandées.
    private(set) var prewarms = 0
    /// Réinitialisations demandées (branchement ou débranchement de la caméra).
    private(set) var resets = 0
    private var completions: [@MainActor @Sendable (AIResult) -> Void] = []
    /// L'utilitaire existe (SDK installé) : sans lui, la vie privée native n'est pas proposée.
    var nativePrivacyAvailable = false
    var supportsNativePrivacy: Bool { nativePrivacyAvailable }
    /// Ordres de vie privée native reçus, dans l'ordre (true : privacy on).
    private(set) var privacyOrders: [Bool] = []
    private var privacyCompletions: [@MainActor @Sendable (AIResult) -> Void] = []

    func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        runCount += 1
        orders.append(on)
        completions.append(completion)
    }

    func runPrivacy(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        privacyOrders.append(on)
        privacyCompletions.append(completion)
    }

    /// Termine l'ordre de vie privée native en cours.
    func finishPrivacy(_ result: AIResult) {
        let pending = privacyCompletions
        privacyCompletions.removeAll()
        pending.forEach { $0(result) }
    }

    func prewarm() {
        prewarms += 1
    }

    func reset() {
        resets += 1
    }

    func finish(_ result: AIResult) {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0(result) }
    }
}
