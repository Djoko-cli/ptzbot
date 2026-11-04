import CoreGraphics
import Foundation

/// go2rtc et la veille du Mac (spec B3 § 15) : go2rtc s'arrête avant la veille et ne repart qu'au vrai réveil.
///
/// Ses deux ffmpeg de capture n'acquittent jamais l'annonce de veille : macOS attend 30 s avant de passer outre, à
/// chaque veille. Puis la caméra quitte le bus USB, et go2rtc relance des captures qui restent bloquées sur l'appareil
/// absent pendant les réveils sombres. Cette logique relie les événements d'alimentation (`SystemSleepWatcher`) au
/// superviseur : le temps vient du `Scheduler`, les écrans d'un prédicat, pour que les tests maîtrisent les deux.
@MainActor
public final class Go2RTCSleepPause {
    /// La veille est acquittée au plus tard après ce délai, même si le gardien n'est pas encore sorti (macOS attend 30 s
    /// chaque client : PTZBot ne doit pas devenir celui qui retarde la veille).
    public static let acknowledgeLimit: TimeInterval = 20
    /// Après un réveil, go2rtc ne repart que si les écrans sont allumés depuis ce délai (un réveil complet d'une seconde,
    /// capot fermé, suivi d'un retour en réveil sombre, ne relance rien).
    public static let resumeDelay: TimeInterval = 5
    /// Tant que la pause dure et que les écrans restent éteints (réveil sombre), nouvelle vérification à ce rythme.
    public static let recheckInterval: TimeInterval = 30

    private let supervisor: Go2RTCSupervisor
    private let scheduler: any Scheduler
    private let screensAwake: @MainActor () -> Bool
    private let log: @MainActor (String) -> Void
    /// La vérification de reprise en attente : une seule à la fois.
    private var pendingCheck: (any Cancellable)?

    /// `log` reçoit des lignes sans horodatage : le câblage (`system`) les date et les ajoute au journal de go2rtc.
    public init(
        supervisor: Go2RTCSupervisor,
        scheduler: any Scheduler,
        screensAwake: @escaping @MainActor () -> Bool,
        log: @escaping @MainActor (String) -> Void
    ) {
        self.supervisor = supervisor
        self.scheduler = scheduler
        self.screensAwake = screensAwake
        self.log = log
    }

    /// Annonce de veille : pause du superviseur ; `acknowledge` est appelé **exactement une fois**, à la fin de l'arrêt
    /// ou à `acknowledgeLimit`, le premier des deux. Annule toute vérification de reprise en attente.
    public func systemWillSleep(acknowledge: @escaping @MainActor () -> Void) {
        cancelCheck()
        let announcement = SleepAnnouncement(startedAt: scheduler.now, acknowledge: acknowledge)
        let stops = supervisor.needsStopBeforeSleep
        log(stops ? "veille annoncée : go2rtc s'arrête avant la veille" : "veille annoncée : go2rtc ne tournait pas")
        // Le journal d'abord, l'acquittement ensuite : le Mac peut s'endormir dès qu'il est donné.
        announcement.limit = scheduler.schedule(after: Self.acknowledgeLimit) { [weak self] in
            guard announcement.isPending else { return }
            self?.log("go2rtc toujours en cours d'arrêt après \(Int(Self.acknowledgeLimit)) s : la veille part quand même")
            announcement.finish()
        }
        supervisor.pauseForSleep { [weak self] in
            if stops, announcement.isPending, let self {
                log("go2rtc arrêté en \(Self.seconds(scheduler.now - announcement.startedAt)) s : la veille peut partir")
            }
            announcement.finish()
        }
    }

    /// Sortie de veille, réveil sombre ou complet (IOKit) : si la pause dure, une vérification dans `resumeDelay`. Une
    /// seule en attente à la fois ; un nouvel événement la reporte.
    public func systemDidPowerOn() {
        guard supervisor.isPausedForSleep else { return }
        log("sortie de veille : reprise de go2rtc si les écrans restent allumés \(Int(Self.resumeDelay)) s")
        scheduleCheck(after: Self.resumeDelay)
    }

    /// Réveil complet (`NSWorkspace.didWakeNotification`) : comme `systemDidPowerOn`, sans ligne de plus au journal.
    public func systemDidWake() {
        guard supervisor.isPausedForSleep else { return }
        scheduleCheck(after: Self.resumeDelay)
    }

    /// Écrans rallumés : comme `systemDidWake`.
    public func screensDidWake() {
        guard supervisor.isPausedForSleep else { return }
        scheduleCheck(after: Self.resumeDelay)
    }

