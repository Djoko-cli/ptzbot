import Foundation
import NacelleProtocol
import Network
import PTZAuth
import PTZCore

/// Serveur WebSocket de ptzd : quelques adresses précises (jamais 0.0.0.0),
/// 4 iPhone authentifiés au plus, et 4 connexions de confiance du Mac à part (spec § 6.1 et § 6.10,
/// spec app Mac § 7.1). L'administration (app Mac) ne passe que par 127.0.0.1 de confiance. Chaque connexion s'authentifie, sauf sur
/// 127.0.0.1 (spec accès local § 6.3). Les connexions anonymes ont leurs propres réserves, bornées
/// en tout et par adresse : un appareil du Wi-Fi ne peut pas occuper les places des clients.
/// Une place n'est jamais gardée par une connexion morte ou anonyme : 10 s pour s'authentifier,
/// connexion en attente, ping toutes les 10 s. Sur le réseau local, tout passe en TLS à clé
/// pré-partagée (spec accès local § 14) : c'est le seul endroit où l'on appaire, dans le TLS ouvert
/// avec le secret du QR (identité `pair-<id>`). L'appairage est refusé (`notLocal`) sur Tailscale et
/// sur 127.0.0.1, et `openPairing` n'est accepté que de 127.0.0.1 de confiance.
@MainActor
public final class WebSocketServer {
    /// Appareils authentifiés (iPhone).
    public nonisolated static let maxClients = 4
    /// Connexions de confiance du Mac (app Mac, ptzd pair, nacelle-ws), à part : elles ne prennent
    /// jamais la place d'un iPhone.
    public nonisolated static let maxTrustedClients = 4
    /// Durée d'une expulsion (spec app Mac § 7.3).
    public static let blockDuration: TimeInterval = 600
    /// Connexions anonymes en attente d'authentification, en tout.
    public nonisolated static let maxPending = 8
    /// Connexions anonymes en attente d'authentification, par adresse distante.
    public nonisolated static let maxPendingPerAddress = 2
    public static let retryDelay: TimeInterval = 5
    /// Une connexion acceptée qui n'est pas authentifiée après ce délai libère sa place.
    public static let authTimeout: TimeInterval = 10
    /// Intervalle des pings envoyés à chaque client prêt.
    public static let pingInterval: TimeInterval = 10
    /// Un client sans pong depuis ce délai libère sa place.
    public static let pongTimeout: TimeInterval = 25
    /// Une connexion déjà authentifiée du même appareil, sondée quand celui-ci s'authentifie
    /// de nouveau, libère sa place si elle ne répond pas à ce délai.
    public static let staleProbeTimeout: TimeInterval = 3
    /// Marque une poignée de main refusée. Network n'envoie alors aucune réponse, garde la
    /// connexion ouverte et la signale même prête (constaté avec le SDK de macOS 27) : on
    /// retrouve la marque dans ses métadonnées pour la fermer nous-mêmes.
    nonisolated static let rejectionMarker = (name: "X-Nacelle-Refus", value: "origin")

    /// Appelé quand l'écoute sur une adresse est prête, avec le port réellement
    /// ouvert (utile quand on demande le port 0).
    public var onReady: ((_ host: String, _ port: UInt16) -> Void)?

    /// Appelé quand l'écoute sur une adresse échoue parce que le port y est déjà pris (EADDRINUSE).
    /// L'écoute est réessayée quand même ; ptzd lancé par PTZBot s'arrête (code 75).
    public var onAddressInUse: ((_ host: String) -> Void)?

    private let hosts: [String]
    private let port: UInt16
    private let controller: PTZController
    private let authority: DeviceAuthority
    private let relay: any WebRTCRelay
    private let scheduler: any Scheduler
    private let log: LogSink
    private let trustLoopback: Bool
    private let localNetwork: Bool
    /// Adresses écoutées comme le réseau local (TLS, seul endroit où l'on appaire) : pour les tests seulement,
    /// le vrai réseau local passant par `LocalNetworkListeners`.
    private let localHosts: Set<String>
    /// Trames voix (spec parler § 5) ; sans destination, elles sont validées puis perdues.
    private let voice: VoiceRelayer
    private var listeners: [String: NWListener] = [:]
    private var localListeners: LocalNetworkListeners?
    /// Échéance de l'appairage en cours.
    private var expiry: (any Cancellable)?
    private var clients: [ClientID: Client] = [:]
    private var nextID: ClientID = 1
    /// Appareils expulsés : fin du blocage et minuterie qui le lève. Perdus au redémarrage de ptzd.
    private var blocks: [String: (until: Date, timer: any Cancellable)] = [:]
    private let now: @Sendable () -> Date

