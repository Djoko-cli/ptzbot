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
/// **Les ordres de fond du suivi IA** (relecture du mode réel, relance du suivi voulu : `TrackingReconciler`) passent
/// derrière la vie privée et le suivi, et devant l'exposition. Leur condition est relue au moment de partir : fausse (vie
/// privée voulue ou en cours, ordre de suivi entre-temps, session abandonnée), l'ordre n'est jamais envoyé, et son
/// rappel rend `launchFailed`. Parti, il rend `isReady` faux, comme un ordre d'exposition : la vie privée ne l'attend
/// jamais.
///
/// `reset` passe à l'utilitaire : l'ordre en cours échoue, et l'ordre suivant de la file part sur un utilitaire neuf.
@MainActor
public final class AIOrderQueue: AIRunner {
    private typealias Start = (@escaping @MainActor @Sendable () -> Void) -> Void

    /// Le rang d'un ordre : la vie privée et le suivi d'abord (dans l'ordre d'arrivée), puis les ordres de fond du suivi,
    /// puis l'exposition.
    private enum Rank: Int {
        case main = 0
        case tracking = 1
        case exposure = 2
    }

    /// Un ordre en attente. Un ordre d'exposition cède la place aux autres, et `dropQueuedExposure` peut le jeter.
    private struct Job {
        let rank: Rank
        let start: Start
    }

    /// Rappel d'un ordre de fond écarté à son tour (sa condition est devenue fausse).
    static let discarded = AIResult.launchFailed("ordre de fond du suivi IA écarté")

    private let runner: any AIRunner
    private var jobs: [Job] = []
    private var busy = false
    /// Le rang de l'ordre parti (nil : aucun).
    private var inFlight: Rank?

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

    /// La lecture du mode IA, sans condition (rang des ordres de fond).
    public func readTracking(completion: @escaping @MainActor @Sendable (TrackingReading) -> Void) {
        readTracking(when: { true }, completion: completion)
    }

    /// Lecture de fond du mode IA : `allowed` est relue quand vient son tour ; fausse, rien ne part.
    public func readTracking(
        when allowed: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor @Sendable (TrackingReading) -> Void
    ) {
        enqueue(rank: .tracking) { [runner] done in
            guard allowed() else {
                completion(.failed(Self.discarded))
                done()
                return
            }
            runner.readTracking { reading in
                completion(reading)
                done()
            }
        }
    }

    /// Relance de fond du suivi IA voulu (`on`) : `allowed` est relue quand vient son tour ; fausse, rien ne part.
    public func resumeTracking(
        when allowed: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor @Sendable (AIResult) -> Void
    ) {
        enqueue(rank: .tracking) { [runner] done in
            guard allowed() else {
                completion(Self.discarded)
                done()
                return
            }
            runner.run(on: true) { result in
                completion(result)
                done()
            }
        }
    }

    public func readExposure(completion: @escaping @MainActor @Sendable (ExposureReading) -> Void) {
        enqueue(rank: .exposure) { [runner] done in
            runner.readExposure { reading in
                completion(reading)
                done()
            }
        }
    }

    public func runExposure(_ setting: ExposureSetting, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        enqueue(rank: .exposure) { [runner] done in
            runner.runExposure(setting) { result in
                completion(result)
                done()
            }
        }
    }

    public var supportsNativePrivacy: Bool { runner.supportsNativePrivacy }

    /// Prêt pour un ordre immédiat : faux tant qu'un ordre d'exposition ou de fond du suivi est parti, la vie privée
    /// attendrait derrière lui.
    public var isReady: Bool { runner.isReady && (inFlight ?? .main) == .main }

    public var busyWithExposure: Bool { inFlight == .exposure }

    public var busyWithTracking: Bool { inFlight == .tracking }

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
        jobs.removeAll { $0.rank == .exposure }
    }

    /// Le rappel passe avant l'ordre suivant : un ordre donné par le rappel prend sa place au bout de la file, derrière
    /// ceux qui attendaient déjà de même rang, et les rappels arrivent dans l'ordre des ordres.
    private func enqueue(rank: Rank = .main, _ start: @escaping Start) {
        jobs.append(Job(rank: rank, start: start))
        pump()
    }

    private func pump() {
        guard !busy, !jobs.isEmpty else { return }
        busy = true
        // Le premier ordre du meilleur rang (le plus ancien à rang égal).
        guard let best = jobs.map(\.rank.rawValue).min(), let index = jobs.firstIndex(where: { $0.rank.rawValue == best }) else { return }
        let job = jobs.remove(at: index)
        inFlight = job.rank
        let release = Release()
        job.start { [weak self] in
            // Une seule libération par ordre, même si l'utilitaire rappelait deux fois.
            guard !release.done, let self else { return }
            release.done = true
            busy = false
            inFlight = nil
            pump()
        }
    }
}

/// La libération d'un ordre de la file, faite une seule fois.
@MainActor
private final class Release {
    var done = false
}