    /// Écrans éteints pendant la pause (retour en réveil sombre juste après un réveil) : la vérification est reportée à
    /// `recheckInterval`. La pause garde ainsi une vérification en attente jusqu'à la reprise, même si les écrans se
    /// rallument sans qu'aucun événement n'arrive.
    public func screensDidSleep() {
        guard supervisor.isPausedForSleep else { return }
        scheduleCheck(after: Self.recheckInterval)
    }

    // MARK: - Vérification de reprise

    /// Si la pause ne dure plus, rien ; si les écrans sont allumés, go2rtc repart ; sinon, nouvelle vérification dans
    /// `recheckInterval`.
    private func check() {
        pendingCheck = nil
        guard supervisor.isPausedForSleep else { return }
        guard screensAwake() else {
            log("écrans toujours éteints (réveil sombre) : go2rtc reste arrêté")
            scheduleCheck(after: Self.recheckInterval)
            return
        }
        // La ligne dit ce que la reprise a vraiment fait : l'interrupteur a pu être éteint, go2rtc échouer ou l'app se
        // terminer pendant la pause, et le gardien peut ne pas être encore sorti.
        if let line = Self.resumeLine(supervisor.resumeAfterSleep()) {
            log(line)
        }
    }

    /// La ligne du journal pour chaque issue de la reprise ; aucune hors d'une pause.
    static func resumeLine(_ outcome: SleepResume) -> String? {
        switch outcome {
        case .notPaused: nil
        case .relaunched: "réveil complet : go2rtc relancé"
        case .afterGardienExits: "réveil complet : go2rtc relancé à la sortie du gardien"
        case .switchedOff: "réveil complet : go2rtc éteint, rien à relancer"
        case .failed: "réveil complet : go2rtc en échec, rien à relancer"
        case .quitting: "réveil complet : l'app se termine, rien à relancer"
        }
    }

    private func scheduleCheck(after delay: TimeInterval) {
        pendingCheck?.cancel()
        pendingCheck = scheduler.schedule(after: delay) { [weak self] in
            self?.check()
        }
    }

    private func cancelCheck() {
        pendingCheck?.cancel()
        pendingCheck = nil
    }

    /// « 2,4 » : une décimale, avec une virgule.
    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", max(0, value)).replacingOccurrences(of: ".", with: ",")
    }
}

/// Une annonce de veille en attente d'acquittement, qui n'est donné qu'une fois : à la fin de l'arrêt de go2rtc ou à la
/// limite de temps, le premier des deux.
@MainActor
private final class SleepAnnouncement {
    let startedAt: TimeInterval
    /// La limite de temps, retirée à l'acquittement.
    var limit: (any Cancellable)?
    private var acknowledge: (@MainActor () -> Void)?

    init(startedAt: TimeInterval, acknowledge: @escaping @MainActor () -> Void) {
        self.startedAt = startedAt
        self.acknowledge = acknowledge
    }

    var isPending: Bool {
        acknowledge != nil
    }

    /// Acquitte, s'il ne l'est pas déjà.
    func finish() {
        limit?.cancel()
        limit = nil
        let action = acknowledge
        acknowledge = nil
        action?()
    }
}

extension Go2RTCSleepPause {
    /// Le câblage de l'app : les écrans tels que macOS les voit (l'écran principal n'est pas éteint), et le journal de
    /// go2rtc (`go2rtc.log`), où le gardien et go2rtc écrivent aussi, pour que le banc lise tout au même endroit.
    public static func system(supervisor: Go2RTCSupervisor, paths: AppPaths, scheduler: any Scheduler) -> Go2RTCSleepPause {
        Go2RTCSleepPause(
            supervisor: supervisor,
            scheduler: scheduler,
            screensAwake: { CGDisplayIsAsleep(CGMainDisplayID()) == 0 },
            log: { Go2RTCJournal.append($0, to: paths.go2rtcLog) }
        )
    }
}

/// Les lignes de PTZBot dans `go2rtc.log` : « HH:mm:ss PTZBot : … », à côté de celles du gardien (« gardien : … ») et de
/// go2rtc.
enum Go2RTCJournal {
    /// La ligne datée de l'heure locale, sans saut de ligne.
    static func line(_ text: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return "\(formatter.string(from: date)) PTZBot : \(text)"
    }

    /// Ajoute une ligne en fin de fichier, ouvert en ajout (le gardien et go2rtc y écrivent aussi) : une écriture par
    /// ligne. Les erreurs sont ignorées : le journal ne doit jamais retarder la veille.
    @MainActor
    static func append(_ text: String, to url: URL, at date: Date = Date()) {
        guard let handle = try? FoundationProcessLauncher.appendingHandle(url) else { return }
        defer { try? handle.close() }
        try? handle.write(contentsOf: Data((line(text, at: date) + "\n").utf8))
    }
}
