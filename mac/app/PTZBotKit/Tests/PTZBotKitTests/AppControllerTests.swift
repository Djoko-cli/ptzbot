import Foundation
import Network
import Testing
@testable import PTZBotKit

@MainActor
@Suite("Lancement et arrêt de l'app", .french)
struct AppControllerTests {
    let root: URL
    let paths: AppPaths
    let launcher = FakeLauncher()
    let scheduler = FakeScheduler()
    let launchctl = FakeLaunchctl()
    let toolchain = FakeToolchain()
    let supervisor: ServiceSupervisor
    /// go2rtc a son propre lanceur : les lancements de ptzd restent seuls dans `launcher`.
    let go2rtcLauncher = FakeLauncher()
    let go2rtcSettings = FakeSettings()

    init() throws {
        root = try FakeSDK.directory()
        paths = AppPaths(bundle: root.appending(path: "PTZBot.app"), home: root)
        supervisor = ServiceSupervisor(paths: paths.service, launcher: launcher, settings: FakeSettings(), scheduler: scheduler, parentPID: 4242)
        try FakeSDK.write(Data("int main() { return 3; }\n".utf8), to: paths.obsbotAISource)
    }

    private func installer(sdkLoads: Bool = true) -> SDKInstaller {
        SDKInstaller(
            sdkDirectory: paths.sdkDirectory,
            sourceURL: paths.obsbotAISource,
            toolchain: toolchain,
            verifier: FakeVerifier(sdkLoads).verifier,
            buildLog: paths.obsbotAIBuildLog
        )
    }

    private func controller(
        addresses: [String] = ["127.0.0.1"],
        interfaces: [InterfaceAddress]? = nil,
        sdkLoads: Bool = true,
        confirm: Bool = true,
        asked: Counter = Counter(),
        answers: Answers? = nil,
        go2rtc: Go2RTCSupervisor? = nil
    ) -> AppController {
        AppController(
            supervisor: supervisor,
            go2rtc: go2rtc,
            legacyAgent: LegacyAgent(
                launchAgentsDirectory: root.appending(path: "LaunchAgents"),
                supportDirectory: paths.support,
                launchctl: launchctl,
                trash: FakeTrash(directory: root.appending(path: "Trash")),
                sleep: { _ in }
            ),
            configURL: paths.config,
            interfaces: interfaces.map { FakeInterfaces(interfaces: $0) } ?? FakeInterfaces(addresses: addresses),
            sdkInstaller: installer(sdkLoads: sdkLoads),
            scheduler: scheduler,
            confirmMigration: {
                asked.value += 1
                return answers?.next() ?? confirm
            }
        )
    }

    /// L'installation actuelle : agent chargé, plist, SDK dans lib/.
    private func installLegacy() throws {
        try FakeSDK.write(Data("<plist/>".utf8), to: root.appending(path: "LaunchAgents/\(LegacyAgent.label).plist"))
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: paths.support.appending(path: "lib/libdev.dylib"))
        try FakeSDK.write(Data(#"{"listenAddress":"100.64.0.1"}"#.utf8), to: paths.config)
        launchctl.state.withLock { $0.loaded = true }
    }

    @Test("Mac neuf : config.json créé, ptzd lancé, SDK absent, Tailscale signalé manquant")
    func freshMac() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = Counter()
        let app = controller(asked: asked)
        var configReady = 0
        app.onConfigReady = { configReady += 1 }
        await app.launch()
        #expect(asked.value == 0)
        #expect(app.legacy == .none)
        #expect(FileManager.default.fileExists(atPath: paths.config.path))
        #expect(app.tailscaleMissing)
        #expect(configReady == 1)
        #expect(supervisor.state == .running)
        #expect(launcher.executables == [paths.ptzd])
        #expect(try #require(launcher.last).arguments == ["--parent", "4242", "--ai", paths.obsbotAI.path, "--sdk", paths.sdkDirectory.path])
        #expect(app.sdkStatus == .absent)
        await app.launch()
        #expect(launcher.launched.count == 1)
    }

