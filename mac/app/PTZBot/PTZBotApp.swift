import PTZBotKit
import SwiftUI

/// PTZBot pour Mac (spec app Mac, spec ptzd dans l'app, spec distribution, spec B3) : une icône dans la barre des menus,
/// un panneau, trois fenêtres (deux scènes SwiftUI, et les Réglages en AppKit : `SettingsWindowController`), ptzd lancé
/// comme processus enfant, go2rtc lancé par launchd (son gardien suit l'app), Talkback (l'agent talkd, indépendant de
/// l'app) et les mises à jour par Sparkle.
@main
struct PTZBotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: delegate.panel, talkback: delegate.talkback, settings: delegate.settings, app: delegate.controller,
                      network: delegate.network, go2rtc: delegate.go2rtc, go2rtcMonitor: delegate.go2rtcMonitor,
                      settingsWindow: delegate.settingsWindow)
                .followsLanguage(delegate.language)
        } label: {
            Image(nsImage: MenuBarIcon.image())
                .opacity(delegate.panel.service == .active ? 1 : 0.4)
                .onAppear { delegate.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Appairer un iPhone", id: WindowID.pairing) {
            PairingView(model: delegate.panel)
                .followsLanguage(delegate.language, title: "Appairer un iPhone")
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Appareils appairés", id: WindowID.devices) {
            DevicesView(model: delegate.panel)
                .followsLanguage(delegate.language, title: "Appareils appairés")
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Les modèles de l'app, créés une fois ; « Quitter » (et toute fin de l'app) attend l'arrêt de ptzd et de go2rtc.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// La langue choisie dans les Réglages, appliquée avant tout autre texte.
    let language = AppLanguageModel.system()
    let scheduler = MainScheduler()
    let panel: PanelModel
    let talkback: TalkbackModel
    let settings: SettingsModel
    let controller: AppController
    let sdkWindow: SDKWindowModel
    /// La fenêtre « Réglages », ouverte par le panneau.
    let settingsWindow: SettingsWindowController
    let network: LocalNetworkState
    /// go2rtc, lancé par launchd et supervisé par l'app (spec B3, § 14), sa surveillance et l'onglet « Caméra » des Réglages.
    let go2rtc: Go2RTCSupervisor
    let go2rtcMonitor: Go2RTCMonitor
    let cameraSettings: Go2RTCSettingsModel
    private var started = false

    override init() {
        let paths = AppPaths.system()
        panel = PanelModel(config: .load(from: paths.config), transport: URLSessionAdminTransport(), scheduler: scheduler)
        talkback = TalkbackModel(
            service: ClassicTalkbackService.system(program: paths.talkd),
            state: FileTalkbackStateSource(url: paths.talkbackState),
            process: SystemProcessProbe(),
            scheduler: scheduler,
            settings: UserDefaultsSettingsStore(defaults: .standard),
            bundleVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            fileObserver: DispatchFileChangeObserver(url: paths.talkbackState)
        )
        let installer = SDKInstaller.system(paths: paths)
        let preparer = Go2RTCPreparer.system(paths: paths)
        go2rtc = .system(paths: paths, preparer: preparer, scheduler: scheduler)
        go2rtcMonitor = .system(supervisor: go2rtc, paths: paths, scheduler: scheduler)
        cameraSettings = .system(supervisor: go2rtc, preparer: preparer)
        controller = AppController(
            supervisor: .system(paths: paths.service, scheduler: scheduler),
            go2rtc: go2rtc,
            legacyAgent: .system(supportDirectory: paths.support),
            configURL: paths.config,
            interfaces: SystemInterfaceAddresses(),
            sdkInstaller: installer,
            scheduler: scheduler,
            confirmMigration: { MigrationAlert.ask() }
        )
        sdkWindow = SDKWindowModel(installer: installer)
        network = LocalNetworkState(scheduler: scheduler)
        // Sparkle ne démarre que dans une app publiée : jamais sous les tests ni dans une compilation de travail
        // (numéro de compilation 1).
        let info = Bundle.main.infoDictionary
        let bundleVersion = info?["CFBundleVersion"] as? String
        let usesSparkle = UpdaterPolicy.usesSparkle(bundleVersion: bundleVersion, environment: ProcessInfo.processInfo.environment)
        settings = SettingsModel(
            updater: usesSparkle ? SparkleUpdater() : NoUpdater(),
            updatesEnabled: usesSparkle,
            loginItem: LoginItemModel(service: MainAppLoginItem()),
            shortVersion: info?["CFBundleShortVersionString"] as? String,
            bundleVersion: bundleVersion
        )
        settingsWindow = SettingsWindowController(settings: settings, language: language, camera: cameraSettings,
                                                  app: controller, sdk: sdkWindow)
        super.init()
        controller.onConfigReady = { [panel] in
            panel.reloadConfig(.load(from: paths.config))
        }
        sdkWindow.onInstalled = { [controller] in
            Task { await controller.sdkInstalled() }
        }
        // obsbot-ai recompilé ou réinstallé : ptzd relance son utilitaire (spec § 6.5 bis).
        controller.onAIUpdated = { [panel] in
            panel.aiUpdated()
        }
    }

    /// À la première apparition de l'icône : connexion à ptzd, ancienne installation, service, SDK, réseau local.
    func start() {
        guard !started else { return }
        started = true
        panel.start()
        // Migration depuis la 1.0.4 (désinscription de l'ancien agent, attendue) ou mise à jour de l'agent classique, hors du
        // fil de l'interface : l'état se relit une fois qu'elles sont faites.
        Task { [talkback] in
            await talkback.prepareAtLaunch()
            talkback.refresh()
        }
        network.check()
        // Un travail launchd resté d'une session précédente (app tuée) ne reste pas chargé quand go2rtc est éteint ; allumé,
        // le lancement s'en charge lui-même (spec B3 § 14).
        if !go2rtc.isEnabled {
            LaunchdProcessLauncher.removeLeftoverInBackground(supportDirectory: AppPaths.system().support)
        }
        go2rtcMonitor.start()
        Task { await controller.launch() }
    }

    /// Attend l'arrêt de ptzd et de go2rtc (6 s au plus, 16 s avec go2rtc), puis répond. C'est aussi le chemin d'une mise à jour : Sparkle demande
    /// à l'app de quitter (événement Apple « quitter ») avant de la remplacer (voir `SparkleUpdater`).
    ///
    /// Ne jamais appeler `NSApp.terminate` depuis un bloc de la file principale (`DispatchQueue.main.async`,
    /// `asyncAfter`, `Task` sur le MainActor) : `.terminateLater` fait tourner la boucle d'exécution à l'intérieur
    /// de ce bloc, et la file principale, qui n'est pas réentrante, ne livre plus rien. Or la fin de ptzd
    /// (`FoundationProcessLauncher`), celle du gardien de go2rtc (`LaunchdProcessLauncher`) et le délai de sécurité
    /// (`MainScheduler`) passent par elle : l'app attendrait sans fin. « Quitter » passe donc par la boucle d'exécution
    /// (`perform(_:with:afterDelay:inModes:)`), et la réponse aussi.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.quit {
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }
}

