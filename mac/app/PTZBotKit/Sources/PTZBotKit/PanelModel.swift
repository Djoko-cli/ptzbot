import Foundation
import NacelleProtocol
import Observation

/// L'état et les actions du panneau de PTZBot pour Mac (spec app Mac § 8) : une connexion de confiance
/// à ptzd par 127.0.0.1, gardée ouverte, qui demande l'état d'administration et le reçoit en direct.
@MainActor
@Observable
public final class PanelModel {
    public enum Service: Equatable, Sendable {
        /// Première connexion en cours.
        case connecting
        case active
        /// ptzd ne répond pas ; nouvel essai toutes les `retryDelay` secondes.
        case unreachable
    }

    public static let retryDelay: TimeInterval = 2

    public private(set) var service: Service = .connecting
    /// Dernier état de la caméra, nil hors connexion.
    public private(set) var state: StateSnapshot?
    /// Dernier état d'administration, nil hors connexion.
    public private(set) var admin: AdminState?
    /// Dernier refus de ptzd, en clair et dans la langue de l'app (`ErrorTexts`) ; effacé à l'action suivante.
    public private(set) var lastError: String?
    /// La fenêtre « Appairer un iPhone » ouverte, s'il y en a une.
    public private(set) var pairing: PairingSession?
    /// Relu quand l'app crée `config.json` au premier lancement (`reloadConfig`).
    public private(set) var config: PTZDConfig

    @ObservationIgnored private let transport: any AdminTransport
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private var retry: (any Cancellable)?
    @ObservationIgnored private var started = false
    /// `aiUpdated` attend la prochaine connexion à ptzd.
    @ObservationIgnored private var aiUpdatePending = false

    public init(config: PTZDConfig, transport: any AdminTransport, scheduler: any Scheduler) {
        self.config = config
        self.transport = transport
        self.scheduler = scheduler
        transport.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        transport.open(config.url)
    }

    /// Les iPhone connectés : les clients non fiables. La connexion de confiance de l'app elle-même
    /// (127.0.0.1, `route == .mac`) est le côté serveur, pas un client à montrer.
    public var iPhoneClients: [AdminClient] {
        (admin?.clients ?? []).filter { $0.route != .mac }
    }

    /// `config.json` relu (créé au premier lancement) : la prochaine connexion prend son port.
    public func reloadConfig(_ config: PTZDConfig) {
        self.config = config
    }

    // MARK: - Actions

    public func setPrivacy(_ on: Bool) {
        send(.privacy(on: on))
    }

    public func setAITracking(_ on: Bool) {
        send(.aiTracking(on: on))
    }

    public func kick(_ deviceID: String) {
        send(.kick(deviceID: deviceID))
    }

    public func unblock(_ deviceID: String) {
        send(.unblock(deviceID: deviceID))
    }

    public func revoke(_ deviceID: String) {
        send(.revoke(deviceID: deviceID))
    }

    /// PTZBot a recompilé ou réinstallé obsbot-ai : ptzd relance son utilitaire (spec § 6.5 bis). Sans connexion, le
    /// message part dès la prochaine ; il n'efface pas le dernier refus affiché.
    public func aiUpdated() {
        guard service == .active else {
            aiUpdatePending = true
            return
        }
        sendAIUpdated()
    }

    private func sendAIUpdated() {
        aiUpdatePending = false
        if let text = try? NacelleCodec.encode(ClientMessage.aiUpdated) {
            transport.send(text)
        }
    }

    /// Ouvre un appairage : la fenêtre du QR suit `pairing`.
    public func openPairing() {
        let session = pairing ?? PairingSession(knownDevices: knownDevices, scheduler: scheduler)
        session.restart(knownDevices: knownDevices)
        session.onFinished = { [weak self] in
            self?.pairing = nil
        }
        pairing = session
        send(.openPairing)
    }

    /// Fenêtre fermée ou « Annuler » : le secret meurt avec elle (spec app Mac § 8.3).
    public func closePairing() {
        guard let session = pairing else { return }
        session.cancel()
        pairing = nil
        switch session.phase {
        case .waiting, .showing, .noAddress:
            send(.closePairing)
        case .paired, .expired:
            break
        }
    }

    private var knownDevices: [String: Date] {
        var result: [String: Date] = [:]
        for device in admin?.devices ?? [] {
            result[device.deviceID] = device.pairedAt
        }
        return result
    }

    private func send(_ message: ClientMessage) {
        guard service == .active, let text = try? NacelleCodec.encode(message) else { return }
        lastError = nil
        transport.send(text)
    }

    // MARK: - Connexion

    private func handle(_ event: AdminTransportEvent) {
        switch event {
        case .opened:
            break
        case let .message(text):
            guard let message = try? NacelleCodec.decodeServer(text) else { return }
            handle(message)
        case .closed:
            service = .unreachable
            state = nil
            admin = nil
            retry?.cancel()
            retry = scheduler.schedule(after: Self.retryDelay) { [weak self] in
                guard let self else { return }
                retry = nil
                transport.open(config.url)
            }
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .authenticated:
            // Connexion de confiance : authentifiée d'office.
            service = .active
            if let text = try? NacelleCodec.encode(ClientMessage.adminWatch) {
                transport.send(text)
            }
            if aiUpdatePending {
                sendAIUpdated()
            }
        case let .state(snapshot):
            state = snapshot
        case let .adminState(admin):
            self.admin = admin
            pairing?.adminChanged(admin)
        case let .pairingOpened(invitation):
            pairing?.received(invitation)
        case let .error(code, message):
            // Le texte de ptzd est en français : l'app montre le sien, traduit d'après le code.
            lastError = ErrorTexts.text(for: code, message: message)
        case .challenge:
            // 127.0.0.1 n'est pas de confiance (ptzd de test) : l'app ne sait pas s'authentifier.
            lastError = Localization.text("ptzd demande une authentification : cette app ne passe que par 127.0.0.1.")
        case .paired, .webrtcAnswer, .webrtcError:
            break
        }
    }
}