    @Test("Interface Tailscale : pas de message")
    func tailscale() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller(interfaces: [
            InterfaceAddress(interface: "lo0", address: "127.0.0.1"),
            InterfaceAddress(interface: "utun4", address: "100.64.0.1"),
        ])
        await app.launch()
        #expect(!app.tailscaleMissing)
    }

    @Test("config.json existant sur 127.0.0.1 : Tailscale signalé manquant, fichier inchangé")
    func existingLoopback() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let json = Data(#"{"listenAddress":"127.0.0.1","port":19870}"#.utf8)
        try FakeSDK.write(json, to: paths.config)
        let app = controller(addresses: ["100.64.0.1"])
        await app.launch()
        #expect(app.tailscaleMissing)
        #expect(try Data(contentsOf: paths.config) == json)
        #expect(!ConfigBootstrap.listensOnLoopbackOnly(configURL: root.appending(path: "absent.json")))
    }

    @Test("Ancienne installation, « Remplacer » : migration, puis ptzd de l'app ; SDK repris, à compléter (ni en-têtes ni obsbot-ai)")
    func replace() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        let asked = Counter()
        let app = controller(asked: asked)
        await app.launch()
        #expect(asked.value == 1)
        #expect(app.legacy == .none)
        #expect(app.migrationError == nil)
        #expect(!supervisor.legacyAgentActive)
        #expect(supervisor.state == .running)
        #expect(app.sdkStatus == .incomplete)
        #expect(FileManager.default.fileExists(atPath: paths.sdkDirectory.appending(path: "libdev.dylib").path))
        #expect(!app.tailscaleMissing)
    }

    @Test("Migration interrompue : au lancement suivant, les restes sont achevés avant ptzd ; problèmes signalés")
    func interruptedMigration() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // Ni plist ni agent chargé, mais les binaires et lib/ sont restés.
        try FakeSDK.write(Data("ptzd".utf8), to: paths.support.appending(path: "bin/ptzd"))
        try FakeSDK.write(Data("ai".utf8), to: paths.support.appending(path: "bin/obsbot-ai"))
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: paths.support.appending(path: "lib/libdev.dylib"))
        let app = controller()
        await app.launch()
        #expect(app.legacy == .none)
        #expect(app.migrationProblems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.support.appending(path: "bin/ptzd").path))
        #expect(!FileManager.default.fileExists(atPath: paths.support.appending(path: "bin/obsbot-ai").path))
        #expect(FileManager.default.fileExists(atPath: paths.sdkDirectory.appending(path: "libdev.dylib").path))
        #expect(app.sdkStatus == .incomplete)
        #expect(supervisor.state == .running)
    }

    @Test("Ancienne installation, « Plus tard » : aucun ptzd lancé, ancienne installation gardée")
    func later() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        let app = controller(confirm: false)
        await app.launch()
        #expect(app.legacy == .kept)
        #expect(supervisor.legacyAgentActive)
        supervisor.start()
        #expect(launcher.launched.isEmpty)
        #expect(supervisor.state == .stopped)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "LaunchAgents/\(LegacyAgent.label).plist").path))
    }

    @Test("« Plus tard », puis « Remplacer l'ancienne installation… » : même alerte, puis migration et ptzd")
    func replaceLater() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        let asked = Counter()
        let answers = Answers([false, false, true])
        let app = controller(asked: asked, answers: answers)
        await app.launch()
        #expect(app.canReplaceLegacy)
        await app.offerMigration()
        #expect(asked.value == 2)
        #expect(app.legacy == .kept)
        #expect(launcher.launched.isEmpty)
        await app.offerMigration()
        #expect(asked.value == 3)
        #expect(app.legacy == .none)
        #expect(!app.canReplaceLegacy)
        #expect(supervisor.state == .running)
        #expect(app.sdkStatus == .incomplete)
        await app.offerMigration()
        #expect(asked.value == 3)
    }

    @Test("bootout en échec puis réussi : le bouton relance la migration")
    func retryAfterFailure() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        launchctl.state.withLock { $0.bootoutFails = true }
        let app = controller()
        await app.launch()
        #expect(app.migrationError != nil)
        #expect(app.canReplaceLegacy)
        launchctl.state.withLock { $0.bootoutFails = false }
        await app.offerMigration()
        #expect(app.migrationError == nil)
        #expect(app.legacy == .none)
        #expect(launcher.launched.count == 1)
    }

    @Test("Échec du bootout : message, ancienne installation gardée, aucun ptzd")
    func migrationFailure() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        launchctl.state.withLock { $0.bootoutFails = true }
        let app = controller()
        await app.launch()
        #expect(app.legacy == .kept)
        #expect(app.migrationError == "L'ancienne installation n'a pas pu être arrêtée : code 5")
        #expect(launcher.launched.isEmpty)
    }

    @Test("Lancement après une mise à jour de l'app : obsbot-ai recompilé sans rien demander, puis prêt")
    func recompileAtLaunch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = installer()
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: sdk.libraryURL)
        try FakeSDK.write(Data("// en-tête".utf8), to: sdk.headersURL.appending(path: "dev/devs.hpp"))
        try FakeSDK.write(Data("ancien binaire".utf8), to: sdk.obsbotAIURL)
        try FakeSDK.write(Data("empreinte de la version précédente\n".utf8), to: sdk.hashURL)
        let app = controller()
        let updates = Counter()
        app.onAIUpdated = { updates.value += 1 }
        await app.launch()
        #expect(toolchain.compiled.count == 1)
        #expect(app.sdkStatus == .ready)
        #expect(!sdk.needsRecompile())
        // ptzd, lancé avant la recompilation, est prévenu une fois (spec § 6.5 bis) ; pas sans recompilation.
        #expect(updates.value == 1)
        await app.refreshSDK()
        #expect(updates.value == 1)
    }

    @Test("Recompilation impossible (outils absents) : ptzd n'est pas prévenu, l'ancien obsbot-ai reste en service")
    func noUpdateWithoutRecompile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = installer()
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: sdk.libraryURL)
        try FakeSDK.write(Data("// en-tête".utf8), to: sdk.headersURL.appending(path: "dev/devs.hpp"))
        try FakeSDK.write(Data("ancien binaire".utf8), to: sdk.obsbotAIURL)
        try FakeSDK.write(Data("empreinte de la version précédente\n".utf8), to: sdk.hashURL)
        toolchain.available.withLock { $0 = false }
        let app = controller()
        let updates = Counter()
        app.onAIUpdated = { updates.value += 1 }
        await app.launch()
        #expect(app.sdkStatus == .toolsRequired(fallback: true))
        #expect(updates.value == 0)
    }

    @Test("SDK installé par la fenêtre : ptzd prévenu, puis état relu ; ancienne installation : jamais prévenue")
    func sdkInstalledNotifies() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        let updates = Counter()
        app.onAIUpdated = { updates.value += 1 }
        await app.launch()
        await app.sdkInstalled()
        #expect(updates.value == 1)
        #expect(app.sdkStatus == .absent)
    }

    @Test("Ancienne installation gardée : la recompilation ne prévient pas ptzd (le sien a son propre obsbot-ai)")
    func legacyNotNotified() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        let app = controller(confirm: false)
        let updates = Counter()
        app.onAIUpdated = { updates.value += 1 }
        await app.launch()
        #expect(app.legacy == .kept)
        await app.sdkInstalled()
        #expect(updates.value == 0)
    }

    @Test("Outils absents : « Outils de développement requis » ; le bouton lance xcode-select --install ; panneau rouvert : état relu")
    func developerTools() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = installer()
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: sdk.libraryURL)
        try FakeSDK.write(Data("// en-tête".utf8), to: sdk.headersURL.appending(path: "dev/devs.hpp"))
        toolchain.available.withLock { $0 = false }
        let app = controller()
        await app.launch()
        #expect(app.sdkStatus == .toolsRequired(fallback: false))
        app.installDeveloperTools()
        for _ in 0..<200 where toolchain.installRequests.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(toolchain.installRequests.withLock { $0 } == 1)
        toolchain.available.withLock { $0 = true }
        await app.panelOpened()
        #expect(toolchain.compiled.count == 1)
        #expect(app.sdkStatus == .ready)
        // Prêt : rouvrir le panneau ne relit rien.
        await app.panelOpened()
        #expect(toolchain.compiled.count == 1)
    }

    @Test("Mac neuf sans outils d'Apple : le bouton de la ligne SDK installe les outils, avant tout choix du SDK")
    func toolsMissingOnFreshMac() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        toolchain.available.withLock { $0 = false }
        let app = controller()
        await app.launch()
        #expect(app.sdkStatus == .absent)
        #expect(app.toolsAvailable == false)
        let tools = app.toolsAvailable ?? true
        #expect(Labels.sdkAction(app.sdkStatus, toolsAvailable: tools) == "Installer les outils de développement…")
        #expect(Labels.sdkActionInstallsTools(app.sdkStatus, toolsAvailable: tools))
        // Outils installés depuis : le panneau rouvert relit l'état, et le bouton redevient « Installer le SDK… ».
        toolchain.available.withLock { $0 = true }
        await app.panelOpened()
        #expect(app.toolsAvailable == true)
        #expect(Labels.sdkAction(app.sdkStatus, toolsAvailable: app.toolsAvailable ?? true) == "Installer le SDK…")
    }

    @Test("Vérifications du SDK simultanées : mises à la file, jamais une fausse « compilation impossible »")
    func serializedRefresh() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = installer()
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: sdk.libraryURL)
        try FakeSDK.write(Data("// en-tête".utf8), to: sdk.headersURL.appending(path: "dev/devs.hpp"))
        try FakeSDK.write(Data("ancien binaire".utf8), to: sdk.obsbotAIURL)
        try FakeSDK.write(Data("autre empreinte\n".utf8), to: sdk.hashURL)
        // La compilation dure : une seconde vérification arrive pendant ce temps.
        toolchain.during.withLock { $0 = { Thread.sleep(forTimeInterval: 0.3) } }
        let app = controller()
        let seen = StatusLog()
        async let first: Void = app.refreshSDK()
        async let second: Void = app.refreshSDK()
        async let third: Void = { @MainActor in
            for _ in 0..<40 {
                seen.add(app.sdkStatus)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }()
        _ = await (first, second, third)
        #expect(app.sdkStatus == .ready)
        #expect(toolchain.compiled.count == 1)
        #expect(!seen.values.contains { if case .compileFailed = $0 { true } else { false } })
    }

    @Test("ptzd sort avec 75 : « Le port <port de config.json> est déjà pris… », sans relance")
    func portBusy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FakeSDK.write(Data(#"{"listenAddress":"127.0.0.1","port":19870}"#.utf8), to: paths.config)
        let app = controller()
        await app.launch()
        scheduler.advance(by: ServiceSupervisor.earlyBusyWindow)
        try #require(launcher.last).exit(ProcessExit(status: 75, signaled: false))
        #expect(supervisor.state == .failed(reason: "Le port 19870 est déjà pris : un autre ptzd tourne peut-être encore"))
        #expect(Labels.service(supervisor.state, connection: .unreachable, legacy: false) == "Arrêté")
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
    }

    @Test("« Quitter » : interrupteur rallumé ensuite, ptzd n'est pas relancé")
    func quitIsFinal() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        await app.launch()
        try #require(launcher.last).ignoresTerminate = true
        var done = 0
        app.quit { done += 1 }
        supervisor.setEnabled(true)
        scheduler.advance(by: ServiceSupervisor.killDelay)
        #expect(done == 1)
        #expect(launcher.launched.count == 1)
    }

    @Test("« Quitter » : ptzd arrêté, puis completion une seule fois")
    func quit() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        await app.launch()
        var done = 0
        app.quit { done += 1 }
        #expect(try #require(launcher.last).terminations == 1)
        #expect(done == 1)
        scheduler.advance(by: AppController.quitTimeout)
        #expect(done == 1)
    }

    @Test("« Quitter » avec un ptzd dont la fin n'arrive jamais : completion au délai de sécurité, une seule fois")
    func quitTimeout() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        await app.launch()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        process.ignoresKill = true
        var done = 0
        app.quit { done += 1 }
        scheduler.advance(by: AppController.quitTimeout - 0.1)
        #expect(process.kills == 1)
        #expect(done == 0)
        scheduler.advance(by: 0.1)
        #expect(done == 1)
        scheduler.advance(by: 60)
        #expect(done == 1)
    }

    @Test("« Quitter » avec un ptzd bloqué : SIGKILL à 5 s, completion aussitôt après")
    func quitStubborn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        await app.launch()
        try #require(launcher.last).ignoresTerminate = true
        var done = 0
        app.quit { done += 1 }
        scheduler.advance(by: ServiceSupervisor.killDelay - 0.1)
        #expect(done == 0)
        scheduler.advance(by: 0.1)
        #expect(done == 1)
        #expect(try #require(launcher.last).kills == 1)
    }
}

