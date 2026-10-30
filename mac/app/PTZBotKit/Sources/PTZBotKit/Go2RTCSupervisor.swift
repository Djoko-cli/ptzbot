import Foundation
import Observation

/// Pourquoi go2rtc ne tourne pas (spec B3 § 5).
public enum Go2RTCFailure: Equatable, Sendable {
    /// La préparation l'a empêché : ffmpeg, appareil, port, yaml.
    case blocked(Go2RTCBlock)
    /// Plus de `maxUnexpectedExits` arrêts inattendus en `failureWindow` secondes.
    case crashLoop
    /// Le gardien n'a pas pu être lancé.
    case launch(String)
    /// Le gardien n'a pas trouvé go2rtc dans l'app (code 127).
    case missingBinary
    /// Le gardien ne sort pas, même après SIGKILL.
    case unkillable
}

/// Lance go2rtc par le gardien (spec B3 § 3.2 et § 3.3 ; lancé par launchd, § 14), le relance s'il s'arrête et
/// l'arrête en douceur. Sur le modèle de `ServiceSupervisor` (ptzd), avec une préparation avant chaque lancement.
/// Éteint par défaut : il ne doit pas prendre la caméra de quelqu'un qui a déjà son go2rtc.
@MainActor
@Observable
public final class Go2RTCSupervisor {
    public enum State: Equatable, Sendable {
        case stopped
        /// Préparation (ffmpeg, appareils, yaml, ports), puis lancement.
        case starting
        case running
        /// Arrêt inattendu ; relance prévue (n-ième relance de suite).
        case restarting(count: Int)
        case failed(Go2RTCFailure)
    }

    /// Ce que le superviseur lance.
    public struct Paths: Equatable, Sendable {
        public var gardien: URL
        public var go2rtc: URL
        /// Le journal : la sortie et les erreurs du gardien et de go2rtc y sont ajoutées.
        public var log: URL

        public init(gardien: URL, go2rtc: URL, log: URL) {
            self.gardien = gardien
            self.go2rtc = go2rtc
            self.log = log
        }
    }

    /// Délais de relance successifs ; le dernier se répète.
    public static let restartDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    /// Au-delà de `maxUnexpectedExits` arrêts inattendus en `failureWindow` secondes : `failed(.crashLoop)`.
    public static let maxUnexpectedExits = 5
    /// Un go2rtc qui a tenu `failureWindow` secondes repart du premier délai.
    public static let failureWindow: TimeInterval = 120
    /// Le délai que le gardien laisse à go2rtc entre SIGTERM et SIGKILL (`--arret`) : go2rtc arrête ses ffmpeg par
    /// SIGTERM (`killsignal=15`), jamais un ffmpeg qui capture par SIGKILL.
    public static let stopDelay: TimeInterval = 10
    /// Le temps que le gardien laisse ensuite aux ffmpeg restants (`Gardien.orphanWait`, 4 SIGTERM à 1 s d'intervalle).
    public static let gardienOrphanWait: TimeInterval = 5
    /// Le gardien lui-même ne reçoit SIGKILL qu'après ce délai : son pire cas, 10 s pour go2rtc puis 5 s pour ses
    /// ffmpeg, plus une marge d'une seconde (le journal garde ainsi la ligne « laissé en vie »).
    public static let killDelay: TimeInterval = 16
    /// Un port vu pris au lancement : `portRetries` nouveaux essais, un tous les `portRetryDelay` secondes, avant l'échec
    /// « port déjà utilisé ». Le port d'un go2rtc qui vient de sortir (ou d'un client qui ferme) se libère en quelques
    /// instants. Une relance ultérieure reste possible, par l'interrupteur ou « Appliquer ».
    public static let portRetryDelay: TimeInterval = 1
    public static let portRetries = 5
    public static let enabledKey = "go2rtcEnabled"
    /// Code de sortie du gardien quand go2rtc n'a pas pu être lancé.
    public static let missingBinaryStatus: Int32 = 127

    public private(set) var state: State = .stopped
    /// L'interrupteur « go2rtc », retenu d'un lancement à l'autre ; éteint par défaut.
    public private(set) var isEnabled: Bool
    /// Le go2rtc en cours tourne sur un fichier personnalisé.
    public private(set) var usesCustomFile = false
    /// Le pid du gardien en cours : go2rtc et ses ffmpeg en descendent (détecteur de coreaudiod).
    public private(set) var gardienPID: pid_t?
    /// Le nombre de lancements : la surveillance du journal repart de zéro à chaque nouveau go2rtc.
    public private(set) var launchCount = 0
    /// La taille du journal au dernier lancement : la surveillance n'en lit que la suite.
    public private(set) var logOffsetAtLaunch: UInt64 = 0
    /// Les réglages du prochain lancement ; « Appliquer » les remplace (`Go2RTCSettingsModel`).
    public var configuration: Go2RTCSettings

