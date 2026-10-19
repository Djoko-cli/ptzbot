import NacelleProtocol
import PTZBotKit
import SwiftUI

/// Le panneau sous l'icône (spec app Mac § 8.1, maquette B ; spec B3 § 6.1 : go2rtc et les pastilles).
struct PanelView: View {
    let model: PanelModel
    let talkback: TalkbackModel
    let settings: SettingsModel
    let app: AppController
    let network: LocalNetworkState
    let go2rtc: Go2RTCSupervisor
    let go2rtcMonitor: Go2RTCMonitor
    /// La fenêtre des Réglages : le lien « Installer le SDK… » l'ouvre sur « SDK OBSBOT ».
    let settingsWindow: SettingsWindowController
    @Environment(\.openWindow) private var openWindow

    private var supervisor: ServiceSupervisor {
        app.supervisor
    }

    private var legacy: Bool {
        app.legacy == .kept
    }

    /// Service actif et connexion de confiance établie (spec ptzd dans l'app § 6.1).
    private var active: Bool {
        Labels.controlsEnabled(supervisor.state, connection: model.service, legacy: legacy)
    }

    /// Un ordre de suivi IA est en cours (`control == .taking`).
    private var aiBusy: Bool {
        model.state?.control == .taking
    }

    private var aiNeedsSDK: Bool {
        Labels.aiNeedsSDK(app.sdkStatus, legacy: legacy)
    }