/// go2rtc dans l'app (spec B3 § 3.3) : lancé au démarrage s'il est allumé, attendu par « Quitter ».
extension AppControllerTests {
    private func go2rtc(enabled: Bool) -> Go2RTCSupervisor {
        go2rtcSettings.values[Go2RTCSupervisor.enabledKey] = enabled
        return Go2RTCSupervisor(paths: paths.go2rtcService, launcher: go2rtcLauncher, preparer: FakePreparer(), settings: go2rtcSettings,
                                scheduler: scheduler, parentPID: 4242, configuration: Go2RTCFixtures.settings())
    }

    @Test("Au lancement : go2rtc allumé démarre, avec ptzd ; éteint, il ne démarre pas")
    func go2rtcAtLaunch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let on = go2rtc(enabled: true)
        let app = controller(go2rtc: on)
        await app.launch()
        await on.waitForPreparation()
        #expect(on.state == .running)
        #expect(go2rtcLauncher.executables == [paths.gardien])
        #expect(launcher.executables == [paths.ptzd])
        #expect(app.quitStopsCamera)
        let off = go2rtc(enabled: false)
        let other = controller(go2rtc: off)
        await other.launch()
        await off.waitForPreparation()
        #expect(off.state == .stopped)
        #expect(!other.quitStopsCamera)
    }

    @Test("« Quitter » : ptzd et go2rtc arrêtés ; completion quand les deux sont sortis, une seule fois")
    func quitWaitsForGo2RTC() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let camera = go2rtc(enabled: true)
        let app = controller(go2rtc: camera)
        await app.launch()
        await camera.waitForPreparation()
        let gardien = try #require(go2rtcLauncher.last)
        gardien.ignoresTerminate = true
        var done = 0
        app.quit { done += 1 }
        #expect(try #require(launcher.last).terminations == 1)
        #expect(gardien.terminations == 1)
        #expect(done == 0, "ptzd est sorti, go2rtc pas encore")
        scheduler.advance(by: Go2RTCSupervisor.stopDelay)
        #expect(done == 0)
        gardien.exit(ProcessExit(status: SIGTERM, signaled: true))
        #expect(done == 1)
        scheduler.advance(by: AppController.go2rtcQuitTimeout)
        #expect(done == 1)
        #expect(go2rtcLauncher.launched.count == 1)
    }

    @Test("« Quitter » avec un gardien qui ne sort pas : completion au délai de sécurité de go2rtc (16 s)")
    func quitGo2RTCTimeout() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let camera = go2rtc(enabled: true)
        let app = controller(go2rtc: camera)
        await app.launch()
        await camera.waitForPreparation()
        let gardien = try #require(go2rtcLauncher.last)
        gardien.ignoresTerminate = true
        gardien.ignoresKill = true
        var done = 0
        app.quit { done += 1 }
        #expect(app.quitDelay == AppController.go2rtcQuitTimeout)
        scheduler.advance(by: AppController.go2rtcQuitTimeout - 0.1)
        #expect(gardien.kills == 1)
        #expect(done == 0)
        scheduler.advance(by: 0.1)
        #expect(done == 1)
    }
}