    /// Une place occupée : la connexion, son authentification et ses minuteries, toutes annulées par `drop`.
    private struct Client {
        let connection: NWConnection
        /// Arrivée par une écoute en boucle locale (127.0.0.1, ::1) : authentifiée d'office.
        let trusted: Bool
        /// Adresse distante, pour la réserve des connexions anonymes.
        let address: String
        /// Arrivée par le réseau local (canal TLS) : le seul endroit où `pair` est accepté.
        let local: Bool
        var authenticated = false
        /// L'appareil authentifié ; nil pour une connexion de confiance.
        var device: (id: String, name: String)?
        /// Heure de l'authentification.
        var since: Date?
        /// A demandé l'état d'administration (`adminWatch`).
        var watchesAdmin = false

        var route: ClientRoute {
            trusted ? .mac : local ? .localNetwork : .tailscale
        }
        /// Défi en cours ; consommé par le premier `auth`.
        var nonce: Data?
        var deadline: (any Cancellable)?
        var ping: (any Cancellable)?
        var pongDeadline: (any Cancellable)?
        /// Négociation vidéo en cours ; une nouvelle offre la remplace.
        var negotiation: Task<Void, Never>?

        func cancelTimers() {
            deadline?.cancel()
            ping?.cancel()
            pongDeadline?.cancel()
            negotiation?.cancel()
        }
    }

    /// Trames voix refusées depuis le démarrage (tests).
    var voiceRefusals: VoiceRelayer.Refusals {
        voice.refused
    }

    /// Nombre de places occupées (tests).
    var clientCount: Int {
        clients.count
    }

    /// Les adresses en double ne sont écoutées qu'une fois (config.json peut déjà contenir 127.0.0.1).
    /// `trustLoopback` à faux (tests) impose l'authentification aussi sur 127.0.0.1 ; `localHosts` (tests)
    /// fait écouter ces adresses comme le réseau local.
    public init(
        hosts: [String],
        port: UInt16,
        controller: PTZController,
        authority: DeviceAuthority,
        relay: any WebRTCRelay,
        scheduler: any Scheduler,
        log: @escaping LogSink,
        trustLoopback: Bool = true,
        localNetwork: Bool = false,
        localHosts: Set<String> = [],
        voiceSink: (any VoiceSink)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.hosts = hosts.reduce(into: []) { unique, host in
            if !unique.contains(host) {
                unique.append(host)
            }
        }
        self.port = port
        self.controller = controller
        self.authority = authority
        self.relay = relay
        self.scheduler = scheduler
        self.log = log
        self.trustLoopback = trustLoopback
        self.localNetwork = localNetwork
        self.localHosts = localHosts
        self.now = now
        voice = VoiceRelayer(sink: voiceSink ?? DiscardingVoiceSink(), scheduler: scheduler, now: now, log: log)
        controller.onStateChange = { [weak self] snapshot in
            self?.broadcast(.state(snapshot))
        }
        controller.onClientError = { [weak self] id, code, message in
            self?.send(.error(code: code, message: message), to: id)
        }
    }

    /// Ouvre l'écoute sur chaque adresse. En cas d'échec (adresse Tailscale pas
    /// encore là), réessaie toutes les 5 s pour cette adresse. Puis, si demandé, sur le
    /// réseau local, où chaque connexion doit s'authentifier.
    public func start() {
        for host in hosts.filter({ !localHosts.contains($0) }) {
            listen(on: host)
        }
        for host in localHosts.sorted() {
            listen(on: host)
        }
        if localNetwork {
            let local = LocalNetworkListeners(
                port: port,
                makeParameters: { [unowned self] in self.makeParameters(tls: self.localTLS()) },
                onConnection: { [weak self] connection in self?.accept(connection, trusted: false, local: true) },
                scheduler: scheduler,
                log: log
            )
            localListeners = local
            local.start()
        }
    }

    /// TLS à clé pré-partagée du réseau local : les secrets des appareils appairés et de l'appairage en cours,
    /// et le veto d'un appareil retiré depuis, relu à chaque poignée de main. `devices.json` illisible :
    /// aucun appareil, et une ligne de journal (spec accès local § 9).
    private func localTLS() -> NWProtocolTLS.Options {
        let authority = authority
        let identities: [String]
        do {
            identities = try authority.tlsIdentities()
        } catch {
            log("devices.json illisible : aucun appareil sur le réseau local.")
            identities = []
        }
        return NacelleTLS.server(identities: identities) { authority.tlsKey(for: $0) }
    }

    /// Relance les écoutes du réseau local, pour qu'elles connaissent le secret d'un nouvel appareil.
    private func rebuildLocalListeners() {
        localListeners?.rebuild()
        for host in localHosts {
            listeners.removeValue(forKey: host)?.cancel()
            listen(on: host)
        }
    }

