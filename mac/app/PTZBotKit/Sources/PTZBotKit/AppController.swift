import Foundation
import Observation

/// Le lancement et l'arrêt de l'app autour de ptzd (spec ptzd dans l'app § 5.3, § 5.5 et § 5.6) et de go2rtc (spec B3
/// § 3.3) : ancienne installation détectée et remplacée après confirmation, `config.json` créé au besoin,
/// supervision de ptzd et de go2rtc, état du SDK, « Quitter » qui attend ptzd et go2rtc.
@MainActor
@Observable
public final class AppController {
    public enum Legacy: Equatable, Sendable {
        /// Détection en cours.
        case checking
        /// Aucune ancienne installation, ou remplacée.
        case none
        /// Gardée (« Plus tard » ou échec de la migration) : l'app se branche sur l'ancien ptzd.
        case kept
    }

    /// « Quitter » attend ptzd 5 s au plus (le superviseur envoie SIGKILL à 5 s) ; marge de sécurité.
    public static let quitTimeout: TimeInterval = 6
    /// Avec go2rtc : son gardien reçoit SIGKILL à 15 s au plus tard ; marge de sécurité.
    public static let go2rtcQuitTimeout: TimeInterval = Go2RTCSupervisor.killDelay + 1

    public private(set) var legacy: Legacy = .checking
    public private(set) var migrationError: String?
    /// Alerte de migration affichée ou migration en cours.
    public private(set) var migrating = false
    /// Ce que la migration n'a pas pu faire (corbeille, reprise du SDK), sans échouer pour autant.
    public private(set) var migrationProblems: [String] = []
    /// nil pendant la vérification.
    public private(set) var sdkStatus: SDKStatus?
    /// Les outils de développement d'Apple sont installés (`xcode-select -p`) ; nil avant la première vérification.
    public private(set) var toolsAvailable: Bool?
    public private(set) var tailscaleMissing = false
    public private(set) var configError: String?
    public let supervisor: ServiceSupervisor
    /// go2rtc, processus enfant de l'app (spec B3) ; nil dans les tests qui ne s'en occupent pas.
    public let go2rtc: Go2RTCSupervisor?

    @ObservationIgnored private let legacyAgent: LegacyAgent
    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let interfaces: any InterfaceAddressProvider
    @ObservationIgnored public let sdkInstaller: SDKInstaller
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private let confirmMigration: @MainActor () async -> Bool
    @ObservationIgnored private var launched = false
    /// La vérification du SDK en cours : la suivante l'attend (jamais deux à la fois).
    @ObservationIgnored private var sdkRefresh: Task<Void, Never>?
    /// `config.json` est prêt (créé au besoin) : l'app relit le port de ptzd.
    @ObservationIgnored public var onConfigReady: (@MainActor () -> Void)?
    /// obsbot-ai vient d'être recompilé ou réinstallé : ptzd doit relancer son utilitaire (message `aiUpdated`, spec
    /// § 6.5 bis). Jamais pour une ancienne installation, dont le ptzd a son propre obsbot-ai.
    @ObservationIgnored public var onAIUpdated: (@MainActor () -> Void)?

    public init(
        supervisor: ServiceSupervisor,
        go2rtc: Go2RTCSupervisor? = nil,
        legacyAgent: LegacyAgent,
        configURL: URL,
        interfaces: any InterfaceAddressProvider,
        sdkInstaller: SDKInstaller,
        scheduler: any Scheduler,
        confirmMigration: @escaping @MainActor () async -> Bool
    ) {
        self.supervisor = supervisor
        self.go2rtc = go2rtc
        self.legacyAgent = legacyAgent
        self.configURL = configURL
        self.interfaces = interfaces
        self.sdkInstaller = sdkInstaller
        self.scheduler = scheduler
        self.confirmMigration = confirmMigration
    }

    /// Au lancement : ancienne installation ? alerte « Remplacer » / « Plus tard » ; sinon, `config.json`
    /// et ptzd. Puis l'état du SDK.
    public func launch() async {
        guard !launched else { return }
        launched = true
        // go2rtc ne dépend ni de ptzd ni de l'ancienne installation : il démarre tout de suite s'il est allumé.
        go2rtc?.start()
        let agent = legacyAgent
        let found = await Task.detached { agent.detect() }.value
        if found {
            legacy = .kept
            supervisor.legacyAgentActive = true
            await offerMigration()
        } else {
            legacy = .none
            // Une migration interrompue (app quittée entre la plist renommée et le reste) s'achève ici.
            let leftovers = await Task.detached { agent.completeLeftovers() }.value
            migrationProblems = leftovers.problems
            await startService()
        }
        await refreshSDK()
    }

    /// L'ancienne installation est gardée (« Plus tard » ou échec) : le panneau propose
    /// « Remplacer l'ancienne installation… ».
    public var canReplaceLegacy: Bool {
        legacy == .kept && !migrating
    }

    /// « Remplacer l'ancienne installation… » : la même alerte qu'au lancement, puis la même migration.
    public func offerMigration() async {
        guard legacy == .kept, !migrating else { return }
        migrating = true
        defer { migrating = false }
        if await confirmMigration() {
            await replaceLegacy()
            if legacy == .none, launched {
                // Le SDK de lib/ a pu être repris dans sdk/.
                await refreshSDK()
            }
        }
    }