/// Réponses successives à l'alerte de migration.
@MainActor
final class Answers {
    private var queue: [Bool]

    init(_ queue: [Bool]) {
        self.queue = queue
    }

    func next() -> Bool? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
}

/// Les états du SDK vus pendant un essai.
@MainActor
final class StatusLog {
    private(set) var values: [SDKStatus?] = []

    func add(_ status: SDKStatus?) {
        values.append(status)
    }
}

/// Compteur partagé avec une fermeture.
@MainActor
final class Counter {
    var value = 0
}

@MainActor
@Suite("Fenêtre « SDK OBSBOT »", .french)
struct SDKWindowModelTests {
    static func installer(_ directory: URL, loads: Bool) -> SDKInstaller {
        let source = directory.appending(path: "obsbot-ai.cpp")
        try? Data("int main() { return 3; }\n".utf8).write(to: source)
        return SDKInstaller(
            sdkDirectory: directory.appending(path: "sdk"),
            sourceURL: source,
            toolchain: FakeToolchain(),
            verifier: FakeVerifier(loads).verifier,
            buildLog: directory.appending(path: "compilation.log")
        )
    }

    @Test("Choix refusé : motif ; choix accepté puis autorisé : installé, dossier d'extraction effacé")
    func flow() async throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = Self.installer(directory, loads: true)
        let model = SDKWindowModel(installer: installer)
        var installed = 0
        model.onInstalled = { installed += 1 }