    /// Le lien vers l'onglet « SDK OBSBOT » : pas quand l'état n'est pas encore lu, ni pendant la recompilation.
    private var aiSDKLink: Bool {
        Labels.aiSDKLink(app.sdkStatus, toolsAvailable: app.toolsAvailable ?? true, legacy: legacy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            serviceSection
            cameraSection
            iPhoneSection
            HStack(spacing: 8) {
                Button {
                    model.openPairing()
                    openWindow.front(WindowID.pairing)
                } label: {
                    Text(AppText.text("Appairer un iPhone…")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    openWindow.front(WindowID.devices)
                } label: {
                    Text(AppText.text("Appareils…")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(!active)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            // Panneau ouvert : l'autorisation « Réseau local » a pu changer dans les Réglages, et les outils de
            // développement ont pu être installés.
            network.check()
            Task { await app.panelOpened() }
            // L'état de Talkback (« En lecture ») est relu dès que talkd réécrit son fichier, et chaque seconde en secours, tant
            // que le panneau est ouvert.
            talkback.beginWatching()
            // Les clients de go2rtc et ses alertes, toutes les 2 s, seulement panneau ouvert (spec B3 § 5).
            go2rtcMonitor.beginWatching()
        }
        .onDisappear {
            talkback.endWatching()
            go2rtcMonitor.endWatching()
        }
    }

    // MARK: - En-tête

    private var header: some View {
        HStack {
            Text(verbatim: "PTZBot").font(.headline)
            Spacer()
            Text(Labels.service(supervisor.state, connection: model.service, legacy: legacy))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(active ? Color.green : Color.secondary)
                .background(active ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15), in: Capsule())
        }
    }

    // MARK: - Service

    private var serviceSection: some View {
        PanelSection(Labels.serviceSection) {
            let ptzd = Labels.ptzdIndicator(supervisor.state, connection: model.service, legacy: legacy)
            PanelRow(icon: "server.rack", title: AppText.text("Service ptzd")) {
                HStack(spacing: 8) {
                    StatusDot(tone: ptzd.tone)
                    Toggle(AppText.text("Service ptzd"), isOn: Binding(get: { supervisor.isEnabled }, set: { supervisor.setEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(app.legacy != .none)
                }
            } notes: {
                if let line = ptzd.line {
                    PanelNote(line, color: ptzd.tone.color)
                }
                if Labels.showsLog(supervisor.state, connection: model.service) {
                    Button(AppText.text("Ouvrir le journal de ptzd")) {
                        LogOpener.openPTZDLog()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if let error = app.migrationError {
                    PanelNote(error, color: .red)
                }
                if app.canReplaceLegacy {
                    Button(Labels.replaceLegacy) {
                        Task { await app.offerMigration() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                ForEach(app.migrationProblems + (app.configError.map { [$0] } ?? []), id: \.self) { problem in
                    PanelNote(problem)
                }
                if model.config.isFallback {
                    PanelNote(AppText.text("config.json illisible : port 1985 essayé."))
                }
            }
            Divider()
            go2rtcRow
            Divider()
            // Talkback : le retour audio de la caméra vers les haut-parleurs du Mac. Indépendant de ptzd : l'agent
            // tourne aussi quand PTZBot est fermé, d'où ni grisé avec le service ni arrêté par « Quitter ».
            let talkbackIndicator = Labels.talkbackIndicator(talkback.status)
            PanelRow(icon: "speaker.wave.2", title: AppText.text("Talkback")) {
                HStack(spacing: 8) {
                    StatusDot(tone: talkbackIndicator.tone)
                    Toggle(AppText.text("Talkback"), isOn: Binding(get: { talkback.isEnabled }, set: { talkback.setEnabled($0) }))
                        .labelsHidden()
                        .disabled(talkback.isPreparing || talkback.isBusy)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            } notes: {
                if let line = talkbackIndicator.line {
                    PanelNote(line, color: talkbackIndicator.tone.color)
                }
                if talkback.status == .requiresApproval {
                    Button(Labels.talkbackApproval) {
                        talkback.openSystemSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if let error = talkback.lastError {
                    PanelNote(error, color: .red)
                }
            }
        }
    }

    // MARK: - go2rtc

    /// go2rtc, juste après ptzd (spec B3 § 6.1) : interrupteur, pastille, ligne d'état hors état normal, et le détail
    /// des clients au survol.
    private var go2rtcRow: some View {
        let indicator = Labels.go2rtcIndicator(go2rtc.state, isEnabled: go2rtc.isEnabled, usesCustomFile: go2rtc.usesCustomFile,
                                               health: go2rtcMonitor.health)
        return PanelRow(icon: "video", title: "go2rtc") {
            HStack(spacing: 8) {
                StatusDot(tone: indicator.tone)
                Toggle(isOn: Binding(get: { go2rtc.isEnabled }, set: { go2rtc.setEnabled($0) })) {
                    Text(verbatim: "go2rtc")
                }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        } notes: {
            if let line = indicator.line {
                PanelNote(line, color: indicator.tone.color)
            }
            if go2rtcMonitor.health.coreAudioStuck {
                Button(AppText.text("Copier la commande de réparation")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(CoreAudioDetector.repairCommand, forType: .string)
                }
                .buttonStyle(.link)
                .font(.caption)
            } else if go2rtcMonitor.health.accessDenied {
                Button(AppText.text("Ouvrir les réglages de confidentialité")) {
                    PrivacySettings.openCamera()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if case .failed = go2rtc.state {
                Button(AppText.text("Ouvrir le journal de go2rtc")) {
                    LogOpener.openGo2RTCLog()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .help(Labels.go2rtcHelp(go2rtcMonitor.stream) ?? "")
    }

    // MARK: - Caméra

    private var cameraSection: some View {
        PanelSection(Labels.cameraSection(model.state?.camera)) {
            PanelRow(icon: "eye.slash", title: AppText.text("Vie privée"), subtitle: Labels.privacySubtitle) {
                Toggle(AppText.text("Vie privée"), isOn: Binding(get: { model.state?.privacy ?? false }, set: { model.setPrivacy($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            } notes: {
                // Mode `tilt` : l'objectif est détourné, mais l'image et le micro ne sont pas coupés (spec § 6.5 bis).
                if let note = Labels.privacyNote(model.state?.privacyMode, needsSDK: aiNeedsSDK) {
                    PanelNote(note, color: .orange)
                }
            }
            Divider()
            PanelRow(icon: "person.crop.square", title: AppText.text("Suivi IA")) {
                HStack(spacing: 6) {
                    if aiBusy {
                        // obsbot-ai démarre ou travaille : l'interrupteur attend la fin de l'ordre.
                        ProgressView().controlSize(.small)
                    }
                    Toggle(AppText.text("Suivi IA"), isOn: Binding(get: { model.state?.aiTracking == .on }, set: { model.setAITracking($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(model.state?.privacy != false || aiBusy || aiNeedsSDK)
                }
            } notes: {
                if let note = Labels.aiNote(model.state?.aiTracking, needsSDK: aiNeedsSDK) {
                    PanelNote(note)
                }
                if aiSDKLink {
                    // L'installation du SDK est dans l'onglet « SDK OBSBOT » des Réglages (banc du 13/10).
                    Button(AppText.text("Installer le SDK…")) {
                        settingsWindow.show(tab: .sdk)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        } notes: {
            if let error = model.lastError {
                PanelNote(error, color: .red)
            }
        }
        .disabled(!active)
    }

    // MARK: - iPhone

    private var iPhoneSection: some View {
        let clients = model.iPhoneClients
        return PanelSection(Labels.iPhoneSection(count: clients.count)) {
            if clients.isEmpty {
                PanelRow(icon: "iphone", title: Labels.noIPhone, secondaryTitle: true) {
                    EmptyView()
                }
            }
            ForEach(Array(clients.enumerated()), id: \.element.id) { index, client in
                if index > 0 {
                    Divider()
                }
                let label = Labels.client(client)
                PanelRow(icon: "iphone", title: label.title, subtitle: label.detail) {
                    Button(AppText.text("Expulser"), role: .destructive) {
                        if let deviceID = client.deviceID {
                            model.kick(deviceID)
                        }
                    }
                    .controlSize(.small)
                    .disabled(!active)
                }
            }
        } notes: {
            if app.tailscaleMissing {
                PanelNote(Labels.tailscaleMissing)
            }
            if network.denied {
                PanelNote(Labels.localNetworkDenied, color: .orange)
                Button(AppText.text("Ouvrir les réglages de confidentialité")) {
                    network.openSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    // MARK: - Pied

    /// « Rechercher les mises à jour… » seul sur sa ligne, pour ne pas être tronqué (banc du 08/10), puis
    /// « Réglages… » et « Quitter » (spec distribution § 8) ; « Ouvrir à la connexion » est dans les Réglages.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(Labels.checkForUpdates) {
                settings.checkForUpdates()
            }
            .disabled(!settings.canCheckForUpdates)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button(Labels.settings) {
                    settingsWindow.show()
                }
                Spacer()
                Button(Labels.quit) {
                    // go2rtc allumé : quitter arrête aussi la caméra HomeKit, ce que la confirmation dit (spec B3 § 3.3).
                    guard !app.quitStopsCamera || QuitConfirmation.ask() else { return }
                    // Un appairage ouvert est fermé avant de partir ; l'envoi est asynchrone, d'où le court délai.
                    // La fin de l'app attend ensuite l'arrêt de ptzd et de go2rtc, 16 s au plus (AppDelegate).
                    // Par la boucle d'exécution, jamais depuis un bloc de la file principale : voir
                    // AppDelegate.applicationShouldTerminate.
                    model.closePairing()
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.3, inModes: [.common])
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// Une section du panneau : légende discrète, boîte arrondie, puis ses messages.
private struct PanelSection<Content: View, Notes: View>: View {
    let caption: String
    @ViewBuilder let content: Content
    @ViewBuilder let notes: Notes

    init(_ caption: String, @ViewBuilder content: () -> Content, @ViewBuilder notes: () -> Notes = { EmptyView() }) {
        self.caption = caption
        self.content = content()
        self.notes = notes()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                content
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            notes
        }
    }
}

/// Une ligne de boîte : icône, titre (et sous-titre), commande alignée à droite ; ses messages dessous,
/// sans déranger l'alignement. Le titre est déjà traduit (`String(localized:)` ou `Labels`).
private struct PanelRow<Trailing: View, Notes: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var secondaryTitle = false
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let notes: Notes

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        secondaryTitle: Bool = false,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder notes: () -> Notes = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.secondaryTitle = secondaryTitle
        self.trailing = trailing()
        self.notes = notes()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(secondaryTitle ? .secondary : .primary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            VStack(alignment: .leading, spacing: 2) {
                notes
            }
            .padding(.leading, 26)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// La pastille d'un service : verte à l'état normal, grise, orange ou rouge sinon (spec B3 § 6.1).
struct StatusDot: View {
    let tone: ServiceIndicator.Tone

    var body: some View {
        Circle()
            .fill(tone.color ?? .secondary)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

extension ServiceIndicator.Tone {
    /// La couleur de la pastille et de la ligne d'état ; nil : le gris discret des notes.
    var color: Color? {
        switch self {
        case .normal: .green
        case .neutral: nil
        case .attention: .orange
        case .failure: .red
        }
    }
}

/// Un petit message sous une ligne ou une section, déjà traduit.
private struct PanelNote: View {
    let text: String
    let color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Ouvre le journal de ptzd ou de go2rtc dans Console.
enum LogOpener {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/obsbot-nacelle/ptzd.log")

    @MainActor
    static func openPTZDLog() {
        open(logURL)
    }

    @MainActor
    static func openGo2RTCLog() {
        open(AppPaths.system().go2rtcLog)
    }

    @MainActor
    private static func open(_ url: URL) {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Réglages › Confidentialité et sécurité › Caméra : un refus d'accès s'y corrige (spec B3 § 5).
enum PrivacySettings {
    @MainActor
    static func openCamera() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}