    @ObservationIgnored private let paths: Paths
    @ObservationIgnored private let launcher: any ProcessLauncher
    @ObservationIgnored private let preparer: any Go2RTCPreparing
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private let parentPID: pid_t
    @ObservationIgnored private var process: (any LaunchedProcess)?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var launchedAt: TimeInterval = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restartCount = 0
    @ObservationIgnored private var unexpectedExits: [TimeInterval] = []
    @ObservationIgnored private var pendingRestart: (any Cancellable)?
    @ObservationIgnored private var pendingPortRetry: (any Cancellable)?
    @ObservationIgnored private var portRetriesDone = 0
    @ObservationIgnored private var pendingKill: (any Cancellable)?
    @ObservationIgnored private var pendingWatchdog: (any Cancellable)?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var restartAfterStop = false
    @ObservationIgnored private var quitting = false
    @ObservationIgnored private var stopCompletions: [@MainActor () -> Void] = []

    public init(
        paths: Paths,
        launcher: any ProcessLauncher,
        preparer: any Go2RTCPreparing,
        settings: any SettingsStore,
        scheduler: any Scheduler,
        parentPID: pid_t,
        configuration: Go2RTCSettings
    ) {
        self.paths = paths
        self.launcher = launcher
        self.preparer = preparer
        self.settings = settings
        self.scheduler = scheduler
        self.parentPID = parentPID
        self.configuration = configuration
        isEnabled = settings.bool(forKey: Self.enabledKey) ?? false
    }

    /// Le superviseur de l'app : le gardien est lancé par launchd (`LaunchdProcessLauncher`, spec B3 § 14) et non comme
    /// enfant de l'app, pour que la caméra ne soit pas filmée dans la coalition de PTZBot ; préférences de l'utilisateur,
    /// PID de l'app, réglages retenus.
    public static func system(paths: AppPaths, preparer: any Go2RTCPreparing, scheduler: any Scheduler) -> Go2RTCSupervisor {
        let store = UserDefaultsSettingsStore(defaults: .standard)
        return Go2RTCSupervisor(
            paths: paths.go2rtcService,
            launcher: LaunchdProcessLauncher.system(supportDirectory: paths.support),
            preparer: preparer,
            settings: store,
            scheduler: scheduler,
            parentPID: getpid(),
            configuration: Go2RTCSettings.restore(from: store, config: paths.go2rtcConfig)
        )
    }

    /// `gardien --parent <PTZBot> --arret 10 [--rtsp <port> [--capture <md5>]…] -- go2rtc -config <yaml>` (spec B3
    /// § 3.2) : le port RTSP réglé et les empreintes des sources du yaml généré, pour le ménage des ffmpeg décrochés.
    public func arguments(for launch: Go2RTCLaunch) -> [String] {
        var arguments = ["--parent", String(parentPID), "--arret", String(Int(Self.stopDelay))]
        if let port = launch.rtspPort {
            arguments += ["--rtsp", String(port)] + launch.captures.flatMap { ["--capture", $0] }
        }
        return arguments + ["--", paths.go2rtc.path, "-config", launch.config.path]
    }

    /// Le PATH de go2rtc : le dossier de ffmpeg d'abord, puis `/usr/bin:/bin` (la source `ffmpeg:obsbot#audio=opus`
    /// lance `ffmpeg` par son nom).
    public static func environment(ffmpegDirectory: URL?) -> [String: String] {
        ["PATH": ((ffmpegDirectory.map { [$0.path] } ?? []) + ["/usr/bin", "/bin"]).joined(separator: ":")]
    }

    /// Lance go2rtc s'il est autorisé et ne tourne pas déjà. Depuis `failed`, repart de zéro.
    public func start() {
        guard isEnabled, !stopping, !quitting else { return }
        switch state {
        case .stopped, .failed:
            restartCount = 0
            unexpectedExits = []
            launch()
        case .starting, .running, .restarting:
            break
        }
    }

    /// SIGTERM au gardien, qui le transmet à go2rtc et laisse `stopDelay` secondes ; SIGKILL au gardien après
    /// `killDelay` s'il vit encore. `completion` quand il est sorti. Une préparation en cours est abandonnée.
    /// `forQuit` : l'app se termine, go2rtc ne sera plus relancé.
    public func stop(forQuit: Bool = false, completion: @escaping @MainActor () -> Void = {}) {
        if forQuit {
            quitting = true
        }
        restartAfterStop = false
        pendingRestart?.cancel()
        pendingRestart = nil
        pendingPortRetry?.cancel()
        pendingPortRetry = nil
        guard let process else {
            // Le numéro change : une préparation en cours ne lancera rien.
            generation += 1
            state = .stopped
            completion()
            return
        }
        stopCompletions.append(completion)
        guard !stopping else { return }
        stopping = true
        process.terminate()
        pendingKill = scheduler.schedule(after: Self.killDelay) { [weak self] in
            guard let self, let process = self.process else { return }
            pendingKill = nil
            armWatchdog()
            process.kill()
        }
    }