        try FakeSDK.folder(directory.appending(path: "texte"), library: Data("texte".utf8))
        await model.choose(directory.appending(path: "texte"))
        #expect(model.phase == .rejected("Ce fichier n'est pas une bibliothèque Mach-O."))
        let alone = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "seul/libdev.dylib"))
        await model.choose(alone)
        #expect(model.phase == .rejected("Choisissez l'archive ou le dossier du SDK : ses en-têtes sont nécessaires."))

        let library = try FakeSDK.folder(directory.appending(path: "choix"))
        FakeSDK.setQuarantine(library)
        await model.choose(directory.appending(path: "choix"))
        guard case let .candidate(candidate) = model.phase else {
            Issue.record("candidat attendu")
            return
        }
        #expect(candidate.quarantined)
        await model.authorize()
        #expect(model.phase == .installed)
        #expect(installed == 1)
        #expect(!FakeSDK.isQuarantined(installer.libraryURL))
        #expect(FakeSDK.isQuarantined(library))
        model.reset()
        #expect(model.phase == .choosing)
    }

    @Test("Fenêtre fermée pendant l'examen : dossier d'extraction effacé, choix oublié")
    func closedDuringInspection() async throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let extraction = directory.appending(path: "extraction")
        let library = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: extraction.appending(path: "macos/arm64-release/libdev.dylib"))
        // L'examen reste en cours tant que le test ne l'a pas libéré : la fermeture tombe toujours pendant l'examen,
        // quelle que soit la charge de la machine.
        let release = DispatchSemaphore(value: 0)
        let model = SDKWindowModel(
            installer: Self.installer(directory, loads: true),
            inspect: { _ throws(SDKRejection) in
                release.wait()
                return SDKCandidate(path: library, architectures: ["arm64"], temporaryDirectory: extraction)
            }
        )
        let choice = Task { await model.choose(URL(fileURLWithPath: "/archive.zip")) }
        let deadline = ContinuousClock.now + .seconds(10)
        while model.phase != .inspecting, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(model.phase == .inspecting)
        model.reset()
        release.signal()
        await choice.value
        #expect(model.phase == .choosing)
        #expect(!FileManager.default.fileExists(atPath: extraction.path))
    }

    @Test("Outils absents : la fenêtre propose de les installer avant le choix ; xcode-select --install sur clic seulement")
    func toolsFirst() async throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let toolchain = FakeToolchain(available: false)
        let source = try FakeSDK.write(Data("int main() { return 3; }\n".utf8), to: directory.appending(path: "obsbot-ai.cpp"))
        let model = SDKWindowModel(installer: SDKInstaller(
            sdkDirectory: directory.appending(path: "sdk"),
            sourceURL: source,
            toolchain: toolchain,
            verifier: FakeVerifier(true).verifier,
            buildLog: directory.appending(path: "compilation.log")
        ))
        #expect(model.toolsAvailable)
        await model.checkTools()
        #expect(!model.toolsAvailable)
        #expect(toolchain.installRequests.withLock { $0 } == 0)
        model.installTools()
        for _ in 0..<200 where toolchain.installRequests.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(toolchain.installRequests.withLock { $0 } == 1)
        toolchain.available.withLock { $0 = true }
        await model.checkTools()
        #expect(model.toolsAvailable)
        // Outils disparus entre la vérification et l'installation : la fenêtre repasse aux outils.
        try FakeSDK.folder(directory.appending(path: "choix"))
        await model.choose(directory.appending(path: "choix"))
        toolchain.available.withLock { $0 = false }
        await model.authorize()
        #expect(model.phase == .failed(SDKInstallError.toolsMissing.message))
        #expect(!model.toolsAvailable)
    }

    @Test("Vérification en échec : message, rien n'est installé")
    func failure() async throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = Self.installer(directory, loads: false)
        let model = SDKWindowModel(installer: installer)
        try FakeSDK.folder(directory.appending(path: "choix"))
        await model.choose(directory.appending(path: "choix"))
        await model.authorize()
        #expect(model.phase == .failed(SDKInstallError.unloadable.message))
        #expect(!FileManager.default.fileExists(atPath: installer.libraryURL.path))
    }
}

@Suite("Textes du service et du SDK", .french)
struct ServiceLabelsTests {
    @Test("État du service : supervision, puis connexion de confiance ; ancienne installation")
    func service() {
        #expect(Labels.service(.running, connection: .active, legacy: false) == "Actif")
        #expect(Labels.service(.running, connection: .connecting, legacy: false) == "Démarrage…")
        #expect(Labels.service(.running, connection: .unreachable, legacy: false) == "Ne répond pas")
        #expect(Labels.service(.starting, connection: .unreachable, legacy: false) == "Démarrage…")
        #expect(Labels.service(.stopped, connection: .unreachable, legacy: false) == "Arrêté")
        #expect(Labels.service(.failed(reason: "x"), connection: .unreachable, legacy: false) == "Arrêté")
        #expect(Labels.service(.restarting(count: 3), connection: .unreachable, legacy: false) == "Relancé après un arrêt inattendu (3)")
        #expect(Labels.service(.stopped, connection: .active, legacy: true) == "Ancienne installation")
    }

