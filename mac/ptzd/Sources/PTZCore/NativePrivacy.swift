import Foundation

/// Un ordre de vie privée native (`privacy on` ou `privacy off`, spec § 6.5 bis) donné à l'utilitaire du suivi IA, avec
/// un second essai automatique en cas d'échec. Il ne décide de rien : l'appelant choisit quoi faire d'un échec
/// (repli sur l'inclinaison, erreur montrée).
@MainActor
public final class NativePrivacy {
    /// Délai avant le second essai : il part au plus 3 s après l'échec du premier, donc bien dans les 10 s de la spec.
    public static let retryDelay: TimeInterval = 3
    /// Essais au plus par ordre.
    public static let maxAttempts = 2

    /// Un ordre est en cours (attente comprise) : un autre ne peut pas partir.
    public var isBusy: Bool { job != nil }
    /// Le sens de l'ordre en cours (true : entrée), nil s'il n'y en a pas.
    public var pendingOn: Bool? { job?.on }
    /// L'utilitaire du SDK est là ; sinon la vie privée native n'existe pas (mode `tilt` d'emblée).
    public var isAvailable: Bool { runner.supportsNativePrivacy }

    private struct Job {
        var on: Bool
        var attempts = 0
        /// L'ordre attend que l'utilitaire soit libre (coupure du suivi IA en cours).
        var waiting = false
        var completion: @MainActor @Sendable (AIResult) -> Void
    }

    private let runner: any AIRunner
    private let scheduler: any Scheduler
    private let canRun: @MainActor () -> Bool
    private let log: LogSink
    private var job: Job?
    private var retry: (any Cancellable)?
    /// Change à chaque ordre et à chaque annulation : une réponse d'un ordre annulé est ignorée.
    private var generation = 0

    /// `canRun` dit si l'utilitaire est libre : il ne traite qu'un ordre à la fois, et la coupure du suivi IA passe avant.
    public init(runner: any AIRunner, scheduler: any Scheduler, canRun: @escaping @MainActor () -> Bool, log: @escaping LogSink) {
        self.runner = runner
        self.scheduler = scheduler
        self.canRun = canRun
        self.log = log
    }

    /// Donne l'ordre ; `completion` reçoit `.success`, ou l'échec du dernier essai. Sans effet si un ordre est en cours.
    public func apply(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        guard job == nil else { return }
        generation += 1
        job = Job(on: on, completion: completion)
        attempt()
    }

    /// L'utilitaire est peut-être libre : reprend un ordre qui attendait.
    public func resume() {
        guard job?.waiting == true else { return }
        attempt()
    }

    /// Abandonne l'ordre en cours, sans en avertir personne (caméra débranchée, réapplication).
    public func cancel() {
        generation += 1
        retry?.cancel()
        retry = nil
        job = nil
    }

    private func attempt() {
        guard var current = job else { return }
        guard canRun() else {
            current.waiting = true
            job = current
            return
        }
        current.waiting = false
        current.attempts += 1
        job = current
        let ticket = generation
        runner.runPrivacy(on: current.on) { [weak self] result in
            guard let self, ticket == generation else { return }
            finished(result)
        }
    }

    private func finished(_ result: AIResult) {
        guard let current = job else { return }
        if result == .success {
            job = nil
            current.completion(.success)
            return
        }
        guard current.attempts < Self.maxAttempts else {
            log("obsbot-ai privacy \(current.on ? "on" : "off") a échoué deux fois : \(result).")
            job = nil
            current.completion(result)
            return
        }
        log("obsbot-ai privacy \(current.on ? "on" : "off") a échoué (\(result)) : nouvel essai dans \(Int(Self.retryDelay)) s.")
        let ticket = generation
        retry = scheduler.schedule(after: Self.retryDelay) { [weak self] in
            guard let self, ticket == generation else { return }
            retry = nil
            attempt()
        }
    }
}