    /// L'interrupteur « go2rtc » : retenu, puis go2rtc lancé ou arrêté.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        settings.set(enabled, forKey: Self.enabledKey)
        if enabled {
            if stopping {
                restartAfterStop = !quitting
            } else {
                start()
            }
        } else {
            stop()
        }
    }

    /// « Appliquer » : go2rtc s'arrête en douceur, puis repart sur `configuration`.
    public func restart() {
        guard isEnabled, !quitting else { return }
        if stopping {
            restartAfterStop = true
            return
        }
        stop { [weak self] in
            self?.start()
        }
    }

    /// Attend la fin de la préparation en cours (tests).
    public func waitForPreparation() async {
        await preparation?.value
    }

    // MARK: - Processus

    private func launch() {
        state = .starting
        // Chaque lancement a son numéro : une préparation ou une fin d'un lancement déjà remplacé est ignorée.
        generation += 1
        portRetriesDone = 0
        prepare(generation: generation)
    }

    private func prepare(generation launchedGeneration: Int) {
        let settings = configuration
        let preparer = preparer
        preparation = Task { [weak self] in
            let result = await Task.detached { await preparer.prepare(settings) }.value
            self?.prepared(result, generation: launchedGeneration)
        }
    }

    private func prepared(_ result: Go2RTCPreparation, generation launchedGeneration: Int) {
        guard launchedGeneration == generation, state == .starting, isEnabled, !stopping, !quitting else { return }
        switch result {
        case let .blocked(.portBusy(port)):
            guard portRetriesDone < Self.portRetries else {
                state = .failed(.blocked(.portBusy(port)))
                return
            }
            portRetriesDone += 1
            pendingPortRetry = scheduler.schedule(after: Self.portRetryDelay) { [weak self] in
                guard let self else { return }
                pendingPortRetry = nil
                guard launchedGeneration == generation, state == .starting, isEnabled, !stopping, !quitting else { return }
                prepare(generation: launchedGeneration)
            }
        case let .blocked(block):
            state = .failed(.blocked(block))
        case let .ready(launch):
            spawn(launch, generation: launchedGeneration)
        }
    }

    private func spawn(_ launch: Go2RTCLaunch, generation launchedGeneration: Int) {
        logOffsetAtLaunch = Self.size(of: paths.log)
        let launched: any LaunchedProcess
        do {
            launched = try launcher.launch(
                executableURL: paths.gardien,
                arguments: arguments(for: launch),
                environment: Self.environment(ffmpegDirectory: launch.ffmpegDirectory),
                outputURL: paths.log
            ) { [weak self] exit in
                guard let self, launchedGeneration == generation, process != nil else { return }
                exited(exit)
            }
        } catch {
            state = .failed(.launch(error.localizedDescription))
            return
        }
        process = launched
        // PID 0 : le gardien était déjà sorti avant qu'on ait vu son PID. Le prendre pour racine ferait compter tous les
        // ffmpeg vidéo du Mac (le PID 0 est l'ancêtre de tout) le temps que sa sortie soit livrée.
        gardienPID = launched.pid > 0 ? launched.pid : nil
        usesCustomFile = launch.custom
        launchCount += 1
        launchedAt = scheduler.now
        state = .running
    }

    private func exited(_ exit: ProcessExit) {
        process = nil
        gardienPID = nil
        pendingKill?.cancel()
        pendingKill = nil
        pendingWatchdog?.cancel()
        pendingWatchdog = nil
        if stopping {
            stopping = false
            state = .stopped
            let completions = stopCompletions
            stopCompletions = []
            completions.forEach { $0() }
            if restartAfterStop {
                restartAfterStop = false
                start()
            }
            return
        }
        if !exit.signaled, exit.status == Self.missingBinaryStatus {
            state = .failed(.missingBinary)
            return
        }
        unexpectedExit()
    }

    private func unexpectedExit() {
        let now = scheduler.now
        if now - launchedAt >= Self.failureWindow {
            // go2rtc a tenu : les délais repartent du premier.
            restartCount = 0
        }
        unexpectedExits = unexpectedExits.filter { now - $0 < Self.failureWindow } + [now]
        guard unexpectedExits.count <= Self.maxUnexpectedExits else {
            state = .failed(.crashLoop)
            return
        }
        restartCount += 1
        state = .restarting(count: restartCount)
        pendingRestart = scheduler.schedule(after: Self.restartDelays[min(restartCount, Self.restartDelays.count) - 1]) { [weak self] in
            guard let self else { return }
            pendingRestart = nil
            guard case .restarting = state else { return }
            guard isEnabled else {
                state = .stopped
                return
            }
            launch()
        }
    }

    /// Après SIGKILL, le gardien doit sortir dans `killDelay` ; sinon l'arrêt est abandonné.
    private func armWatchdog() {
        let killedGeneration = generation
        pendingWatchdog = scheduler.schedule(after: Self.killDelay) { [weak self] in
            guard let self, self.generation == killedGeneration, process != nil else { return }
            pendingWatchdog = nil
            process = nil
            gardienPID = nil
            stopping = false
            restartAfterStop = false
            state = .failed(.unkillable)
            let completions = stopCompletions
            stopCompletions = []
            completions.forEach { $0() }
        }
    }

    /// La taille d'un fichier, 0 s'il n'existe pas.
    static func size(of url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