/// L'autorisation « Réseau local » de PTZBot, vérifiée au lancement et à chaque ouverture du panneau.
@MainActor
@Observable
final class LocalNetworkState {
    private(set) var denied = false
    @ObservationIgnored private let probe = LocalNetworkProbe()
    @ObservationIgnored private let scheduler: any Scheduler

    init(scheduler: any Scheduler) {
        self.scheduler = scheduler
    }

    func check() {
        probe.check(scheduler: scheduler) { [weak self] denied in
            self?.denied = denied
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// L'alerte de migration (spec ptzd dans l'app § 5.6).
enum MigrationAlert {
    @MainActor
    static func ask() -> Bool {
        let alert = NSAlert()
        alert.messageText = Labels.migrationMessage
        alert.addButton(withTitle: Labels.migrationReplace)
        alert.addButton(withTitle: Labels.migrationLater)
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// La confirmation de « Quitter » quand go2rtc est allumé (spec B3 § 3.3).
enum QuitConfirmation {
    @MainActor
    static func ask() -> Bool {
        let alert = NSAlert()
        alert.messageText = Labels.quitStopsCamera
        alert.addButton(withTitle: Labels.quit)
        alert.addButton(withTitle: AppText.text("Annuler"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum WindowID {
    static let pairing = "pairing"
    static let devices = "devices"
}

extension OpenWindowAction {
    /// Ouvre la fenêtre au premier plan : l'app n'a pas d'icône dans le Dock pour l'y amener.
    @MainActor
    func front(_ id: String) {
        self(id: id)
        NSApp.activate()
    }
}