    @Test("Commandes grisées sauf service actif et connecté ; journal en cas d'échec ou sans réponse")
    func availability() {
        #expect(Labels.controlsEnabled(.running, connection: .active, legacy: false))
        #expect(!Labels.controlsEnabled(.running, connection: .unreachable, legacy: false))
        #expect(!Labels.controlsEnabled(.stopped, connection: .active, legacy: false))
        #expect(!Labels.controlsEnabled(.failed(reason: "x"), connection: .active, legacy: false))
        #expect(Labels.controlsEnabled(.stopped, connection: .active, legacy: true))
        #expect(Labels.showsLog(.failed(reason: "x"), connection: .unreachable))
        #expect(Labels.showsLog(.running, connection: .unreachable))
        #expect(!Labels.showsLog(.running, connection: .active))
        #expect(!Labels.showsLog(.stopped, connection: .unreachable))
    }

    @Test("SDK : états, suivi IA grisé tant qu'il n'est pas prêt (sauf ancienne installation)")
    func sdk() {
        #expect(Labels.sdk(.ready) == "Prêt")
        #expect(Labels.sdk(.absent) == "Absent")
        #expect(Labels.sdk(.quarantined) == "En quarantaine")
        #expect(Labels.sdk(.incompatible) == "Incompatible")
        #expect(Labels.sdk(.unloadable) == "Ne se charge pas")
        #expect(Labels.sdk(.sourceMissing) == "obsbot-ai introuvable")
        #expect(Labels.sdk(nil) == "Vérification…")
        #expect(Labels.aiNeedsSDK(.absent, legacy: false))
        #expect(Labels.aiNeedsSDK(nil, legacy: false))
        #expect(!Labels.aiNeedsSDK(.ready, legacy: false))
        #expect(!Labels.aiNeedsSDK(.absent, legacy: true))
        #expect(Labels.sdkRequired == "SDK OBSBOT requis")
        #expect(Labels.sdkAction(.ready) == "Changer…")
        #expect(Labels.sdkAction(.absent) == "Installer le SDK…")
        #expect(Labels.sdkAction(.quarantined) == "Installer le SDK…")
        #expect(Labels.sdkAction(nil) == nil)
        #expect(Labels.sdkAction(.sourceMissing) == nil)
        #expect(Labels.replaceLegacy == "Remplacer l'ancienne installation…")
    }

    @Test("SDK : nouveaux états de la compilation locale, boutons et notes (spec distribution § 6.4)")
    func compileStates() {
        // États courts, à droite de la ligne (banc du 08/10) ; l'explication va dessous.
        #expect(Labels.sdk(.toolsRequired(fallback: false)) == "Outils requis")
        #expect(Labels.sdk(.incomplete) == "À compléter")
        #expect(Labels.sdk(.recompiling) == "Recompilation…")
        #expect(Labels.sdk(.compileFailed(fallback: false)) == "Compilation impossible")
        let everyStatus: [SDKStatus?] = [nil, .ready, .absent, .quarantined, .incompatible, .unloadable, .sourceMissing,
                                         .toolsRequired(fallback: false), .incomplete, .recompiling, .compileFailed(fallback: true)]
        #expect(everyStatus.allSatisfy { Labels.sdk($0).count <= 22 })
        #expect(Labels.sdkDetail(.incomplete) == "Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent.")
        #expect(Labels.sdkDetail(.incomplete, toolsAvailable: false) == "Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent. Installez d'abord les outils de développement d'Apple.")
        #expect(Labels.sdkDetail(.absent, toolsAvailable: false) == "Installez d'abord les outils de développement d'Apple.")
        #expect(Labels.sdkDetail(.absent) == nil)
        #expect(Labels.sdkDetail(.ready) == nil)
        #expect(Labels.sdkDetail(.recompiling) == nil)
        #expect(Labels.sdkDetail(.quarantined) == "Le SDK ne se charge pas : réinstallez-le pour retirer la quarantaine de sa copie.")
        #expect(Labels.sdkDetail(.incompatible) == "Ce SDK n'a pas de version pour Apple Silicon.")
        #expect(Labels.sdkDetail(.unloadable) == "obsbot-ai ne charge pas ce SDK : réinstallez-le.")
        #expect(Labels.sdkDetail(.sourceMissing) == "La source d'obsbot-ai manque dans l'app : réinstallez PTZBot.")
        #expect(Labels.sdkAction(.toolsRequired(fallback: true)) == "Installer les outils de développement…")
        #expect(Labels.sdkActionInstallsTools(.toolsRequired(fallback: false)))
        #expect(!Labels.sdkActionInstallsTools(.absent))
        #expect(Labels.sdkAction(.incomplete) == "Installer le SDK…")
        #expect(Labels.sdkAction(.compileFailed(fallback: true)) == "Installer le SDK…")
        #expect(Labels.sdkAction(.recompiling) == nil)
        // Outils absents : le bouton installe d'abord les outils, pour un SDK absent, à compléter ou à réinstaller.
        for status in [SDKStatus.absent, .incomplete, .unloadable, .quarantined] {
            #expect(Labels.sdkAction(status, toolsAvailable: false) == "Installer les outils de développement…")
            #expect(Labels.sdkActionInstallsTools(status, toolsAvailable: false))
            #expect(!Labels.sdkActionInstallsTools(status, toolsAvailable: true))
        }
        #expect(Labels.sdkAction(.ready, toolsAvailable: false) == "Changer…")
        #expect(Labels.sdkAction(.recompiling, toolsAvailable: false) == nil)
        #expect(Labels.sdkDetail(.toolsRequired(fallback: true)) == "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai. L'ancien obsbot-ai reste en service.")
        #expect(Labels.sdkDetail(.toolsRequired(fallback: false), toolsAvailable: false) == "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai.")
        #expect(Labels.sdkDetail(.compileFailed(fallback: false)) == "Le détail est dans le journal obsbot-ai-compilation.log.")
        #expect(Labels.sdkDetail(.compileFailed(fallback: true)) == "L'ancien obsbot-ai reste en service. Le détail est dans le journal obsbot-ai-compilation.log.")
        // Ancien obsbot-ai en service : le suivi IA reste disponible.
        #expect(!Labels.aiNeedsSDK(.toolsRequired(fallback: true), legacy: false))
        #expect(Labels.aiNeedsSDK(.toolsRequired(fallback: false), legacy: false))
        #expect(Labels.aiNeedsSDK(.incomplete, legacy: false))
        #expect(Labels.aiNeedsSDK(.recompiling, legacy: false))
    }