    /// TCP avec keepalive, TLS si donné, et WebSocket, sans adresse locale : chaque écoute ajoute la sienne.
    private func makeParameters(tls: NWProtocolTLS.Options? = nil) -> NWParameters {
        // Keepalive TCP : une connexion morte (iPhone suspendu, réseau coupé) est fermée
        // après environ 25 s au lieu de garder une des 4 places indéfiniment.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        // Un navigateur envoie toujours Origin, nos clients (app iOS, nacelle-ws) jamais :
        // une page web ouverte sur le Mac ou le tailnet ne peut donc pas piloter la caméra.
        webSocket.setClientRequestHandler(.main) { [weak self] _, headers in
            guard headers.contains(where: { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }) else {
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
            MainActor.assumeIsolated { self?.log("Connexion refusée : en-tête Origin (navigateur).") }
            return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: [Self.rejectionMarker])
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }

    private func listen(on host: String) {
        let local = localHosts.contains(host)
        let parameters = makeParameters(tls: local ? localTLS() : nil)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            reportAddressInUse(host, error)
            retryLater(host, after: error)
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(host, state) }
        }
        let trusted = !local && trustLoopback && Self.isLoopback(host)
        // L'écoute Tailscale (ni boucle locale ni réseau local) n'admet que des adresses Tailscale,
        // que WireGuard authentifie (spec accès local § 12) ; l'appairage y est refusé (`notLocal`).
        // Les écoutes en boucle locale en sont dispensées, même sans confiance (`trustLoopback` à
        // faux, tests) : seuls les programmes du Mac y arrivent, et les tests y jouent ce rôle.
        let tailscaleOnly = !local && !Self.isLoopback(host)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection, trusted: trusted, local: local, tailscaleOnly: tailscaleOnly) }
        }
        listeners[host] = listener
        listener.start(queue: .main)
    }

    private func listenerChanged(_ host: String, _ state: NWListener.State) {
        switch state {
        case .ready:
            let actual = listeners[host]?.port?.rawValue ?? port
            log("En écoute sur \(host):\(actual).")
            onReady?(host, actual)
        case let .failed(error), let .waiting(error):
            listeners.removeValue(forKey: host)?.cancel()
            reportAddressInUse(host, error)
            retryLater(host, after: error)
        default:
            break
        }
    }

    private func reportAddressInUse(_ host: String, _ error: any Error) {
        if case .posix(.EADDRINUSE) = error as? NWError {
            onAddressInUse?(host)
        }
    }

    private func retryLater(_ host: String, after error: any Error) {
        log("Écoute sur \(host):\(port) impossible (\(error)). Nouvel essai dans 5 s.")
        scheduler.schedule(after: Self.retryDelay) { [weak self] in
            self?.listen(on: host)
        }
    }

    /// Écoute en boucle locale : seuls les programmes du Mac y arrivent.
    nonisolated static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1"
    }

    /// Adresse Tailscale : 100.64.0.0/10 en IPv4, fd7a:115c:a1e0::/48 en IPv6 (zone `%…` ignorée).
    /// Un texte qui n'est pas une adresse IP n'en est pas une.
    nonisolated static func isTailscaleAddress(_ host: String) -> Bool {
        let address = String(host.prefix { $0 != "%" })
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            return bytes[0] == 100 && bytes[1] & 0xC0 == 64
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            return bytes.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
        }
        return false
    }

    /// Adresse distante d'une connexion : l'hôte, sans le port.
    nonisolated static func address(of endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            return "\(host)"
        }
        return "\(endpoint)"
    }

    /// Décide d'admettre une nouvelle connexion, sans toucher au réseau. `trustedCount` compte les
    /// connexions de confiance, `pendingAddresses` les connexions anonymes en attente (une adresse par
    /// connexion). Une connexion de confiance ne dépend que de sa réserve ; une anonyme que de la sienne.
    /// Les iPhone authentifiés ont la leur, vérifiée à l'authentification.
    nonisolated static func admits(trusted: Bool, address: String, trustedCount: Int, pendingAddresses: [String]) -> Bool {
        if trusted {
            return trustedCount < maxTrustedClients
        }
        return pendingAddresses.count < maxPending
            && pendingAddresses.filter { $0 == address }.count < maxPendingPerAddress
    }

    /// Un identifiant d'appareil reçu d'un client anonyme n'entre dans le journal que s'il est
    /// hexadécimal (32 caractères au plus) : jamais de saut de ligne ni de texte forgé.
    nonisolated static func logID(_ deviceID: String) -> String {
        guard deviceID.count <= 32, deviceID.allSatisfy(\.isHexDigit) else { return "invalide" }
        return String(deviceID.prefix(8))
    }

    /// iPhone authentifiés : ceux qui occupent les `maxClients` places.
    private var deviceCount: Int {
        clients.values.filter { $0.authenticated && !$0.trusted }.count
    }

    /// Connexions de confiance : celles qui occupent les `maxTrustedClients` places.
    private var trustedCount: Int {
        clients.values.filter(\.trusted).count
    }

    private func accept(_ connection: NWConnection, trusted: Bool, local: Bool = false, tailscaleOnly: Bool = false) {
        let address = Self.address(of: connection.endpoint)
        guard !tailscaleOnly || Self.isTailscaleAddress(address) else {
            log("Connexion refusée : adresse hors Tailscale (\(address)).")
            connection.cancel()
            return
        }
        let pending = clients.values.filter { !$0.authenticated && !$0.trusted }.map(\.address)
        guard Self.admits(trusted: trusted, address: address, trustedCount: trustedCount, pendingAddresses: pending) else {
            if trusted {
                log("Connexion refusée : déjà \(Self.maxTrustedClients) clients du Mac.")
            } else {
                log("Connexion refusée : trop de connexions anonymes (\(address)).")
            }
            connection.cancel()
            return
        }
        let id = nextID
        nextID += 1
        var client = Client(connection: connection, trusted: trusted, address: address, local: local)
        client.deadline = scheduler.schedule(after: Self.authTimeout) { [weak self] in
            self?.release(id, reason: "pas authentifié en \(Int(Self.authTimeout)) s (\(address))")
        }
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connectionChanged(id, state) }
        }
        connection.start(queue: .main)
        receive(on: connection, id: id)
    }

    func connectionChanged(_ id: ClientID, _ state: NWConnection.State) {
        switch state {
        case .ready:
            guard let client = clients[id] else { return }
            if wasRejected(id) {
                drop(id)
                return
            }
            armPongDeadline(id)
            schedulePing(id)
            if client.trusted {
                authenticate(id)
            } else {
                let nonce = DeviceAuthority.makeNonce()
                clients[id]?.nonce = nonce
                send(.challenge(nonce: nonce), to: id)
            }
        case let .waiting(error):
            // Chemin réseau perdu (Wi-Fi/4G, Tailscale coupé) : une connexion entrante
            // n'atteint alors pas toujours .failed et garderait sa place.
            release(id, reason: "connexion en attente (\(error))")
        case .failed, .cancelled:
            drop(id)
        default:
            break
        }
    }

    private func wasRejected(_ id: ClientID) -> Bool {
        let metadata = clients[id]?.connection.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
        return metadata?.additionalServerHeaders?.contains { $0 == Self.rejectionMarker } ?? false
    }

    private func receive(on connection: NWConnection, id: ClientID) {
        connection.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self, self.clients[id] != nil else { return }
                if error != nil || context?.isFinal == true {
                    self.drop(id)
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close {
                    self.drop(id)
                    return
                }
                if metadata?.opcode == .text, let content, let text = String(data: content, encoding: .utf8) {
                    self.process(text, from: id)
                } else if metadata?.opcode == .binary {
                    // Le seul message binaire du protocole : la voix (spec parler § 4).
                    self.processVoice(content ?? Data(), from: id)
                }
                self.receive(on: connection, id: id)
            }
        }
    }

    /// Une trame voix : seul un iPhone authentifié par sa clé d'appareil est écouté, ni le client de confiance
    /// 127.0.0.1, ni une connexion en cours d'appairage ou d'authentification.
    private func processVoice(_ frame: Data, from id: ClientID) {
        guard let client = clients[id] else { return }
        if client.authenticated, !client.trusted, let device = client.device {
            voice.receive(frame, from: id, as: .device(id: device.id, name: device.name))
        } else {
            voice.receive(frame, from: id, as: client.trusted ? .trusted : .unauthenticated)
        }
    }

    private func process(_ text: String, from id: ClientID) {
        let message: ClientMessage
        do {
            message = try NacelleCodec.decodeClient(text)
        } catch {
            send(.error(code: .badMessage, message: "Message illisible."), to: id)
            return
        }
        guard let client = clients[id] else { return }
        if Self.isAdministration(message) {
            // L'app Mac seulement (spec app Mac § 6).
            guard client.trusted else {
                log("Client \(id) : administration refusée hors du Mac (\(client.address)).")
                send(.error(code: .notLocal, message: "Administration depuis le Mac seulement."), to: id)
                return
            }
            administer(message, from: id)
            return
        }
        switch message {
        case .openPairing:
            // Seul un programme du Mac (ptzd pair) ouvre un appairage (spec découverte et QR § 7.1).
            guard client.trusted else {
                log("Client \(id) : ouverture d'appairage refusée hors du Mac (\(client.address)).")
                send(.error(code: .notLocal, message: "Ouverture d'appairage depuis le Mac seulement."), to: id)
                return
            }
            openPairing(id)
        case let .pair(pairingID, publicKey, name, proof):
            // Le QR code ne sert que sur le réseau local, dans le canal TLS ouvert avec son secret.
            // Testé avant `authenticated` : le client de confiance (127.0.0.1) est authentifié d'office
            // et doit recevoir `notLocal` (spec découverte et QR § 7.1).
            guard client.local else {
                log("Client \(id) : appairage refusé hors du réseau local (\(client.address)).")
                send(.error(code: .notLocal, message: "Appairage par QR code sur le réseau local seulement."), to: id)
                return
            }
            guard !client.authenticated else {
                send(.error(code: .badMessage, message: "Déjà authentifié."), to: id)
                return
            }
            pair(id, pairingID: pairingID, publicKey: publicKey, name: name, proof: proof)
        case let .auth(deviceID, signature):
            guard !client.authenticated else { return }
            verify(id, deviceID: deviceID, signature: signature)
        case .forgetMe:
            // « Oublier cet appairage » sur l'iPhone : le Mac retire l'appareil aussi.
            guard client.authenticated, !client.trusted, let device = client.device else {
                log("Client \(id) : oubli d'appairage refusé (\(client.address)).")
                send(.error(code: .badMessage, message: "Message réservé à un iPhone appairé."), to: id)
                return
            }
            if !removeDevice(device.id, name: device.name, origin: "l'iPhone", informDevice: false) {
                send(.error(code: .badMessage, message: "Liste des appareils illisible sur le Mac."), to: id)
            }
        case let .webrtcOffer(offerID, sdp):
            guard client.authenticated else {
                send(.error(code: .notAuthenticated, message: "Authentification d'abord."), to: id)
                return
            }
            relayOffer(id, offerID: offerID, sdp: sdp)
        default:
            guard client.authenticated else {
                send(.error(code: .notAuthenticated, message: "Authentification d'abord."), to: id)
                return
            }
            if let failure = controller.handle(message, from: id) {
                send(.error(code: failure.code, message: failure.message), to: id)
            }
        }
    }

    nonisolated static func isAdministration(_ message: ClientMessage) -> Bool {
        switch message {
        case .adminWatch, .revoke, .kick, .unblock, .closePairing, .aiUpdated:
            true
        default:
            false
        }
    }

    // MARK: - Administration (spec app Mac § 7)

    private func administer(_ message: ClientMessage, from id: ClientID) {
        switch message {
        case .adminWatch:
            clients[id]?.watchesAdmin = true
            send(.adminState(adminState()), to: id)
        case let .revoke(deviceID):
            revoke(deviceID, from: id)
        case let .kick(deviceID):
            kick(deviceID, from: id)
        case let .unblock(deviceID):
            unblock(deviceID, from: id)
        case .closePairing:
            closePairing()
        case .aiUpdated:
            // PTZBot a recompilé obsbot-ai : l'utilitaire repart du nouveau programme (spec § 6.5 bis).
            controller.aiUpdated()
        default:
            break
        }
    }

    /// L'appareil appairé de cet identifiant ; sinon, l'erreur est déjà envoyée à `id`.
    private func pairedDevice(_ deviceID: String, for id: ClientID) -> PairedDevice? {
        do {
            guard let device = try authority.devices.device(id: deviceID) else {
                send(.error(code: .badMessage, message: "Appareil inconnu."), to: id)
                return nil
            }
            return device
        } catch {
            send(.error(code: .badMessage, message: "Liste des appareils illisible sur le Mac."), to: id)
            return nil
        }
    }

    /// Retire l'appareil sur demande du Mac.
    private func revoke(_ deviceID: String, from id: ClientID) {
        guard let device = pairedDevice(deviceID, for: id) else { return }
        if !removeDevice(deviceID, name: device.name, origin: "le Mac", informDevice: true) {
            send(.error(code: .badMessage, message: "Liste des appareils illisible sur le Mac."), to: id)
        }
    }

    /// Retire l'appareil de la liste, lève son blocage, coupe tout de suite ses connexions et relance les
    /// écoutes du réseau local. `origin` dit qui l'a demandé, pour le journal. `informDevice` : l'appareil
    /// reçoit `unpaired` avant la coupure (retrait demandé par le Mac) ; sinon, coupure sans message (l'iPhone
    /// a demandé le retrait et attend la fermeture). Renvoie false si la liste n'a pas pu être modifiée ; l'appareil déjà absent n'est pas une erreur.
    private func removeDevice(_ deviceID: String, name: String, origin: String, informDevice: Bool) -> Bool {
        let removed: PairedDevice?
        do {
            removed = try authority.devices.remove(id: deviceID)
        } catch {
            return false
        }
        blocks.removeValue(forKey: deviceID)?.timer.cancel()
        // Déjà retiré (oubli concurrent d'un retrait, révocation en ligne de commande) : rien à journaliser,
        // mais les connexions encore ouvertes sont coupées et l'écran du Mac rafraîchi.
        if removed != nil {
            log("Appareil \(Self.logID(deviceID)) (\(name)) retiré depuis \(origin).")
        }
        for (other, client) in clients where client.device?.id == deviceID {
            if informDevice {
                // Comme l'expulsion : la place est libérée une fois l'envoi parti.
                refuse(other, .unpaired, "Appareil retiré depuis le Mac.", reason: "retiré depuis le Mac")
            } else {
                drop(other)
            }
        }
        rebuildLocalListeners()
        publishAdmin()
        return true
    }

    /// Coupe les connexions de l'appareil et le bloque `blockDuration` ; l'appairage est gardé.
    private func kick(_ deviceID: String, from id: ClientID) {
        guard let device = pairedDevice(deviceID, for: id) else { return }
        let until = now() + Self.blockDuration
        blocks.removeValue(forKey: deviceID)?.timer.cancel()
        let timer = scheduler.schedule(after: Self.blockDuration) { [weak self] in
            self?.blockExpired(deviceID)
        }
        blocks[deviceID] = (until, timer)
        log("Appareil \(Self.logID(deviceID)) (\(device.name)) expulsé jusqu'à \(Self.clock(until)).")
        for (other, client) in clients where client.device?.id == deviceID {
            refuse(other, .blocked, Self.blockedMessage(until), reason: "expulsé depuis le Mac")
        }
        publishAdmin()
    }

    private func unblock(_ deviceID: String, from id: ClientID) {
        guard let device = pairedDevice(deviceID, for: id) else { return }
        if let block = blocks.removeValue(forKey: deviceID) {
            block.timer.cancel()
            log("Appareil \(Self.logID(deviceID)) (\(device.name)) débloqué.")
        }
        publishAdmin()
    }

    private func blockExpired(_ deviceID: String) {
        guard let block = blocks.removeValue(forKey: deviceID) else { return }
        block.timer.cancel()
        publishAdmin()
    }

    private func closePairing() {
        guard let pairingID = authority.pairing.current?.pairingID, authority.pairing.close(pairingID) else { return }
        expiry?.cancel()
        expiry = nil
        log("Appairage \(pairingID) annulé.")
        rebuildLocalListeners()
        publishAdmin()
    }

    nonisolated static func blockedMessage(_ until: Date) -> String {
        "Expulsé par le Mac jusqu'à \(clock(until))."
    }

    /// Heure locale, « HH:mm ».
    nonisolated static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Les adresses de l'invitation : celles du réseau local d'abord, 4 au plus (spec app Mac § 7.4).
    /// Seules les IPv4 locales restent : l'app iPhone rejette tout le QR code sur une autre adresse.
    nonisolated static func invitationHosts(_ hosts: [String]) -> [String] {
        Array(hosts.filter(LocalAddress.isLocalIPv4).prefix(PairingLink.maxHosts))
    }

    /// Les adresses des écoutes réelles du réseau local, filtrées ; `localHosts` (tests seulement, vide en
    /// service) est ajouté tel quel : les tests y mettent « ::1 », qui n'est pas une IPv4 locale.
    private func invitationAddresses() -> [String] {
        let listening = Self.invitationHosts(localListeners?.addresses ?? [])
        return Array((listening + localHosts.sorted()).prefix(PairingLink.maxHosts))
    }

    /// L'état d'administration : appareils, clients authentifiés ou de confiance, appairage en cours.
    func adminState() -> AdminState {
        let devices = ((try? authority.devices.all()) ?? []).map { device in
            AdminDevice(deviceID: device.deviceID, name: device.name, pairedAt: device.pairedAt, blockedUntil: blocks[device.deviceID].flatMap { $0.until > now() ? $0.until : nil })
        }
        let connected = clients.sorted { $0.key < $1.key }.compactMap { id, client -> AdminClient? in
            guard client.authenticated, let since = client.since else { return nil }
            return AdminClient(id: id, deviceID: client.device?.id, name: client.device?.name, route: client.route, address: client.address, since: since)
        }
        let pairing = authority.pairing.current.map { AdminPairing(pairingID: $0.pairingID, expiresAt: $0.expiresAt) }
        return AdminState(devices: devices, clients: connected, pairing: pairing)
    }

    /// Aux connexions qui ont demandé l'état d'administration.
    private func publishAdmin() {
        let watchers = clients.filter(\.value.watchesAdmin).map(\.key)
        guard !watchers.isEmpty else { return }
        let state = adminState()
        for id in watchers {
            send(.adminState(state), to: id)
        }
    }

    /// Ouvre un appairage, l'annonce aux écoutes du réseau local et renvoie de quoi faire le QR code.
    private func openPairing(_ id: ClientID) {
        let opened = authority.pairing.open()
        expiry?.cancel()
        expiry = scheduler.schedule(after: PairingWindow.lifetime) { [weak self] in
            self?.pairingExpired(opened.pairingID)
        }
        log("Appairage ouvert (\(opened.pairingID)), valable \(Int(PairingWindow.lifetime / 60)) min.")
        let invitation = PairingInvitation(
            pairingID: opened.pairingID, secret: opened.secret, expiresAt: opened.expiresAt,
            hosts: invitationAddresses(), port: Int(port)
        )
        send(.pairingOpened(invitation), to: id)
        rebuildLocalListeners()
        publishAdmin()
    }

    private func pairingExpired(_ pairingID: String) {
        expiry = nil
        guard authority.pairing.close(pairingID) else { return }
        log("Appairage \(pairingID) expiré.")
        rebuildLocalListeners()
        publishAdmin()
    }

    /// Preuve du QR code sur le défi de la connexion : une preuve fausse laisse la connexion ouverte.
    private func pair(_ id: ClientID, pairingID: String, publicKey: Data, name: String, proof: Data) {
        guard let nonce = clients[id]?.nonce else { return }
        let wasOpen = authority.pairing.current?.pairingID == pairingID
        switch authority.pair(pairingID: pairingID, publicKey: publicKey, name: name, proof: proof, nonce: nonce) {
        case let .paired(deviceID, lanKey):
            expiry?.cancel()
            expiry = nil
            log("Appareil appairé : \(deviceID.prefix(8)) (\(PairedDevice.cleanName(name))).")
            send(.paired(deviceID: deviceID, lanKey: lanKey), to: id)
            rebuildLocalListeners()
            publishAdmin()
        case .badCode:
            log("Appairage \(Self.logID(pairingID)) : preuve fausse (\(clients[id]?.address ?? "?")).")
            send(.error(code: .badCode, message: "QR code refusé."), to: id)
            if wasOpen, authority.pairing.current == nil {
                rebuildLocalListeners()
                publishAdmin()
            }
        case .closed:
            send(.error(code: .pairingClosed, message: "QR code expiré ou déjà utilisé : relancez l'appairage sur le Mac."), to: id)
        case .invalidKey:
            send(.error(code: .badMessage, message: "Clé publique illisible."), to: id)
        }
    }

    /// Réponse au défi. Le défi ne sert qu'une fois ; un échec ferme la connexion.
    private func verify(_ id: ClientID, deviceID: String, signature: Data) {
        guard let nonce = clients[id]?.nonce else { return }
        clients[id]?.nonce = nil
        switch authority.check(deviceID: deviceID, signature: signature, nonce: nonce) {
        case let .accepted(device):
            // Vérifié après la signature : un inconnu n'apprend rien des expulsions.
            if let block = blocks[deviceID] {
                if block.until <= now() {
                    // Le minuteur du planificateur est en pause pendant la veille du Mac, pas l'heure :
                    // un blocage échu est levé ici sans attendre le minuteur.
                    blockExpired(deviceID)
                } else {
                    refuse(id, .blocked, Self.blockedMessage(block.until), reason: "appareil \(Self.logID(deviceID)) expulsé jusqu'à \(Self.clock(block.until))")
                    return
                }
            }
            // Les 4 places sont aux iPhone authentifiés : un anonyme qui s'authentifie
            // alors qu'elles sont prises est refusé.
            guard deviceCount < Self.maxClients else {
                log("Connexion refusée : déjà \(Self.maxClients) clients.")
                drop(id)
                return
            }
            log("Client \(id) authentifié : \(device.name) (\(Self.logID(deviceID))).")
            clients[id]?.device = (device.deviceID, device.name)
            authenticate(id)
            // Un iPhone arrive : l'utilitaire du suivi IA se prépare (pas pour le Mac, de confiance).
            controller.prewarmAI()
            probeStale(sameDeviceAs: id)
        case .unknownDevice:
            refuse(id, .unpaired, "Appareil inconnu : appairez-le depuis PTZBot sur le Mac.", reason: "appareil inconnu \(Self.logID(deviceID))")
        case .badSignature:
            refuse(id, .authFailed, "Signature refusée.", reason: "signature refusée pour \(Self.logID(deviceID))")
        case .registryUnreadable:
            log("devices.json illisible : aucun appareil accepté.")
            refuse(id, .unpaired, "Liste des appareils illisible sur le Mac.", reason: "devices.json illisible")
        }
    }

    /// Relaie l'offre à go2rtc ; la réponse ou l'erreur porte l'identifiant de l'offre.
    private func relayOffer(_ id: ClientID, offerID: Int, sdp: String) {
        clients[id]?.negotiation?.cancel()
        let relay = relay
        clients[id]?.negotiation = Task { [weak self] in
            let reply: ServerMessage
            do {
                reply = .webrtcAnswer(id: offerID, sdp: try await relay.answer(offer: sdp))
            } catch {
                guard !Task.isCancelled else { return }
                self?.log("Relais vidéo du client \(id) en échec : \(error).")
                reply = .webrtcError(id: offerID, message: "go2rtc ne répond pas.")
            }
            guard !Task.isCancelled else { return }
            self?.send(reply, to: id)
        }
    }

    private func authenticate(_ id: ClientID) {
        clients[id]?.authenticated = true
        clients[id]?.since = now()
        clients[id]?.deadline?.cancel()
        clients[id]?.deadline = nil
        send(.authenticated, to: id)
        send(.state(controller.snapshot), to: id)
        publishAdmin()
        // Ce que le client va afficher est relu sur la caméra (vie privée native, spec § 6.5 bis) ; un changement est
        // diffusé à tous.
        controller.clientConnected()
    }

    /// Le même iPhone s'authentifie de nouveau (Wi-Fi vers 4G) : l'ancienne connexion est peut-être
    /// morte, mais l'iPhone lance aussi plusieurs candidates en course et garde la première, donc
    /// aucune n'est fermée d'office. Chaque autre connexion du même appareil reçoit un ping tout
    /// de suite et `staleProbeTimeout` pour répondre ; le pong rend l'échéance normale.
    private func probeStale(sameDeviceAs id: ClientID) {
        guard let deviceID = clients[id]?.device?.id else { return }
        let others = clients.filter { $0.key != id && $0.value.authenticated && !$0.value.trusted && $0.value.device?.id == deviceID }
        for other in others.keys {
            clients[other]?.ping?.cancel()
            clients[other]?.pongDeadline?.cancel()
            clients[other]?.pongDeadline = scheduler.schedule(after: Self.staleProbeTimeout) { [weak self] in
                self?.release(other, reason: "remplacé par une autre connexion du même appareil, sans réponse")
            }
            ping(other)
        }
    }

    /// Envoie l'erreur, puis libère la place une fois l'envoi parti.
    private func refuse(_ id: ClientID, _ code: ErrorCode, _ message: String, reason: String) {
        guard let connection = clients[id]?.connection, let text = try? NacelleCodec.encode(ServerMessage.error(code: code, message: message)) else { return }
        log("Client \(id) refusé : \(reason) (\(endpoint(id))).")
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "nacelle", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.drop(id) }
        })
    }

    private func endpoint(_ id: ClientID) -> String {
        clients[id].map { "\($0.connection.endpoint)" } ?? "?"
    }

    private func schedulePing(_ id: ClientID) {
        clients[id]?.ping = scheduler.schedule(after: Self.pingInterval) { [weak self] in
            self?.ping(id)
        }
    }

    /// Envoie un ping. Le client y répond seul : URLSessionWebSocketTask le fait tant qu'une
    /// réception est en attente, ce qui est toujours le cas dans l'app iOS et nacelle-ws.
    private func ping(_ id: ClientID) {
        guard let connection = clients[id]?.connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(.main) { [weak self] error in
            guard error == nil else { return }
            MainActor.assumeIsolated { self?.armPongDeadline(id) }
        }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, isComplete: true, completion: sendCompletion(id))
        schedulePing(id)
    }

    /// (Ré)arme l'échéance du pong : à la connexion, puis à chaque pong reçu.
    private func armPongDeadline(_ id: ClientID) {
        guard clients[id] != nil else { return }
        clients[id]?.pongDeadline?.cancel()
        clients[id]?.pongDeadline = scheduler.schedule(after: Self.pongTimeout) { [weak self] in
            self?.release(id, reason: "pas de pong depuis \(Int(Self.pongTimeout)) s")
        }
    }

    /// Libération anormale : une ligne de journal avec la raison, puis `drop`.
    private func release(_ id: ClientID, reason: String) {
        guard clients[id] != nil else { return }
        log("Client \(id) libéré : \(reason).")
        drop(id)
    }

    /// Seul chemin de libération d'une place.
    private func drop(_ id: ClientID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.cancelTimers()
        client.connection.cancel()
        voice.clientGone(id)
        controller.clientDisconnected(id)
        if client.authenticated {
            publishAdmin()
        }
    }

    /// Aux seuls clients authentifiés.
    private func broadcast(_ message: ServerMessage) {
        for (id, client) in clients where client.authenticated {
            send(message, to: id)
        }
    }

    private func send(_ message: ServerMessage, to id: ClientID) {
        guard let connection = clients[id]?.connection, let text = try? NacelleCodec.encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "nacelle", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: sendCompletion(id))
    }

    /// Un envoi qui échoue libère la place (sans effet si elle l'est déjà).
    private func sendCompletion(_ id: ClientID) -> NWConnection.SendCompletion {
        .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated { self?.release(id, reason: "échec d'envoi (\(error))") }
        }
    }
}
