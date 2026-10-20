import Foundation

/// Les ordres de l'utilitaire, un à la fois (spec § 6.5 bis et § 6.11) : la coupure du suivi IA, la vie privée native et l'exposition partagent
/// le même `obsbot-ai serve`, qui refuse un ordre donné pendant un autre. La file les fait partir l'un après l'autre :
/// aucun n'est refusé pour cause d'ordre en cours, aucun n'est croisé.
///
/// **La vie privée passe toujours devant l'exposition** (spec § 6.11) : les ordres du suivi et de la vie privée partent
/// dans l'ordre d'arrivée, mais devant tout ordre d'exposition en attente. Un ordre déjà parti n'est jamais interrompu :
/// l'attente au pire est donc d'un seul ordre d'exposition. Tant qu'il est en cours, `isReady` est faux : l'entrée en vie
/// privée prend alors le repli (−70° tout de suite) au lieu d'attendre derrière lui.
///
/// `reset` passe à l'utilitaire : l'ordre en cours échoue, et l'ordre suivant de la file part sur un utilitaire neuf.
@MainActor
public final class AIOrderQueue: AIRunner {
    private typealias Start = (@escaping @MainActor @Sendable () -> Void) -> Void

    /// Un ordre en attente. `exposure` : un ordre d'exposition, qui cède la place aux autres et que `dropQueuedExposure`
    /// peut jeter.
    private struct Job {
        let exposure: Bool
        let start: Start
    }

    private let runner: any AIRunner
    private var jobs: [Job] = []
    private var busy = false
    /// L'ordre parti est un ordre d'exposition.
    private var exposureInFlight = false

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

    public func readExposure(completion: @escaping @MainActor @Sendable (ExposureReading) -> Void) {
        enqueue(exposure: true) { [runner] done in
            runner.readExposure { reading in
                completion(reading)
                done()
            }
        }
    }

    public func runExposure(_ setting: ExposureSetting, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        enqueue(exposure: true) { [runner] done in
            runner.runExposure(setting) { result in
                completion(result)
                done()
            }
        }
    }

    public var supportsNativePrivacy: Bool { runner.supportsNativePrivacy }

    /// Prêt pour un ordre immédiat : faux tant qu'un ordre d'exposition est parti, la vie privée attendrait derrière lui.
    public var isReady: Bool { runner.isReady && !exposureInFlight }

    public var busyWithExposure: Bool { exposureInFlight }

    public var keepsWarm: Bool { runner.keepsWarm }

    public func prewarm() {
        runner.prewarm()
    }

    public func reset() {
        runner.reset()
    }

    /// Jette les ordres d'exposition encore en attente (la session de l'exposition est abandonnée : débranchement,
    /// recompilation, ou vie privée voulue). Ils ne partiront jamais ; leur réponse ne sera jamais rendue, personne ne
    /// l'attend. Un ordre déjà parti va à son terme.
    public func dropQueuedExposure() {
        jobs.removeAll { $0.exposure }
    }

    /// Le rappel passe avant l'ordre suivant : un ordre donné par le rappel prend sa place au bout de la file, derrière
    /// ceux qui attendaient déjà de même rang, et les rappels arrivent dans l'ordre des ordres.
    private func enqueue(exposure: Bool = false, _ start: @escaping Start) {
        jobs.append(Job(exposure: exposure, start: start))
        pump()
    }

    private func pump() {
        guard !busy, !jobs.isEmpty else { return }
        busy = true
        // Le premier ordre qui n'est pas d'exposition ; à défaut, le premier ordre.
        let index = jobs.firstIndex { !$0.exposure } ?? 0
        let job = jobs.remove(at: index)
        exposureInFlight = job.exposure
        let release = Release()
        job.start { [weak self] in
            // Une seule libération par ordre, même si l'utilitaire rappelait deux fois.
            guard !release.done, let self else { return }
            release.done = true
            busy = false
            exposureInFlight = false
            pump()
        }
    }
}

/// La libération d'un ordre de la file, faite une seule fois.
@MainActor
private final class Release {
    var done = false
}