    @Test("Lien « Installer le SDK… » du panneau : seulement si le suivi IA attend le SDK et que l'onglet a une action à proposer")
    func aiSDKLink() {
        // Le SDK est à installer, à compléter ou à réinstaller : le lien mène à l'onglet.
        for status in [SDKStatus.absent, .quarantined, .incompatible, .unloadable, .incomplete, .toolsRequired(fallback: false),
                       .compileFailed(fallback: false)] {
            #expect(Labels.aiSDKLink(status, legacy: false), "\(status)")
        }
        // L'état n'est pas encore lu, ou obsbot-ai est en cours de recompilation, ou sa source manque : pas de lien.
        #expect(!Labels.aiSDKLink(nil, legacy: false))
        #expect(!Labels.aiSDKLink(.recompiling, legacy: false))
        #expect(!Labels.aiSDKLink(.sourceMissing, legacy: false))
        // Le suivi IA est disponible (SDK prêt, ou ancien obsbot-ai en service) : pas de lien.
        #expect(!Labels.aiSDKLink(.ready, legacy: false))
        #expect(!Labels.aiSDKLink(.toolsRequired(fallback: true), legacy: false))
        #expect(!Labels.aiSDKLink(.compileFailed(fallback: true), legacy: false))
        // Ancienne installation : le SDK n'est pas nécessaire.
        #expect(!Labels.aiSDKLink(.absent, legacy: true))
        // Outils d'Apple absents : le lien reste, l'onglet propose de les installer d'abord.
        #expect(Labels.aiSDKLink(.absent, toolsAvailable: false, legacy: false))
        #expect(!Labels.aiSDKLink(.recompiling, toolsAvailable: false, legacy: false))
        #expect(!Labels.aiSDKLink(nil, toolsAvailable: false, legacy: false))
    }

    @Test("Sections du panneau : Service, Caméra avec son état, iPhone connectés, note du suivi IA")
    func sections() {
        #expect(Labels.serviceSection == "Service")
        #expect(Labels.cameraSection(.connected) == "Caméra · branchée")
        #expect(Labels.cameraSection(.absent) == "Caméra · débranchée")
        #expect(Labels.cameraSection(nil) == "Caméra · débranchée")
        #expect(Labels.iPhoneSection(count: 0) == "iPhone connectés · 0")
        #expect(Labels.noIPhone == "Aucun iPhone connecté")
        #expect(Labels.aiNote(.unknown, needsSDK: true) == "SDK OBSBOT requis")
        #expect(Labels.aiNote(.unknown, needsSDK: false) == "État inconnu")
        #expect(Labels.aiNote(.on, needsSDK: false) == nil)
        #expect(Labels.aiNote(nil, needsSDK: false) == nil)
    }

    @Test("Textes exacts de la spec : alerte de migration, confirmation du SDK")
    func specTexts() {
        #expect(Labels.migrationMessage == "Une ancienne installation de ptzd tourne en arrière-plan. PTZBot va la remplacer : le service sera désormais actif seulement quand PTZBot est ouvert. Vos iPhone appairés sont conservés.")
        #expect(Labels.sdkConfirmation == "PTZBot va copier ce fichier dans sa bibliothèque et retirer la quarantaine de cette copie. Ne le faites que si vous l'avez téléchargé depuis obsbot.com.")
        #expect(Labels.localNetworkDenied == "PTZBot n'a pas accès au réseau local : les iPhone ne le trouveront qu'avec Tailscale")
        #expect(Labels.tailscaleMissing == "Tailscale introuvable : accès depuis l'extérieur indisponible")
    }