    /// « Remplacer » : en cas d'échec, message, et l'app reste sur l'ancien ptzd (jamais deux à la fois).
    public func replaceLegacy() async {
        let agent = legacyAgent
        let result = await Task.detached { Result { () throws(LegacyMigrationError) in try agent.migrate() } }.value
        switch result {
        case let .success(report):
            migrationError = nil
            migrationProblems = report.problems
            legacy = .none
            supervisor.legacyAgentActive = false
            await startService()
        case let .failure(error):
            migrationError = error.message
        }
    }

    /// L'état du SDK, après une recompilation d'obsbot-ai si la source de l'app a changé (spec distribution § 6.3) :
    /// « Recompilation… » pendant ce temps, sans rien demander. Les appels sont mis à la file : une vérification ne
    /// lit jamais l'état pendant la recompilation d'une autre (elle y verrait une fausse « compilation impossible »).
    public func refreshSDK() async {
        let previous = sdkRefresh
        let task = Task { @MainActor in
            await previous?.value
            await self.performSDKRefresh()
        }
        sdkRefresh = task
        await task.value
    }

    private func performSDKRefresh() async {
        let installer = sdkInstaller
        let toolchain = installer.toolchain
        toolsAvailable = await Task.detached { toolchain.isAvailable() }.value
        if await Task.detached(operation: { installer.needsRecompile() }).value {
            sdkStatus = .recompiling
            // Un échec laisse l'ancien obsbot-ai en service ; `status()` le dit.
            let recompiled = await Task.detached { (try? installer.recompileIfNeeded()) ?? false }.value
            if recompiled {
                // ptzd a pu lancer l'ancien obsbot-ai avant la fin de la recompilation (il démarre avant) : il le relance.
                aiUpdated()
            }
        }
        sdkStatus = await Task.detached { installer.status() }.value
    }

    /// Le SDK vient d'être installé par la fenêtre « SDK OBSBOT » : obsbot-ai est neuf, ptzd relance son utilitaire,
    /// puis l'état du SDK est relu.
    public func sdkInstalled() async {
        aiUpdated()
        await refreshSDK()
    }

    private func aiUpdated() {
        guard legacy == .none else { return }
        onAIUpdated?()
    }

    /// Panneau ouvert : si les outils de développement manquaient, ils ont pu être installés depuis.
    public func panelOpened() async {
        if case .toolsRequired = sdkStatus {
            await refreshSDK()
        } else if toolsAvailable == false {
            await refreshSDK()
        }
    }

    /// « Installer les outils de développement… » : `xcode-select --install`, l'utilisateur accepte chez Apple.
    public func installDeveloperTools() {
        let toolchain = sdkInstaller.toolchain
        Task.detached { toolchain.requestInstall() }
    }

    /// « Quitter » arrête aussi la caméra HomeKit : la confirmation le dit quand go2rtc est allumé (spec B3 § 3.3).
    public var quitStopsCamera: Bool {
        go2rtc?.isEnabled == true
    }

    /// Le délai de sécurité de « Quitter » : celui de ptzd, ou celui de go2rtc quand l'app le supervise.
    public var quitDelay: TimeInterval {
        go2rtc == nil ? Self.quitTimeout : Self.go2rtcQuitTimeout
    }

    /// Arrête ptzd (SIGTERM, puis SIGKILL à 5 s) et go2rtc (SIGTERM, que le gardien transmet ; 10 s pour sortir),
    /// puis `completion`, une seule fois, quand les deux sont sortis, au plus tard après `quitDelay`.
    public func quit(completion: @escaping @MainActor () -> Void) {
        let once = Once(completion)
        let remaining = Countdown(go2rtc == nil ? 1 : 2) { once.run() }
        supervisor.stop(forQuit: true) { remaining.done() }
        go2rtc?.stop(forQuit: true) { remaining.done() }
        scheduler.schedule(after: quitDelay) { once.run() }
    }

    private func startService() async {
        let url = configURL
        let interfaces = interfaces
        let result: Result<ConfigBootstrap.Outcome, BootstrapFailure> = await Task.detached {
            do {
                return .success(try ConfigBootstrap.run(configURL: url, addresses: interfaces))
            } catch {
                return .failure(BootstrapFailure(reason: error.localizedDescription))
            }
        }.value
        switch result {
        case let .success(outcome):
            configError = nil
            tailscaleMissing = outcome == .tailscaleMissing || ConfigBootstrap.listensOnLoopbackOnly(configURL: url)
        case let .failure(failure):
            configError = Localization.text("config.json n'a pas pu être créé : \(failure.reason)")
        }
        onConfigReady?()
        // Pour le message d'un port déjà pris (sortie 75 de ptzd).
        supervisor.port = PTZDConfig.load(from: url).port
        supervisor.start()
    }
}

private struct BootstrapFailure: Error {
    var reason: String
}

/// Une action exécutée quand `count` tâches ont fini.
@MainActor
private final class Countdown {
    private var count: Int
    private let action: @MainActor () -> Void

    init(_ count: Int, action: @escaping @MainActor () -> Void) {
        self.count = count
        self.action = action
    }

    func done() {
        count -= 1
        if count == 0 {
            action()
        }
    }
}

/// Une action exécutée une seule fois.
@MainActor
private final class Once {
    private var action: (@MainActor () -> Void)?

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func run() {
        let action = action
        self.action = nil
        action?()
    }
}
