import Foundation
import Observation

/// La surveillance de go2rtc (spec B3 § 5) : le journal, relu toutes les 10 s tant que go2rtc tourne (refus d'accès,
/// `exec: timeout`, qui déclenche une sonde de coreaudiod) ; et, seulement pendant que le panneau est ouvert, l'API
/// (clients, producteur) et les processus (ffmpeg vidéo en trop, qui déclenchent aussi une sonde), toutes les 2 s.
@MainActor
@Observable
public final class Go2RTCMonitor {
    public static let pollInterval: TimeInterval = 2
    public static let logScanInterval: TimeInterval = 10

    /// Le stream `obsbot` lu dans l'API ; nil hors lecture, API muette ou stream absent.
    public private(set) var stream: Go2RTCStreamStatus?
    public private(set) var health = Go2RTCHealth()

    @ObservationIgnored private let supervisor: Go2RTCSupervisor
    @ObservationIgnored private let api: any Go2RTCAPI
    @ObservationIgnored private let processes: any ProcessListing
    @ObservationIgnored private let probe: any CoreAudioProbe
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private var reader: Go2RTCLogReader
    @ObservationIgnored private var seenLaunch = 0
    @ObservationIgnored private var coreAudio = CoreAudioWatch()
    @ObservationIgnored private var probing: Task<Void, Never>?
    /// La garde de la sonde en cours : à son échéance, une sonde sans résultat compte pour ratée.
    @ObservationIgnored private var probeGuard: (any Cancellable)?
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var poll: (any Cancellable)?
    @ObservationIgnored private var polling: Task<Void, Never>?

    public init(
        supervisor: Go2RTCSupervisor,
        api: any Go2RTCAPI,
        processes: any ProcessListing,
        probe: any CoreAudioProbe,
        logURL: URL,
        scheduler: any Scheduler
    ) {
        self.supervisor = supervisor
        self.api = api
        self.processes = processes
        self.probe = probe
        self.scheduler = scheduler
        reader = Go2RTCLogReader(url: logURL)
    }

    public static func system(supervisor: Go2RTCSupervisor, paths: AppPaths, scheduler: any Scheduler) -> Go2RTCMonitor {
        Go2RTCMonitor(supervisor: supervisor, api: URLSessionGo2RTCAPI(), processes: SystemProcessListing(),
                      probe: SystemCoreAudioProbe(), logURL: paths.go2rtcLog, scheduler: scheduler)
    }

    /// Au lancement de l'app : le journal est relu toutes les 10 s, pour toute la vie de l'app.
    public func start() {
        guard !started else { return }
        started = true
        scheduleLogScan()
    }

    /// Panneau ouvert : une lecture tout de suite, puis toutes les 2 s.
    public func beginWatching() {
        guard !watching else { return }
        watching = true
        polling = Task { [weak self] in
            await self?.refresh()
            self?.scheduleNextPoll()
        }
    }

    /// Panneau fermé : plus de lecture de l'API ni des processus.
    public func endWatching() {
        watching = false
        poll?.cancel()
        poll = nil
        // Plus de contrôle : les ffmpeg vidéo vus avant la fermeture ne comptent plus « de suite » à la réouverture.
        coreAudio.videoCount(0, now: scheduler.now)
        update()
    }

    /// Attend la lecture en cours (tests).
    public func waitForPoll() async {
        await polling?.value
    }

    /// Attend la sonde de coreaudiod en cours (tests).
    public func waitForProbe() async {
        await probing?.value
    }

    /// Le journal depuis le dernier lancement de go2rtc : un nouveau go2rtc efface les alertes du précédent.
    public func scanLog() {
        guard supervisor.state == .running else {
            update()
            return
        }
        if supervisor.launchCount != seenLaunch {
            seenLaunch = supervisor.launchCount
            reader.reset(to: supervisor.logOffsetAtLaunch)
            health.accessDenied = false
            coreAudio.reset()
        }
        let scan = Go2RTCLogPatterns.scan(reader.readNew())
        if scan.sawTimeout {
            // L'heure de la lecture, pas celle de la ligne : une ligne d'avant la veille, lue au réveil, ouvre aussi la
            // suspicion ; la sonde la lève si coreaudiod répond.
            coreAudio.sawTimeout(at: scheduler.now)
        }
        if scan.sawAccessDenied {
            health.accessDenied = true
        }
        update()
        probeIfNeeded()
    }

    /// Suspicion ouverte : coreaudiod est sondé, hors du fil de l'interface, au plus une fois toutes les 30 s et jamais
    /// deux fois en même temps. La sonde est bornée par `ChildProcess.run` ; la garde `probeGuard` couvre en plus le cas
    /// où l'enfant ne se laisserait pas tuer : la sonde est comptée ratée, la suivante peut partir, et la réponse tardive
    /// de la première est ignorée (son numéro n'est plus le bon).
    private func probeIfNeeded() {
        guard supervisor.state == .running, coreAudio.shouldProbe(now: scheduler.now) else { return }
        let number = coreAudio.probeStarted(now: scheduler.now)
        let probe = probe
        probeGuard?.cancel()
        probeGuard = scheduler.schedule(after: CoreAudioDetector.probeGuard) { [weak self] in
            guard let self else { return }
            probeGuard = nil
            coreAudio.probeFinished(responds: false, probe: number)
            update()
        }
        probing = Task { [weak self] in
            let responds = await Task.detached { probe.coreAudioResponds() }.value
            guard let self else { return }
            coreAudio.probeFinished(responds: responds, probe: number)
            update()
            // Un résultat périmé (garde déjà passée) n'a pas à défaire la garde d'une sonde plus récente.
            if !coreAudio.isProbing {
                probeGuard?.cancel()
                probeGuard = nil
            }
        }
    }

    /// Une lecture du journal, de l'API et des processus.
    public func refresh() async {
        scanLog()
        guard supervisor.state == .running, let root = supervisor.gardienPID else {
            stream = nil
            coreAudio.videoCount(0, now: scheduler.now)
            update()
            return
        }
        let api = api
        let processes = processes
        let body = try? await api.streams()
        let output = await Task.detached { processes.psOutput() }.value
        // go2rtc a pu s'arrêter pendant la lecture.
        guard supervisor.state == .running else { return }
        stream = body.flatMap { Go2RTCStreams.status(of: Go2RTCSettings.streamName, in: $0) }
        coreAudio.videoCount(output.map { CoreAudioDetector.videoFFmpegCount(psOutput: $0, root: root) } ?? 0, now: scheduler.now)
        update()
        // Le signal fort ouvre une suspicion : coreaudiod est sondé, aux mêmes règles.
        probeIfNeeded()
    }

    private func update() {
        let running = supervisor.state == .running
        health.coreAudioStuck = running && coreAudio.isStuck(now: scheduler.now)
        health.capturesStuck = running && coreAudio.capturesStuck(now: scheduler.now)
        health.capturesStuckLong = running && coreAudio.capturesStuckLong(now: scheduler.now)
        health.cameraMissing = running && stream?.hasActiveProducer == false
        if !running {
            health.accessDenied = false
            stream = nil
        }
    }

    private func scheduleNextPoll() {
        guard watching else { return }
        poll = scheduler.schedule(after: Self.pollInterval) { [weak self] in
            guard let self, watching else { return }
            polling = Task { [weak self] in
                await self?.refresh()
                self?.scheduleNextPoll()
            }
        }
    }

    private func scheduleLogScan() {
        scheduler.schedule(after: Self.logScanInterval) { [weak self] in
            guard let self else { return }
            scanLog()
            scheduleLogScan()
        }
    }
}