    @Test("Vérifications du SDK : architecture, signature, provenance, quarantaine")
    func checks() {
        let signed = SDKCandidate(
            path: URL(fileURLWithPath: "/x/libdev.dylib"),
            architectures: ["arm64"],
            signer: "Developer ID Application: Exemple",
            team: "ABCDE12345",
            quarantined: true,
            origin: SDKOrigin(url: "https://example.com/libdev.zip", date: nil),
            signatureValid: true,
            appleAnchored: true
        )
        #expect(Labels.sdkChecks(signed).map(\.value) == [
            "Apple Silicon : ✓",
            "Developer ID Application: Exemple (équipe ABCDE12345)",
            "https://example.com/libdev.zip",
            "oui",
        ])
        var others = signed
        others.otherCopies = ["macos/macos/arm64-release/libdev.dylib", "macos/x86_64-release/libdev.dylib"]
        #expect(Labels.sdkChecks(others).last == Labels.SDKCheck(
            title: "Autres copies ignorées",
            value: "macos/macos/arm64-release/libdev.dylib, macos/x86_64-release/libdev.dylib"
        ))
        let bare = SDKCandidate(path: URL(fileURLWithPath: "/x/libdev.dylib"), architectures: ["x86_64"])
        #expect(Labels.sdkChecks(bare).map(\.value) == ["Apple Silicon : ✗ (x86_64)", "non signé", "inconnue", "non"])
        #expect(Labels.sdkChecks(bare).map(\.title) == ["Architecture", "Signature", "Provenance", "Quarantaine"])
        let dated = SDKCandidate(path: bare.path, architectures: ["arm64"], origin: SDKOrigin(url: nil, date: Date(timeIntervalSince1970: 0x6A00_0000)))
        #expect(Labels.sdkChecks(dated)[2].value.hasPrefix("le "))
    }

    @Test("Vérifications du SDK : signature invalide, provenance tirée de l'archive")
    func checksWarnings() {
        let altered = SDKCandidate(path: URL(fileURLWithPath: "/x/libdev.dylib"), architectures: ["arm64"], signatureValid: false)
        #expect(Labels.sdkChecks(altered)[1] == Labels.SDKCheck(title: "Signature", value: "Signature invalide"))
        // Signature intacte mais certificat inconnu d'Apple : ni signataire ni équipe, même s'ils étaient renseignés.
        let unanchored = SDKCandidate(
            path: URL(fileURLWithPath: "/x/libdev.dylib"),
            architectures: ["arm64"],
            signer: "Apple Inc.",
            team: "ABCDE12345",
            signatureValid: true,
            appleAnchored: false
        )
        #expect(Labels.sdkChecks(unanchored)[1] == Labels.SDKCheck(title: "Signature", value: "Signé, certificat non reconnu par Apple"))
        // Signé par un certificat Apple sans équipe (binaire du système) : le signataire seul.
        let system = SDKCandidate(path: unanchored.path, architectures: ["arm64"], signer: "Software Signing", signatureValid: true, appleAnchored: true)
        #expect(Labels.sdkChecks(system)[1].value == "Software Signing")
        let fromArchive = SDKCandidate(
            path: URL(fileURLWithPath: "/x/libdev.dylib"),
            architectures: ["arm64"],
            origin: SDKOrigin(url: "https://example.com/libdev.zip", date: nil, fromInsideArchive: true)
        )
        #expect(Labels.sdkChecks(fromArchive)[2].value == "https://example.com/libdev.zip (indiquée dans l'archive)")
        let direct = SDKCandidate(
            path: URL(fileURLWithPath: "/x/libdev.dylib"),
            architectures: ["arm64"],
            origin: SDKOrigin(url: "https://example.com/libdev.zip", date: nil)
        )
        #expect(Labels.sdkChecks(direct)[2].value == "https://example.com/libdev.zip")
    }

    @Test("Emplacements : utilitaires dans Contents/Helpers, SDK et journal de l'utilisateur")
    func paths() {
        let paths = AppPaths(bundle: URL(fileURLWithPath: "/Applications/PTZBot.app"), home: URL(fileURLWithPath: "/maison/exemple"))
        #expect(paths.ptzd.path == "/Applications/PTZBot.app/Contents/Helpers/ptzd")
        // obsbot-ai est compilé chez l'utilisateur, à côté du SDK ; l'app ne livre que sa source.
        #expect(paths.obsbotAI.path == "/maison/exemple/Library/Application Support/ObsbotNacelle/sdk/obsbot-ai")
        #expect(paths.obsbotAISource.path == "/Applications/PTZBot.app/Contents/Resources/obsbot-ai.cpp")
        #expect(paths.obsbotAIBuildLog.path == "/maison/exemple/Library/Logs/obsbot-nacelle/obsbot-ai-compilation.log")
        #expect(paths.service.ai == paths.obsbotAI)
        #expect(paths.sdkDirectory.path == "/maison/exemple/Library/Application Support/ObsbotNacelle/sdk")
        #expect(paths.config.path == "/maison/exemple/Library/Application Support/ObsbotNacelle/config.json")
        #expect(paths.ptzdLog.path == "/maison/exemple/Library/Logs/obsbot-nacelle/ptzd.log")
    }

    @Test("Réseau local : refus reconnu à l'erreur PolicyDenied")
    func localNetwork() {
        #expect(LocalNetworkProbe.isDenied(.waiting(.dns(-65570))) == true)
        #expect(LocalNetworkProbe.isDenied(.failed(.dns(-65570))) == true)
        #expect(LocalNetworkProbe.isDenied(.failed(.dns(-65537))) == false)
        #expect(LocalNetworkProbe.isDenied(.ready) == false)
        #expect(LocalNetworkProbe.isDenied(.setup) == nil)
        #expect(LocalNetworkProbe.isDenied(.waiting(.posix(.ENETDOWN))) == nil)
    }
}
