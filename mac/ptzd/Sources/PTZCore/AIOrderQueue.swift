import Foundation

/// Les ordres de l'utilitaire, un à la fois (spec § 6.5 bis) : la coupure du suivi IA et la vie privée native partagent
/// le même `obsbot-ai serve`, qui refuse un ordre donné pendant un autre. La file les fait partir l'un après l'autre,
/// dans l'ordre d'arrivée : aucun n'est refusé pour cause d'ordre en cours, aucun n'est croisé.
///
/// `reset` passe à l'utilitaire : l'ordre en cours échoue, et l'ordre suivant de la file part sur un utilitaire neuf.
@MainActor
public final class AIOrderQueue: AIRunner {
    private typealias Job = (@escaping @MainActor @Sendable () -> Void) -> Void

    private let runner: any AIRunner
    private var jobs: [Job] = []
    private var busy = false

    public init(runner: any AIRunner) {
        self.runner = runner
    }

    /// Ordres en attente, celui en cours non compris (tests).
    var waiting: Int { jobs.count }

    public func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        enqueue { [runner] done in
            runner.run(on: on) { result in
                completion(result)
                done()
            }
        }
    }

    public func runPrivacy(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        enqueue { [runner] done in
            runner.runPrivacy(on: on) { result in
                completion(result)
                done()
            }
        }
    }

    public func readPrivacy(completion: @escaping @MainActor @Sendable (PrivacyReading) -> Void) {
        enqueue { [runner] done in
            runner.readPrivacy { reading in
                completion(reading)
                done()
            }
        }
    }

    public var supportsNativePrivacy: Bool { runner.supportsNativePrivacy }

    public var isReady: Bool { runner.isReady }

    public var keepsWarm: Bool { runner.keepsWarm }

    public func prewarm() {
        runner.prewarm()
    }

    public func reset() {
        runner.reset()
    }

    /// Le rappel passe avant l'ordre suivant : un ordre donné par le rappel prend sa place au bout de la file, derrière
    /// ceux qui attendaient déjà, et les rappels arrivent dans l'ordre des ordres.
    private func enqueue(_ job: @escaping Job) {
        jobs.append(job)
        pump()
    }

    private func pump() {
        guard !busy, !jobs.isEmpty else { return }
        busy = true
        let job = jobs.removeFirst()
        let release = Release()
        job { [weak self] in
            // Une seule libération par ordre, même si l'utilitaire rappelait deux fois.
            guard !release.done, let self else { return }
            release.done = true
            busy = false
            pump()
        }
    }
}

/// La libération d'un ordre de la file, faite une seule fois.
@MainActor
private final class Release {
    var done = false
}
