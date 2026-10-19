import CryptoKit
import Foundation
import NacelleProtocol
import Network
import PTZAuth
import PTZCore
import Synchronization
import Testing
@testable import PTZServer

@MainActor
@Suite("Serveur WebSocket", .serialized, .timeLimit(.minutes(1)))
struct WebSocketServerTests {
    let camera = StubCamera()
    let controller: PTZController
    let ai = StubAI()
    let authority: DeviceAuthority
    /// Clé de l'appareil de test, appairée par `pairTestDevice()`.
    let key = P256.Signing.PrivateKey()

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ptzserver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        authority = DeviceAuthority(directory: directory)
        controller = PTZController(
            camera: camera,
            scheduler: DispatchScheduler(),
            ai: ai,
            store: StubStore(),
            settings: MotionSettings(),
            isObsbotCenterRunning: { false },
            log: { _ in }
        )
    }

    /// Démarre un serveur sur ces adresses (port 0 : choisi par le système) et
    /// renvoie le port ouvert sur chacune.
    private func startServer(
        on hosts: [String] = ["127.0.0.1"],
        scheduler: any Scheduler = DispatchScheduler(),
        log: @escaping LogSink = { _ in },
        trustLoopback: Bool = true,
        relay: any WebRTCRelay = FakeRelay { "v=0 réponse à \($0)" },
        localHosts: Set<String> = [],
        voiceSink: (any VoiceSink)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> (WebSocketServer, [String: UInt16]) {
        let server = WebSocketServer(
            hosts: hosts, port: 0, controller: controller, authority: authority, relay: relay,
            scheduler: scheduler, log: log, trustLoopback: trustLoopback, localHosts: localHosts,
            voiceSink: voiceSink, now: now
        )
        let ports = await withCheckedContinuation { continuation in
            var ready: [String: UInt16] = [:]
            var resumed = false
            // Une écoute relancée (appairage) rappelle onReady : l'attente ne reprend qu'une fois.
            server.onReady = { host, port in
                ready[host] = port
                if !resumed, ready.count == hosts.count {
                    resumed = true
                    continuation.resume(returning: ready)
                }
            }
            server.start()
        }
        return (server, ports)
    }

    private func connect(_ host: String, _ port: UInt16, origin: String? = nil) -> URLSessionWebSocketTask {
        let authority = host.contains(":") ? "[\(host)]" : host
        var request = URLRequest(url: URL(string: "ws://\(authority):\(port)")!)
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return task
    }

    /// Client WebSocket qui ne répond pas aux pings (`autoReplyPing = false`), ou simple
    /// connexion TCP qui n'envoie jamais de poignée de main (`webSocket: false`).
    private func rawClient(_ port: UInt16, webSocket: Bool) -> NWConnection {
        let parameters = NWParameters.tcp
        if webSocket {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = false
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        let endpoint: NWEndpoint = webSocket
            ? .url(URL(string: "ws://127.0.0.1:\(port)")!)
            : .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: .main)
        return connection
    }

    /// Client WebSocket brut (qui ne répond pas aux pings) authentifié comme l'appareil de test :
    /// reçoit le défi, le signe, et ne lit plus rien ensuite.
    private func authenticatedSilentClient(_ port: UInt16) async throws -> NWConnection {
        let connection = rawClient(port, webSocket: true)
        let text: String = try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, _, _, error in
                if let data, let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
        }
        guard case let .challenge(nonce) = try NacelleCodec.decodeServer(text) else {
            Issue.record("défi attendu")
            return connection
        }
        let auth = try NacelleCodec.encode(ClientMessage.auth(deviceID: deviceID, signature: try signature(for: nonce)))
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "test", metadata: [metadata])
        connection.send(content: Data(auth.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        return connection
    }

    /// Attend (5 s au plus) que la condition devienne vraie.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    private var deviceID: String {
        NacelleAuth.deviceID(publicKeyX963: key.publicKey.x963Representation)
    }

    private func pairTestDevice(lanKey: Data? = nil) throws {
        try authority.devices.add(PairedDevice(
            deviceID: deviceID, name: "iPhone de test", publicKey: key.publicKey.x963Representation,
            pairedAt: Date(), lanKey: lanKey
        ))
    }

    /// Ouvre le canal TLS du « réseau local » (::1 dans les tests), reçoit le défi, le signe ;
    /// renvoie le client et la réponse du serveur.
    private func authenticateOverTLS(port: UInt16, lanKey: Data) async throws -> (TLSClient, ServerMessage) {
        let client = TLSClient(host: "::1", port: port, identity: deviceID, key: lanKey)
        try await client.open()
        guard case let .challenge(nonce) = try await client.receive() else {
            Issue.record("défi attendu")
            return (client, .authenticated)
        }
        try client.send(.auth(deviceID: deviceID, signature: try signature(for: nonce)))
        return (client, try await client.receive())
    }

    private func send(_ message: ClientMessage, on task: URLSessionWebSocketTask) async throws {
        try await task.send(.string(try NacelleCodec.encode(message)))
    }

    /// Le défi reçu à l'ouverture.
    private func challenge(_ task: URLSessionWebSocketTask) async throws -> Data {
        guard case let .challenge(nonce) = try await next(task, where: { _ in true }) else {
            Issue.record("défi attendu")
            return Data()
        }
        return nonce
    }

    private func signature(for nonce: Data) throws -> Data {
        try key.signature(for: NacelleAuth.signedPayload(nonce: nonce, deviceID: deviceID)).derRepresentation
    }

    /// Lit les messages jusqu'au premier qui satisfait la condition.
    private func next(_ task: URLSessionWebSocketTask, where matches: (ServerMessage) -> Bool) async throws -> ServerMessage {
        while true {
            guard case let .string(text) = try await task.receive() else { continue }
            let message = try NacelleCodec.decodeServer(text)
            if matches(message) {
                return message
            }
        }
    }

    @Test("127.0.0.1 : authentifié d'office, puis l'état ; move appliqué ; message illisible signalé")
    func roundTrip() async throws {
        let (server, ports) = await startServer()
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        #expect(try await next(task) { _ in true } == .authenticated)
        let second = try await next(task) { _ in true }
        guard case let .state(snapshot) = second else {
            Issue.record("état attendu, reçu \(second)")
            return
        }
        #expect(snapshot.camera == .connected)

        try await task.send(.string(try NacelleCodec.encode(ClientMessage.move(pan: 1, tilt: 0))))
        _ = try await next(task) { if case let .state(s) = $0 { s.moving } else { false } }
        #expect(camera.relativeCommands.first?.panDirection == 1)

        try await task.send(.string("pas du json"))
        let error = try await next(task) { if case .error = $0 { true } else { false } }
        #expect(error == .error(code: .badMessage, message: "Message illisible."))
        withExtendedLifetime(server) {}
    }

    @Test("Deux adresses, un seul contrôleur : l'état est diffusé aux clients des deux")
    func twoHosts() async throws {
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"])
        let first = connect("127.0.0.1", ports["127.0.0.1"]!)
        let second = connect("::1", ports["::1"]!)
        defer { [first, second].forEach { $0.cancel(with: .goingAway, reason: nil) } }
        _ = try await next(first) { _ in true }
        _ = try await next(second) { _ in true }

        try await first.send(.string(try NacelleCodec.encode(ClientMessage.move(pan: 1, tilt: 0))))
        let seen = try await next(second) { if case let .state(s) = $0 { s.moving } else { false } }
        guard case let .state(snapshot) = seen else { return }
        #expect(snapshot.moving)
        withExtendedLifetime(server) {}
    }

    @Test("Une adresse en double n'est écoutée qu'une fois")
    func duplicateHosts() async throws {
        let server = WebSocketServer(
            hosts: ["127.0.0.1", "127.0.0.1"], port: 0, controller: controller, authority: authority,
            relay: FakeRelay { $0 }, scheduler: DispatchScheduler(), log: { _ in }
        )
        var readyCount = 0
        server.onReady = { _, _ in readyCount += 1 }
        server.start()
        try await Task.sleep(for: .milliseconds(500))
        #expect(readyCount == 1)
        withExtendedLifetime(server) {}
    }

    @Test("Port de 127.0.0.1 déjà pris (EADDRINUSE) : signalé par onAddressInUse")
    func addressInUse() async throws {
        // Un socket ordinaire, sans SO_REUSEPORT, tient un port choisi par le système (port 0).
        let holder = socket(AF_INET, SOCK_STREAM, 0)
        try #require(holder >= 0)
        defer { close(holder) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(holder, pointer, length) == 0 && listen(holder, 1) == 0 && getsockname(holder, pointer, &length) == 0
            }
        }
        try #require(bound)
        let port = UInt16(bigEndian: address.sin_port)
        let server = WebSocketServer(
            hosts: ["127.0.0.1"], port: port, controller: controller, authority: authority,
            relay: FakeRelay { $0 }, scheduler: DispatchScheduler(), log: { _ in }
        )
        var inUse: [String] = []
        server.onAddressInUse = { inUse.append($0) }
        server.start()
        try await waitUntil { !inUse.isEmpty }
        #expect(inUse.first == "127.0.0.1")
        withExtendedLifetime(server) {}
    }

    @Test("Au-delà de 4 clients, la connexion est refusée")
    func maxClients() async throws {
        let (server, ports) = await startServer()
        let port = ports["127.0.0.1"]!
        var tasks: [URLSessionWebSocketTask] = []
        for _ in 0..<WebSocketServer.maxClients {
            let task = connect("127.0.0.1", port)
            _ = try await next(task) { _ in true }
            tasks.append(task)
        }
        let extra = connect("127.0.0.1", port)
        await #expect(throws: (any Error).self) {
            _ = try await extra.receive()
        }
        (tasks + [extra]).forEach { $0.cancel(with: .goingAway, reason: nil) }
        withExtendedLifetime(server) {}
    }

    @Test("Poignée de main avec en-tête Origin (navigateur) : refusée, journalisée, place libérée")
    func browserOriginRejected() async throws {
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) })
        let port = ports["127.0.0.1"]!
        let browser = connect("127.0.0.1", port, origin: "https://exemple.invalid")
        await #expect(throws: (any Error).self) {
            _ = try await browser.receive()
        }
        #expect(lines.values.contains("Connexion refusée : en-tête Origin (navigateur)."))
        // La connexion refusée est fermée côté serveur : les 4 places restent libres
        // pour les clients sans Origin (app iOS, nacelle-ws).
        var clients: [URLSessionWebSocketTask] = []
        for _ in 0..<WebSocketServer.maxClients {
            let task = connect("127.0.0.1", port)
            _ = try await next(task) { _ in true }
            clients.append(task)
        }
        (clients + [browser]).forEach { $0.cancel(with: .goingAway, reason: nil) }
        withExtendedLifetime(server) {}
    }

    @Test("Connexion jamais prête : place libérée 10 s après l'acceptation, avec une ligne de journal")
    func handshakeTimeout() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) })
        let client = rawClient(ports["127.0.0.1"]!, webSocket: false)
        defer { client.cancel() }
        try await waitUntil { server.clientCount == 1 }

        scheduler.advance(by: WebSocketServer.authTimeout - 0.1)
        #expect(server.clientCount == 1)
        scheduler.advance(by: 0.1)
        #expect(server.clientCount == 0)
        #expect(lines.values.contains("Client 1 libéré : pas authentifié en 10 s (127.0.0.1)."))
    }

    @Test("Sans 127.0.0.1 de confiance : défi d'abord, rien d'autre avant l'authentification")
    func challengeFirst() async throws {
        let (server, ports) = await startServer(trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        #expect(try await challenge(task).count == NacelleAuth.nonceLength)
        try await send(.move(pan: 1, tilt: 0), on: task)
        #expect(try await next(task) { _ in true } == .error(code: .notAuthenticated, message: "Authentification d'abord."))
        #expect(camera.relativeCommands.isEmpty)
        withExtendedLifetime(server) {}
    }

    @Test("Signature juste : authenticated, puis l'état ; les commandes passent")
    func validAuth() async throws {
        try pairTestDevice()
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let nonce = try await challenge(task)
        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
        #expect(try await next(task) { _ in true } == .authenticated)
        guard case .state = try await next(task, where: { _ in true }) else {
            Issue.record("état attendu")
            return
        }
        try await send(.move(pan: 1, tilt: 0), on: task)
        _ = try await next(task) { if case let .state(s) = $0 { s.moving } else { false } }
        #expect(lines.values.contains("Client 1 authentifié : iPhone de test (\(deviceID.prefix(8)))."))
        withExtendedLifetime(server) {}
    }

    @Test("Appareil inconnu : unpaired, puis fermeture et place libérée")
    func unknownDevice() async throws {
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let nonce = try await challenge(task)
        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
        #expect(try await next(task) { _ in true } == .error(code: .unpaired, message: "Appareil inconnu : appairez-le depuis PTZBot sur le Mac."))
        try await waitUntil { server.clientCount == 0 }
        #expect(lines.values.contains { $0.hasPrefix("Client 1 refusé : appareil inconnu \(deviceID.prefix(8))") })
    }

    @Test("Signature d'un autre défi (rejeu) : authFailed, puis fermeture")
    func replayedSignature() async throws {
        try pairTestDevice()
        let (server, ports) = await startServer(trustLoopback: false)
        let first = connect("127.0.0.1", ports["127.0.0.1"]!)
        let second = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { [first, second].forEach { $0.cancel(with: .goingAway, reason: nil) } }

        let firstNonce = try await challenge(first)
        _ = try await challenge(second)
        try await send(.auth(deviceID: deviceID, signature: try signature(for: firstNonce)), on: second)
        #expect(try await next(second) { _ in true } == .error(code: .authFailed, message: "Signature refusée."))
        try await waitUntil { server.clientCount == 1 }
    }

    @Test("Défi sans réponse : place libérée 10 s après l'acceptation")
    func authTimeout() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) }, trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await challenge(task)

        scheduler.advance(by: WebSocketServer.authTimeout)
        #expect(server.clientCount == 0)
        #expect(lines.values.contains("Client 1 libéré : pas authentifié en 10 s (127.0.0.1)."))
    }

    /// Ouvre un appairage depuis 127.0.0.1 de confiance (comme `ptzd pair`) et renvoie l'invitation.
    private func openPairing(port: UInt16) async throws -> (URLSessionWebSocketTask, PairingInvitation?) {
        let task = connect("127.0.0.1", port)
        try await send(.openPairing, on: task)
        let reply = try await next(task) { message in
            if case .pairingOpened = message { true } else { false }
        }
        guard case let .pairingOpened(invitation) = reply else { return (task, nil) }
        return (task, invitation)
    }

    /// Preuve du QR code pour la clé de test sur ce défi.
    private func proof(secret: Data, nonce: Data) -> Data {
        NacelleAuth.pairingProof(secret: secret, nonce: nonce, publicKeyX963: key.publicKey.x963Representation)
    }

    @Test("openPairing depuis 127.0.0.1 de confiance : invitation (identifiant, secret, 5 min, adresses locales), journalisée")
    func openPairingFromMac() async throws {
        let lines = LineBox()
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], log: { lines.values.append($0) }, localHosts: ["::1"])
        let (task, invitation) = try await openPairing(port: ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        let opened = try #require(invitation)
        #expect(authority.pairing.current?.pairingID == opened.pairingID)
        #expect(authority.pairing.current?.secret == opened.secret)
        #expect(opened.hosts == ["::1"])
        #expect(abs(opened.expiresAt.timeIntervalSinceNow - PairingWindow.lifetime) < 5)
        #expect(lines.values.contains("Appairage ouvert (\(opened.pairingID)), valable 5 min."))
        withExtendedLifetime(server) {}
    }

    @Test("openPairing sans la confiance de 127.0.0.1 : notLocal, aucun appairage ouvert")
    func openPairingRefused() async throws {
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await challenge(task)
        try await send(.openPairing, on: task)
        #expect(try await next(task) { _ in true } == .error(code: .notLocal, message: "Ouverture d'appairage depuis le Mac seulement."))
        #expect(authority.pairing.current == nil)
        #expect(lines.values.contains("Client 1 : ouverture d'appairage refusée hors du Mac (127.0.0.1)."))
        withExtendedLifetime(server) {}
    }

    @Test("Appairage depuis 127.0.0.1 de confiance : notLocal, journalisé, aucun essai décompté")
    func pairFromTrustedLoopbackRefused() async throws {
        let opened = authority.pairing.open()
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) })
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        // Le client de confiance ne reçoit pas de défi : une preuve quelconque suffit.
        let pair = ClientMessage.pair(
            pairingID: opened.pairingID, publicKey: key.publicKey.x963Representation, name: "iPhone",
            proof: Data(count: 32)
        )
        try await send(pair, on: task)
        let reply = try await next(task) { if case .error = $0 { true } else { false } }
        #expect(reply == .error(code: .notLocal, message: "Appairage par QR code sur le réseau local seulement."))
        #expect(authority.pairing.current?.pairingID == opened.pairingID)
        #expect(lines.values.contains("Client 1 : appairage refusé hors du réseau local (127.0.0.1)."))
        withExtendedLifetime(server) {}
    }

    @Test("Appairage hors du réseau local (Tailscale) : notLocal, même avec la bonne preuve")
    func pairOnlyOnLocalNetwork() async throws {
        let opened = authority.pairing.open()
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        let nonce = try await challenge(task)
        let pair = ClientMessage.pair(
            pairingID: opened.pairingID, publicKey: key.publicKey.x963Representation, name: "iPhone",
            proof: proof(secret: opened.secret, nonce: nonce)
        )
        try await send(pair, on: task)
        #expect(try await next(task) { _ in true } == .error(code: .notLocal, message: "Appairage par QR code sur le réseau local seulement."))
        #expect(authority.pairing.current?.pairingID == opened.pairingID)
        #expect(lines.values.contains("Client 1 : appairage refusé hors du réseau local (127.0.0.1)."))
        withExtendedLifetime(server) {}
    }

    @Test("Offre WebRTC relayée : réponse avec le même identifiant")
    func relayAnswer() async throws {
        let (server, ports) = await startServer()
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await next(task) { if case .state = $0 { true } else { false } }

        try await send(.webrtcOffer(id: 7, sdp: "offre"), on: task)
        #expect(try await next(task) { if case .webrtcAnswer = $0 { true } else { false } } == .webrtcAnswer(id: 7, sdp: "v=0 réponse à offre"))
        withExtendedLifetime(server) {}
    }

    @Test("go2rtc en échec : webrtcError avec le même identifiant, journalisé")
    func relayError() async throws {
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, relay: FakeRelay { _ in throw RelayError.badResponse(status: 500) })
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await next(task) { if case .state = $0 { true } else { false } }

        try await send(.webrtcOffer(id: 2, sdp: "offre"), on: task)
        #expect(try await next(task) { if case .webrtcError = $0 { true } else { false } } == .webrtcError(id: 2, message: "go2rtc ne répond pas."))
        #expect(lines.values.contains { $0.hasPrefix("Relais vidéo du client 1 en échec") })
        withExtendedLifetime(server) {}
    }

    @Test("Offre avant l'authentification : refusée, go2rtc pas appelé")
    func relayRequiresAuth() async throws {
        let calls = CallCounter()
        let (server, ports) = await startServer(trustLoopback: false, relay: FakeRelay { calls.increment(); return $0 })
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await challenge(task)

        try await send(.webrtcOffer(id: 1, sdp: "offre"), on: task)
        #expect(try await next(task) { _ in true } == .error(code: .notAuthenticated, message: "Authentification d'abord."))
        #expect(calls.value == 0)
        withExtendedLifetime(server) {}
    }

    @Test("Une nouvelle offre remplace la précédente : seule la dernière reçoit sa réponse")
    func newOfferReplaces() async throws {
        let relay = FakeRelay { offer in
            if offer == "lente" {
                try await Task.sleep(for: .seconds(1))
            }
            return "v=0 \(offer)"
        }
        let (server, ports) = await startServer(relay: relay)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await next(task) { if case .state = $0 { true } else { false } }

        try await send(.webrtcOffer(id: 1, sdp: "lente"), on: task)
        try await send(.webrtcOffer(id: 2, sdp: "rapide"), on: task)
        #expect(try await next(task) { if case .webrtcAnswer = $0 { true } else { false } } == .webrtcAnswer(id: 2, sdp: "v=0 rapide"))
        try await Task.sleep(for: .milliseconds(1500))
        try await task.send(.string("pas du json"))
        // Après 1,5 s, le message suivant est l'erreur de lecture : la réponse à l'offre 1 n'est jamais partie.
        let following = try await next(task) { if case .state = $0 { false } else { true } }
        #expect(following == .error(code: .badMessage, message: "Message illisible."))
        withExtendedLifetime(server) {}
    }

    @Test("Réseau local : appareil appairé en TLS avec son secret, puis défi et authentification")
    func localTLS() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], trustLoopback: false, localHosts: ["::1"])
        let (client, reply) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        defer { client.close() }
        #expect(reply == .authenticated)
        withExtendedLifetime(server) {}
    }

    @Test("Réseau local : sans TLS, ou avec une mauvaise clé, aucun canal")
    func localRequiresTLS() async throws {
        try pairTestDevice(lanKey: NacelleTLS.makeKey())
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], trustLoopback: false, localHosts: ["::1"])
        let wrong = TLSClient(host: "::1", port: ports["::1"]!, identity: deviceID, key: NacelleTLS.makeKey())
        await #expect(throws: TLSClientError.noChannel) { try await wrong.open() }
        wrong.close()
        let plain = connect("::1", ports["::1"]!)
        defer { plain.cancel(with: .goingAway, reason: nil) }
        await #expect(throws: (any Error).self) { _ = try await plain.receive() }
        withExtendedLifetime(server) {}
    }

    @Test("Réseau local : devices.json illisible au montage de l'écoute TLS, journalisé")
    func unreadableRegistryOnLocalNetwork() async throws {
        try Data("pas du json".utf8).write(to: authority.devices.url)
        let lines = LineBox()
        let (server, _) = await startServer(on: ["127.0.0.1", "::1"], log: { lines.values.append($0) }, trustLoopback: false, localHosts: ["::1"])
        #expect(lines.values.contains("devices.json illisible : aucun appareil sur le réseau local."))
        withExtendedLifetime(server) {}
    }

    @Test("QR code sur le réseau local : preuve fausse (connexion gardée), bonne preuve, auth sur le même défi, écoute relancée")
    func qrPairing() async throws {
        let opened = authority.pairing.open()
        let lines = LineBox()
        let (server, ports) = await startServer(
            on: ["127.0.0.1", "::1"], log: { lines.values.append($0) }, trustLoopback: false, localHosts: ["::1"]
        )
        let rebuilt = PortBox()
        server.onReady = { host, port in
            if host == "::1" {
                rebuilt.port = port
            }
        }
        let client = TLSClient(host: "::1", port: ports["::1"]!, identity: NacelleTLS.pairingIdentity(opened.pairingID), key: opened.secret)
        defer { client.close() }
        try await client.open()
        guard case let .challenge(nonce) = try await client.receive() else {
            Issue.record("défi attendu")
            return
        }
        let publicKey = key.publicKey.x963Representation

        try client.send(.pair(pairingID: opened.pairingID, publicKey: publicKey, name: "iPhone\n", proof: proof(secret: NacelleTLS.makeKey(), nonce: nonce)))
        #expect(try await client.receive() == .error(code: .badCode, message: "QR code refusé."))
        #expect(lines.values.contains("Appairage \(opened.pairingID) : preuve fausse (::1)."))
        try client.send(.pair(pairingID: opened.pairingID, publicKey: publicKey, name: "iPhone\n", proof: proof(secret: opened.secret, nonce: nonce)))
        guard case let .paired(pairedID, lanKey) = try await client.receive() else {
            Issue.record("paired attendu")
            return
        }
        #expect(pairedID == deviceID)
        #expect(lanKey.count == NacelleTLS.keyLength)
        #expect(authority.lanKey(for: deviceID) == lanKey)
        #expect(authority.pairing.current == nil)
        #expect(lines.values.contains("Appareil appairé : \(deviceID.prefix(8)) (iPhone)."))
        try client.send(.auth(deviceID: deviceID, signature: try signature(for: nonce)))
        #expect(try await client.receive() == .authenticated)

        try await waitUntil { rebuilt.port != nil }
        let (again, reply) = try await authenticateOverTLS(port: rebuilt.port!, lanKey: lanKey)
        defer { again.close() }
        #expect(reply == .authenticated)
        let reused = TLSClient(host: "::1", port: rebuilt.port!, identity: NacelleTLS.pairingIdentity(opened.pairingID), key: opened.secret)
        defer { reused.close() }
        await #expect(throws: TLSClientError.noChannel) { try await reused.open() }
    }

    @Test("Réseau local, appairage déjà utilisé ou inconnu : pairingClosed")
    func pairingClosedOnLocalNetwork() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], trustLoopback: false, localHosts: ["::1"])
        let client = TLSClient(host: "::1", port: ports["::1"]!, identity: deviceID, key: lanKey)
        defer { client.close() }
        try await client.open()
        _ = try await client.receive()
        try client.send(.pair(pairingID: "1a2b3c4d", publicKey: key.publicKey.x963Representation, name: "iPhone", proof: Data(count: 32)))
        #expect(try await client.receive() == .error(code: .pairingClosed, message: "QR code expiré ou déjà utilisé : relancez l'appairage sur le Mac."))
        withExtendedLifetime(server) {}
    }

    @Test("Appairage ouvert : expiré au bout de 5 min, journalisé, écoute locale relancée")
    func pairingExpiry() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(
            on: ["127.0.0.1", "::1"], scheduler: scheduler, log: { lines.values.append($0) }, localHosts: ["::1"]
        )
        let rebuilt = PortBox()
        server.onReady = { host, port in
            if host == "::1" {
                rebuilt.port = port
            }
        }
        let (task, invitation) = try await openPairing(port: ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        let opened = try #require(invitation)
        try await waitUntil { rebuilt.port != nil }
        rebuilt.port = nil
        scheduler.advance(by: PairingWindow.lifetime - 1)
        #expect(authority.pairing.current?.pairingID == opened.pairingID)
        scheduler.advance(by: 1)
        #expect(authority.pairing.current == nil)
        #expect(lines.values.contains("Appairage \(opened.pairingID) expiré."))
        try await waitUntil { rebuilt.port != nil }
    }

    @Test("ptzd pair : QR code et URL de l'appairage ouvert par 127.0.0.1")
    func pairCommand() async throws {
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], localHosts: ["::1"])
        let result = await PairCommand.run(port: Int(ports["127.0.0.1"]!))
        let current = try #require(authority.pairing.current)
        let link = PairingLink(pairingID: current.pairingID, secret: current.secret, hosts: ["::1"], port: 0)
        #expect(result.status == 0)
        #expect(result.output.contains("\u{1B}[30;107m"))
        #expect(result.output.contains(link.url.absoluteString))
        #expect(result.output.contains("Dans PTZBot sur l'iPhone, touchez « Scanner le QR code » et visez ce code."))
        withExtendedLifetime(server) {}
    }

    @Test("ptzd pair : refus du service affiché, sans adresse locale, ou service absent : code 1")
    func pairCommandFailures() async throws {
        let (untrusted, refusing) = await startServer(trustLoopback: false)
        let refused = await PairCommand.run(port: Int(refusing["127.0.0.1"]!))
        #expect(refused.status == 1)
        #expect(refused.output == "ptzd refuse l'appairage : Ouverture d'appairage depuis le Mac seulement.")
        withExtendedLifetime(untrusted) {}

        let (lonely, ports) = await startServer()
        let noAddress = await PairCommand.run(port: Int(ports["127.0.0.1"]!))
        #expect(noAddress.status == 1)
        #expect(noAddress.output == "Aucune adresse sur le réseau local : reliez le Mac au Wi-Fi ou à l'Ethernet, puis relancez ptzd pair.")
        withExtendedLifetime(lonely) {}

        let absent = await PairCommand.run(port: 1, timeout: 2)
        #expect(absent == (1, "ptzd ne répond pas : le service est-il lancé ?"))
    }


    // MARK: - Administration (spec app Mac)

    /// Connexion de confiance qui demande l'état d'administration ; renvoie la connexion et le premier état.
    private func watchAdmin(_ port: UInt16) async throws -> (URLSessionWebSocketTask, AdminState) {
        let task = connect("127.0.0.1", port)
        try await send(.adminWatch, on: task)
        return (task, try await nextAdmin(task))
    }

    private func nextAdmin(_ task: URLSessionWebSocketTask) async throws -> AdminState {
        guard case let .adminState(state) = try await next(task, where: { if case .adminState = $0 { true } else { false } }) else {
            return AdminState(devices: [], clients: [], pairing: nil)
        }
        return state
    }

    @Test("Administration hors de 127.0.0.1 de confiance : notLocal, journalisé, rien d'autre", arguments: [
        ClientMessage.adminWatch, .revoke(deviceID: "00"), .kick(deviceID: "00"), .unblock(deviceID: "00"), .closePairing,
        .aiUpdated,
    ])
    func administrationRefused(_ message: ClientMessage) async throws {
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await challenge(task)
        try await send(message, on: task)
        #expect(try await next(task) { _ in true } == .error(code: .notLocal, message: "Administration depuis le Mac seulement."))
        #expect(lines.values.contains("Client 1 : administration refusée hors du Mac (127.0.0.1)."))
        withExtendedLifetime(server) {}
    }

    @Test("adminWatch : l'état tout de suite, puis à l'arrivée et au départ d'un iPhone")
    func adminStateFollowsClients() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], localHosts: ["::1"])
        let (admin, first) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        #expect(first.devices.map(\.deviceID) == [deviceID])
        #expect(first.devices.first?.name == "iPhone de test")
        #expect(first.clients.map(\.route) == [.mac])
        #expect(first.clients.first?.deviceID == nil)
        #expect(first.pairing == nil)

        let (iPhone, reply) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        #expect(reply == .authenticated)
        let joined = try await nextAdmin(admin)
        let client = try #require(joined.clients.first { $0.deviceID == deviceID })
        #expect(client.route == .localNetwork)
        #expect(client.name == "iPhone de test")
        #expect(client.address == "::1")

        iPhone.close()
        let left = try await nextAdmin(admin)
        #expect(!left.clients.contains { $0.deviceID == deviceID })
        withExtendedLifetime(server) {}
    }

    @Test("Expulser : blocked envoyé et connexion fermée ; refusé après signature pendant 10 min ; réaccepté à l'échéance")
    func kickBlocksForTenMinutes() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], scheduler: scheduler, log: { lines.values.append($0) }, localHosts: ["::1"])
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        let (iPhone, reply) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        #expect(reply == .authenticated)
        _ = try await nextAdmin(admin)

        try await send(.kick(deviceID: deviceID), on: admin)
        let kicked = try await iPhone.receive(where: { if case .error = $0 { true } else { false } })
        guard case let .error(code, message) = kicked else {
            Issue.record("blocked attendu")
            return
        }
        #expect(code == .blocked)
        #expect(message.hasPrefix("Expulsé par le Mac jusqu'à "))
        let blocked = try await nextAdmin(admin)
        #expect(blocked.devices.first?.blockedUntil != nil)
        #expect(lines.values.contains { $0.hasPrefix("Appareil \(deviceID.prefix(8)) (iPhone de test) expulsé jusqu'à ") })

        let (again, refused) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        defer { again.close() }
        guard case .error(.blocked, _) = refused else {
            Issue.record("blocked attendu à la reconnexion")
            return
        }

        scheduler.advance(by: WebSocketServer.blockDuration)
        let (back, accepted) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        defer { back.close() }
        #expect(accepted == .authenticated)
        withExtendedLifetime(server) {}
    }

    @Test("Blocage échu pendant la veille : le minuteur est en pause, l'heure non ; accepté et plus de blockedUntil")
    func expiredBlockLiftedWithoutTimer() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let clock = TestClock()
        let (server, ports) = await startServer(
            on: ["127.0.0.1", "::1"], scheduler: FakeScheduler(), localHosts: ["::1"], now: { clock.date }
        )
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        try await send(.kick(deviceID: deviceID), on: admin)
        #expect(try await nextAdmin(admin).devices.first?.blockedUntil != nil)

        // L'heure avance de plus de 600 s sans que le planificateur ne tire (veille du Mac).
        clock.advance(by: WebSocketServer.blockDuration + 1)
        let (iPhone, reply) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        defer { iPhone.close() }
        #expect(reply == .authenticated)
        #expect(try await nextAdmin(admin).devices.first?.blockedUntil == nil)
        withExtendedLifetime(server) {}
    }

    @Test("État d'administration : blockedUntil seulement pour un blocage encore en cours")
    func adminStateHidesExpiredBlock() async throws {
        try pairTestDevice()
        let clock = TestClock()
        let (server, ports) = await startServer(scheduler: FakeScheduler(), now: { clock.date })
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        try await send(.kick(deviceID: deviceID), on: admin)
        #expect(try await nextAdmin(admin).devices.first?.blockedUntil != nil)
        clock.advance(by: WebSocketServer.blockDuration + 1)
        #expect(server.adminState().devices.first?.blockedUntil == nil)
        withExtendedLifetime(server) {}
    }

    @Test("Expulsé puis reconnecté avec une mauvaise signature : authFailed, pas blocked")
    func kickedBadSignatureIsAuthFailed() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], scheduler: FakeScheduler(), localHosts: ["::1"])
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        try await send(.kick(deviceID: deviceID), on: admin)
        #expect(try await nextAdmin(admin).devices.first?.blockedUntil != nil)

        let client = TLSClient(host: "::1", port: ports["::1"]!, identity: deviceID, key: lanKey)
        try await client.open()
        defer { client.close() }
        guard case let .challenge(nonce) = try await client.receive() else {
            Issue.record("défi attendu")
            return
        }
        let other = P256.Signing.PrivateKey()
        let forged = try other.signature(for: NacelleAuth.signedPayload(nonce: nonce, deviceID: deviceID)).derRepresentation
        try client.send(.auth(deviceID: deviceID, signature: forged))
        guard case .error(.authFailed, _) = try await client.receive() else {
            Issue.record("authFailed attendu, pas blocked")
            return
        }
        withExtendedLifetime(server) {}
    }

    @Test("Client authentifié mais pas de confiance (réseau local) : l'administration est refusée, notLocal")
    func authenticatedUntrustedClientCannotAdminister() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], trustLoopback: false, localHosts: ["::1"])
        let (iPhone, reply) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        defer { iPhone.close() }
        #expect(reply == .authenticated)
        try iPhone.send(.kick(deviceID: deviceID))
        let refused = try await iPhone.receive(where: { if case .error = $0 { true } else { false } })
        #expect(refused == .error(code: .notLocal, message: "Administration depuis le Mac seulement."))
        withExtendedLifetime(server) {}
    }

    @Test("Débloquer : réaccepté tout de suite, journalisé")
    func unblock() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let lines = LineBox()
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], scheduler: FakeScheduler(), log: { lines.values.append($0) }, localHosts: ["::1"])
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        try await send(.kick(deviceID: deviceID), on: admin)
        #expect(try await nextAdmin(admin).devices.first?.blockedUntil != nil)
        try await send(.unblock(deviceID: deviceID), on: admin)
        #expect(try await nextAdmin(admin).devices.first?.blockedUntil == nil)
        #expect(lines.values.contains("Appareil \(deviceID.prefix(8)) (iPhone de test) débloqué."))
        let (iPhone, reply) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        defer { iPhone.close() }
        #expect(reply == .authenticated)
        withExtendedLifetime(server) {}
    }

    @Test("Retirer depuis le Mac : appareil retiré, unpaired envoyé à l'iPhone connecté puis connexion coupée, journalisé")
    func revokeCutsConnections() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let lines = LineBox()
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], log: { lines.values.append($0) }, localHosts: ["::1"])
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        let (iPhone, reply) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        #expect(reply == .authenticated)
        _ = try await nextAdmin(admin)

        try await send(.revoke(deviceID: deviceID), on: admin)
        let removed = try await iPhone.receive(where: { if case .error = $0 { true } else { false } })
        #expect(removed == .error(code: .unpaired, message: "Appareil retiré depuis le Mac."))
        await #expect(throws: TLSClientError.noChannel) {
            while true {
                _ = try await iPhone.receive()
            }
        }
        let after = try await nextAdmin(admin)
        #expect(after.devices.isEmpty)
        #expect(try authority.devices.device(id: deviceID) == nil)
        #expect(lines.values.contains("Appareil \(deviceID.prefix(8)) (iPhone de test) retiré depuis le Mac."))
        withExtendedLifetime(server) {}
    }

    @Test("Oubli depuis l'iPhone : appareil retiré, connexion coupée, journalisé ; la poignée de main suivante est refusée")
    func forgetMeRemovesDevice() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let lines = LineBox()
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], log: { lines.values.append($0) }, localHosts: ["::1"])
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        let (iPhone, reply) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        #expect(reply == .authenticated)
        _ = try await nextAdmin(admin)

        try iPhone.send(.forgetMe)
        await #expect(throws: TLSClientError.noChannel) {
            while true {
                _ = try await iPhone.receive()
            }
        }
        #expect(try await nextAdmin(admin).devices.isEmpty)
        #expect(try authority.devices.device(id: deviceID) == nil)
        #expect(lines.values.contains("Appareil \(deviceID.prefix(8)) (iPhone de test) retiré depuis l'iPhone."))
        let again = TLSClient(host: "::1", port: ports["::1"]!, identity: deviceID, key: lanKey)
        defer { again.close() }
        await #expect(throws: TLSClientError.noChannel) { try await again.open() }
        withExtendedLifetime(server) {}
    }

    @Test("Oubli d'un appareil déjà retiré de la liste (retrait concurrent) : connexion coupée, rien de journalisé")
    func forgetMeAfterRemoval() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let lines = LineBox()
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], log: { lines.values.append($0) }, localHosts: ["::1"])
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        let (iPhone, reply) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        #expect(reply == .authenticated)
        _ = try await nextAdmin(admin)

        // Retrait par ailleurs (ligne de commande) pendant que l'iPhone est connecté, puis son propre oubli.
        try authority.devices.remove(id: deviceID)
        try iPhone.send(.forgetMe)
        await #expect(throws: TLSClientError.noChannel) {
            while true {
                _ = try await iPhone.receive()
            }
        }
        #expect(try await nextAdmin(admin).devices.isEmpty)
        #expect(!lines.values.contains { $0.contains("retiré depuis") })
        withExtendedLifetime(server) {}
    }

    @Test("Oubli demandé par le Mac (confiance) : badMessage, rien n'est retiré")
    func forgetMeFromTrustedClient() async throws {
        try pairTestDevice()
        let (server, ports) = await startServer()
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        try await send(.forgetMe, on: admin)
        #expect(try await next(admin) { if case .error = $0 { true } else { false } } == .error(code: .badMessage, message: "Message réservé à un iPhone appairé."))
        #expect(try authority.devices.device(id: deviceID) != nil)
        withExtendedLifetime(server) {}
    }

    @Test("Oubli demandé avant l'authentification : badMessage, rien n'est retiré")
    func forgetMeWithoutDevice() async throws {
        try pairTestDevice()
        let (server, ports) = await startServer(trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await challenge(task)
        try await send(.forgetMe, on: task)
        #expect(try await next(task) { _ in true } == .error(code: .badMessage, message: "Message réservé à un iPhone appairé."))
        #expect(try authority.devices.device(id: deviceID) != nil)
        withExtendedLifetime(server) {}
    }

    @Test("aiUpdated depuis le Mac : l'utilitaire du suivi IA est relancé, rien n'est renvoyé (spec § 6.5 bis)")
    func aiUpdatedFromMac() async throws {
        let (server, ports) = await startServer()
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        #expect(ai.resets == 0)
        try await send(.aiUpdated, on: admin)
        try await waitUntil { ai.resets == 1 }
        #expect(WebSocketServer.isAdministration(.aiUpdated))
        withExtendedLifetime(server) {}
    }

    @Test("forgetMe n'est pas un message d'administration")
    func forgetMeIsNotAdministration() {
        #expect(!WebSocketServer.isAdministration(.forgetMe))
    }

    @Test("Un iPhone qui s'authentifie prépare le suivi IA ; le Mac de confiance, non")
    func prewarmOnIPhoneOnly() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], localHosts: ["::1"])
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        #expect(ai.prewarms == 0)

        let (iPhone, reply) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        defer { iPhone.close() }
        #expect(reply == .authenticated)
        #expect(ai.prewarms == 1)
        withExtendedLifetime(server) {}
    }

    @Test("Expulser, débloquer ou retirer un appareil inconnu : « Appareil inconnu. »", arguments: [
        ClientMessage.kick(deviceID: "00112233445566778899aabbccddeeff"),
        .unblock(deviceID: "00112233445566778899aabbccddeeff"),
        .revoke(deviceID: "00112233445566778899aabbccddeeff"),
    ])
    func unknownDevice(_ message: ClientMessage) async throws {
        let (server, ports) = await startServer()
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        try await send(message, on: admin)
        #expect(try await next(admin) { if case .error = $0 { true } else { false } } == .error(code: .badMessage, message: "Appareil inconnu."))
        withExtendedLifetime(server) {}
    }

    @Test("Appairage ouvert puis annulé depuis le Mac : publié, journalisé, plus d'appairage en cours")
    func closePairing() async throws {
        let lines = LineBox()
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], log: { lines.values.append($0) }, localHosts: ["::1"])
        let (admin, _) = try await watchAdmin(ports["127.0.0.1"]!)
        defer { admin.cancel(with: .goingAway, reason: nil) }
        try await send(.openPairing, on: admin)
        let opened = try await nextAdmin(admin)
        let pairing = try #require(opened.pairing)
        #expect(pairing.pairingID == authority.pairing.current?.pairingID)
        try await send(.closePairing, on: admin)
        #expect(try await nextAdmin(admin).pairing == nil)
        #expect(authority.pairing.current == nil)
        #expect(lines.values.contains("Appairage \(pairing.pairingID) annulé."))
        withExtendedLifetime(server) {}
    }

    @Test("Invitation : 4 adresses au plus, dans l'ordre")
    func invitationHosts() {
        let hosts = ["192.168.0.2", "192.168.0.3", "10.0.0.5", "169.254.0.7", "192.168.0.9"]
        #expect(WebSocketServer.invitationHosts(hosts) == ["192.168.0.2", "192.168.0.3", "10.0.0.5", "169.254.0.7"])
        #expect(WebSocketServer.invitationHosts(["192.168.0.2"]) == ["192.168.0.2"])
        // Une adresse que l'app iPhone rejetterait (publique, IPv6) est écartée avant le plafond de 4.
        #expect(WebSocketServer.invitationHosts(["192.0.2.1", "192.168.0.2", "fe80::1", "10.0.0.5"]) == ["192.168.0.2", "10.0.0.5"])
        #expect(WebSocketServer.invitationHosts(["192.0.2.1"]).isEmpty)
    }

    @Test("Appareil retiré : refusé dès la poignée de main TLS suivante")
    func localRevocation() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], trustLoopback: false, localHosts: ["::1"])
        try authority.devices.remove(prefix: String(deviceID.prefix(8)))
        let client = TLSClient(host: "::1", port: ports["::1"]!, identity: deviceID, key: lanKey)
        defer { client.close() }
        await #expect(throws: TLSClientError.noChannel) { try await client.open() }
        withExtendedLifetime(server) {}
    }

    @Test("L'état n'est diffusé qu'aux clients authentifiés")
    func broadcastOnlyToAuthenticated() async throws {
        try pairTestDevice()
        let (server, ports) = await startServer(trustLoopback: false)
        let anonymous = connect("127.0.0.1", ports["127.0.0.1"]!)
        let member = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { [anonymous, member].forEach { $0.cancel(with: .goingAway, reason: nil) } }
        _ = try await challenge(anonymous)
        let nonce = try await challenge(member)
        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: member)
        _ = try await next(member) { if case .state = $0 { true } else { false } }

        try await send(.move(pan: 1, tilt: 0), on: member)
        _ = try await next(member) { if case let .state(s) = $0 { s.moving } else { false } }
        // Le client anonyme ne reçoit que la réponse à son propre message.
        try await send(.zoom(value: 10), on: anonymous)
        #expect(try await next(anonymous) { _ in true } == .error(code: .notAuthenticated, message: "Authentification d'abord."))
        withExtendedLifetime(server) {}
    }

    @Test("Réserves : la confiance n'est jamais refusée à cause des anonymes, un anonyme l'est au-delà de 2 par adresse ou de 8 en tout")
    func admission() {
        let eight = (1...8).map { "192.0.2.\($0)" }
        #expect(WebSocketServer.admits(trusted: true, address: "127.0.0.1", trustedCount: 0, pendingAddresses: eight))
        #expect(WebSocketServer.admits(trusted: true, address: "127.0.0.1", trustedCount: 3, pendingAddresses: []))
        #expect(!WebSocketServer.admits(trusted: true, address: "127.0.0.1", trustedCount: 4, pendingAddresses: []))

        #expect(WebSocketServer.admits(trusted: false, address: "192.0.2.1", trustedCount: 4, pendingAddresses: ["192.0.2.1"]))
        #expect(!WebSocketServer.admits(trusted: false, address: "192.0.2.1", trustedCount: 0, pendingAddresses: ["192.0.2.1", "192.0.2.1"]))
        #expect(WebSocketServer.admits(trusted: false, address: "192.0.2.9", trustedCount: 0, pendingAddresses: ["192.0.2.1", "192.0.2.1"]))
        #expect(!WebSocketServer.admits(trusted: false, address: "192.0.2.9", trustedCount: 0, pendingAddresses: eight))
        #expect(WebSocketServer.admits(trusted: false, address: "192.0.2.9", trustedCount: 0, pendingAddresses: Array(eight.dropLast())))
    }

    @Test("Écoute Tailscale : seules les adresses 100.64.0.0/10 et fd7a:115c:a1e0::/48 sont admises")
    func tailscaleAddresses() {
        #expect(WebSocketServer.isTailscaleAddress("100.64.0.0"))
        #expect(!WebSocketServer.isTailscaleAddress("192.0.2.1"))
        #expect(!WebSocketServer.isTailscaleAddress("169.254.1.1"))
        #expect(!WebSocketServer.isTailscaleAddress("127.0.0.1"))
        #expect(WebSocketServer.isTailscaleAddress("fd7a:115c:a1e0::1"))
        #expect(WebSocketServer.isTailscaleAddress("fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff"))
        #expect(WebSocketServer.isTailscaleAddress("fd7a:115c:a1e0::1%utun4"))
        #expect(!WebSocketServer.isTailscaleAddress("fd7a:115c:a1e1::1"))
        #expect(!WebSocketServer.isTailscaleAddress("fe80::1%en0"))
        #expect(!WebSocketServer.isTailscaleAddress("::1"))
        #expect(!WebSocketServer.isTailscaleAddress(""))
        #expect(!WebSocketServer.isTailscaleAddress("mac.exemple.ts.net"))
        #expect(!WebSocketServer.isTailscaleAddress("100.64.0"))
    }

    @Test("Réseau : 2 connexions anonymes par adresse, la 3e est fermée sans défi, journalisée")
    func pendingPerAddress() async throws {
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false)
        let port = ports["127.0.0.1"]!
        let first = connect("127.0.0.1", port)
        let second = connect("127.0.0.1", port)
        defer { [first, second].forEach { $0.cancel(with: .goingAway, reason: nil) } }
        #expect(try await challenge(first).count == NacelleAuth.nonceLength)
        #expect(try await challenge(second).count == NacelleAuth.nonceLength)

        let third = connect("127.0.0.1", port)
        defer { third.cancel(with: .goingAway, reason: nil) }
        await #expect(throws: (any Error).self) {
            _ = try await third.receive()
        }
        #expect(lines.values.contains("Connexion refusée : trop de connexions anonymes (127.0.0.1)."))
        #expect(server.clientCount == 2)
    }

    @Test("Un anonyme qui s'authentifie alors que 4 clients le sont déjà est refusé")
    func authenticatedLimit() async throws {
        try pairTestDevice()
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false)
        let port = ports["127.0.0.1"]!
        var members: [URLSessionWebSocketTask] = []
        for _ in 0..<WebSocketServer.maxClients {
            let task = connect("127.0.0.1", port)
            let nonce = try await challenge(task)
            try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
            _ = try await next(task) { if case .state = $0 { true } else { false } }
            members.append(task)
        }
        let extra = connect("127.0.0.1", port)
        let nonce = try await challenge(extra)
        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: extra)
        await #expect(throws: (any Error).self) {
            _ = try await extra.receive()
        }
        try await waitUntil { server.clientCount == WebSocketServer.maxClients }
        #expect(lines.values.contains("Connexion refusée : déjà 4 clients."))
        (members + [extra]).forEach { $0.cancel(with: .goingAway, reason: nil) }
    }

    @Test("Journal : un identifiant d'appareil forgé n'y entre pas tel quel")
    func forgedDeviceIDNotLogged() async throws {
        #expect(WebSocketServer.logID(deviceID) == String(deviceID.prefix(8)))
        #expect(WebSocketServer.logID("0123456789abcdef0123456789ABCDEF") == "01234567")
        #expect(WebSocketServer.logID("0123456789abcdef0123456789abcdef0") == "invalide")
        #expect(WebSocketServer.logID("abcd\nClient 9 authentifié : x") == "invalide")
        #expect(WebSocketServer.logID("zzzzzzzz") == "invalide")

        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await challenge(task)
        try await send(.auth(deviceID: "abcd\nClient 9 authentifié : x", signature: Data(count: 64)), on: task)
        _ = try await next(task) { _ in true }
        try await waitUntil { server.clientCount == 0 }
        #expect(lines.values.contains { $0.hasPrefix("Client 1 refusé : appareil inconnu invalide (") })
        #expect(!lines.values.contains { $0.contains("\n") })
    }

    @Test("Client qui ne répond pas aux pings : place libérée 25 s après le dernier pong")
    func missingPong() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) })
        let client = rawClient(ports["127.0.0.1"]!, webSocket: true)
        defer { client.cancel() }
        // Prêt : le délai de poignée de main est annulé, restent le ping et l'échéance du pong.
        try await waitUntil { server.clientCount == 1 && scheduler.pendingCount == 2 }

        scheduler.advance(by: WebSocketServer.pingInterval)
        try await Task.sleep(for: .milliseconds(300))
        scheduler.advance(by: WebSocketServer.pingInterval)
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.clientCount == 1)
        scheduler.advance(by: WebSocketServer.pongTimeout - 2 * WebSocketServer.pingInterval)
        #expect(server.clientCount == 0)
        #expect(lines.values.contains("Client 1 libéré : pas de pong depuis 25 s."))
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Client qui répond aux pings (URLSessionWebSocketTask) : gardé au-delà de 25 s")
    func pongKeepsClient() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) })
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await next(task) { _ in true }
        try await waitUntil { scheduler.pendingCount == 2 }

        // URLSessionWebSocketTask ne répond aux pings que si une réception est en attente :
        // comme l'app iOS et nacelle-ws, on lit en continu.
        let reader = Task { while true { _ = try await task.receive() } }
        defer { reader.cancel() }
        for _ in 0..<4 {
            scheduler.advance(by: WebSocketServer.pingInterval)
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(server.clientCount == 1)
        #expect(!lines.values.contains { $0.contains("libéré") })
    }

    @Test("Même appareil authentifié deux fois, l'ancienne connexion muette : sondée, libérée après staleProbeTimeout")
    func staleDuplicateIsReleased() async throws {
        try pairTestDevice()
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) }, trustLoopback: false)
        let port = ports["127.0.0.1"]!
        let stale = try await authenticatedSilentClient(port)
        defer { stale.cancel() }
        try await waitUntil { lines.values.contains { $0.hasPrefix("Client 1 authentifié") } }

        let fresh = connect("127.0.0.1", port)
        defer { fresh.cancel(with: .goingAway, reason: nil) }
        let nonce = try await challenge(fresh)
        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: fresh)
        _ = try await next(fresh) { if case .state = $0 { true } else { false } }
        #expect(server.clientCount == 2)

        // Le temps du sondage, le muet n'a pas encore perdu sa place.
        scheduler.advance(by: WebSocketServer.staleProbeTimeout - 1)
        #expect(server.clientCount == 2)
        scheduler.advance(by: 1)
        #expect(server.clientCount == 1)
        #expect(lines.values.contains("Client 1 libéré : remplacé par une autre connexion du même appareil, sans réponse."))
    }

    @Test("Même appareil authentifié deux fois, l'ancienne connexion répond au ping : les deux restent")
    func answeringDuplicateStays() async throws {
        try pairTestDevice()
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) }, trustLoopback: false)
        let port = ports["127.0.0.1"]!
        var tasks: [URLSessionWebSocketTask] = []
        var readers: [Task<Void, Error>] = []
        defer {
            readers.forEach { $0.cancel() }
            tasks.forEach { $0.cancel(with: .goingAway, reason: nil) }
        }
        for _ in 0..<2 {
            let task = connect("127.0.0.1", port)
            tasks.append(task)
            let nonce = try await challenge(task)
            try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
            _ = try await next(task) { if case .state = $0 { true } else { false } }
            // Comme l'app iOS : lecture continue, donc pong automatique.
            readers.append(Task { while true { _ = try await task.receive() } })
        }
        #expect(server.clientCount == 2)

        // Laisse au pong le temps de revenir avant que le délai de sondage ne passe.
        try await Task.sleep(for: .milliseconds(500))
        scheduler.advance(by: WebSocketServer.staleProbeTimeout)
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.clientCount == 2)
        #expect(!lines.values.contains { $0.contains("libéré") })
        // Le pong a rendu l'échéance normale : toujours là bien après le délai de sondage.
        scheduler.advance(by: WebSocketServer.pongTimeout - WebSocketServer.staleProbeTimeout - 1)
        #expect(server.clientCount == 2)
    }

    @Test("Connexion de confiance : jamais sondée quand un appareil s'authentifie")
    func trustedIsNeverProbed() async throws {
        let lanKey = NacelleTLS.makeKey()
        try pairTestDevice(lanKey: lanKey)
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], scheduler: scheduler, log: { lines.values.append($0) }, localHosts: ["::1"])
        let trusted = rawClient(ports["127.0.0.1"]!, webSocket: true)
        defer { trusted.cancel() }
        try await waitUntil { server.clientCount == 1 && scheduler.pendingCount == 2 }
        let (first, firstReply) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        defer { first.close() }
        let (second, secondReply) = try await authenticateOverTLS(port: ports["::1"]!, lanKey: lanKey)
        defer { second.close() }
        #expect(firstReply == .authenticated)
        #expect(secondReply == .authenticated)

        scheduler.advance(by: WebSocketServer.staleProbeTimeout)
        try await Task.sleep(for: .milliseconds(300))
        // Le Mac (client 1, muet) garde sa place : ni sondé, ni libéré.
        #expect(!lines.values.contains { $0.hasPrefix("Client 1 libéré") })
        #expect(server.clientCount >= 2)
    }

    @Test("Connexion en attente (chemin réseau perdu) : place libérée, avec une ligne de journal")
    func waitingReleases() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) })
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await next(task) { _ in true }

        server.connectionChanged(1, .waiting(.posix(.ENETDOWN)))
        #expect(server.clientCount == 0)
        #expect(lines.values.contains { $0.hasPrefix("Client 1 libéré : connexion en attente") })
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Fermeture normale : minuteries du client annulées, rien de plus au journal")
    func normalCloseCancelsTimers() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) })
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        _ = try await next(task) { _ in true }
        try await waitUntil { scheduler.pendingCount == 2 }

        task.cancel(with: .goingAway, reason: nil)
        try await waitUntil { server.clientCount == 0 }
        #expect(scheduler.pendingCount == 0)
        #expect(!lines.values.contains { $0.contains("libéré") })
    }
}

@MainActor
final class LineBox {
    var values: [String] = []
}

/// Horloge murale de test, avancée à la main.
final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var date: Date {
        current.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Port d'une écoute relancée (tests).
@MainActor
final class PortBox {
    var port: UInt16?
}

/// Relais WebRTC de test : la réponse est calculée à partir de l'offre.
struct FakeRelay: WebRTCRelay {
    let handler: @Sendable (String) async throws -> String

    init(_ handler: @escaping @Sendable (String) async throws -> String) {
        self.handler = handler
    }

    func answer(offer: String) async throws -> String {
        try await handler(offer)
    }
}

/// Compteur partagé avec un relais de test.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

@MainActor
final class StubCamera: CameraDevice {
    var isPresent = true
    private(set) var relativeCommands: [PanTiltRelative] = []

    func setPanTiltRelative(_ command: PanTiltRelative) throws {
        relativeCommands.append(command)
    }

    func setPanTiltAbsolute(panDegrees: Double, tiltDegrees: Double) throws {}
    func setZoom(_ value: Int) throws {}

    func readPanTilt() throws -> PanTiltPosition {
        PanTiltPosition(pan: 0, tilt: 0)
    }

    func readZoom() throws -> Int {
        0
    }
}

@MainActor
final class StubAI: AIRunner {
    private(set) var prewarms = 0
    private(set) var resets = 0

    func prewarm() {
        prewarms += 1
    }

    func reset() {
        resets += 1
    }

    func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        completion(.success)
    }
}

final class StubStore: StateStore {
    func load() -> PersistedState {
        PersistedState(privacy: false, saved: nil)
    }

    func save(_ state: PersistedState) throws {}
}

// MARK: - Trames voix (spec parler § 5)

extension WebSocketServerTests {
    private func voiceFrame(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: VoiceFrame.byteCount)
    }

    /// Un iPhone appairé et authentifié (127.0.0.1 sans confiance).
    private func authenticatedDevice(_ port: UInt16) async throws -> URLSessionWebSocketTask {
        let task = connect("127.0.0.1", port)
        let nonce = try await challenge(task)
        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
        #expect(try await next(task) { _ in true } == .authenticated)
        return task
    }

    @Test("Trame voix d'un iPhone authentifié : relayée en UDP vers talkd, telle quelle et dans l'ordre")
    func voiceRelayed() async throws {
        try pairTestDevice()
        let receiver = try UDPTestReceiver()
        let sink = UDPVoiceSink(port: receiver.port)
        let (server, ports) = await startServer(trustLoopback: false, voiceSink: sink)
        let task = try await authenticatedDevice(ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        for byte in 1...3 {
            try await task.send(.data(voiceFrame(UInt8(byte))))
        }
        for byte in 1...3 {
            #expect(await receiver.receiveAsync() == voiceFrame(UInt8(byte)))
        }
        #expect(server.voiceRefusals.total == 0)
    }

    @Test("Trame voix du client de confiance 127.0.0.1 : ignorée et comptée, la connexion reste ouverte")
    func voiceFromTrustedClient() async throws {
        let receiver = try UDPTestReceiver()
        let sink = UDPVoiceSink(port: receiver.port)
        let (server, ports) = await startServer(voiceSink: sink)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await next(task) { _ in true }

        try await task.send(.data(voiceFrame(1)))
        try await waitUntil { server.voiceRefusals.unauthorized == 1 }
        #expect(await receiver.receiveAsync(timeout: 0.3) == nil)
        // La connexion fonctionne toujours.
        try await send(.move(pan: 1, tilt: 0), on: task)
        _ = try await next(task) { if case let .state(s) = $0 { s.moving } else { false } }
    }

    @Test("Trame voix avant l'authentification : ignorée et comptée, rien ne part vers talkd")
    func voiceBeforeAuth() async throws {
        try pairTestDevice()
        let receiver = try UDPTestReceiver()
        let sink = UDPVoiceSink(port: receiver.port)
        let (server, ports) = await startServer(trustLoopback: false, voiceSink: sink)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        let nonce = try await challenge(task)

        try await task.send(.data(voiceFrame(1)))
        try await waitUntil { server.voiceRefusals.unauthorized == 1 }
        // Le défi reste valable : l'authentification réussit ensuite.
        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
        #expect(try await next(task) { _ in true } == .authenticated)
        #expect(await receiver.receiveAsync(timeout: 0.3) == nil)
    }

    @Test("Mauvaise taille : ignorée et comptée, la connexion reste ouverte et la bonne trame suivante passe")
    func voiceBadSize() async throws {
        try pairTestDevice()
        let receiver = try UDPTestReceiver()
        let sink = UDPVoiceSink(port: receiver.port)
        let (server, ports) = await startServer(trustLoopback: false, voiceSink: sink)
        let task = try await authenticatedDevice(ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        try await task.send(.data(Data(count: 639)))
        try await task.send(.data(Data(count: 1280)))
        try await task.send(.data(voiceFrame(5)))
        #expect(await receiver.receiveAsync() == voiceFrame(5))
        #expect(server.voiceRefusals.badSize == 2)
        #expect(await receiver.receiveAsync(timeout: 0.3) == nil)
    }

    @Test("Au-delà de la limite par seconde : l'excédent est ignoré et compté")
    func voiceRateLimited() async throws {
        try pairTestDevice()
        let receiver = try UDPTestReceiver()
        let sink = UDPVoiceSink(port: receiver.port)
        // Horloge figée : toutes les trames tombent dans la même seconde.
        let (server, ports) = await startServer(scheduler: FakeScheduler(), trustLoopback: false, voiceSink: sink)
        let task = try await authenticatedDevice(ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let allowed = VoiceFrame.maxFramesPerSecond + VoiceRelayer.burstTolerance
        for index in 0..<(allowed + 15) {
            try await task.send(.data(voiceFrame(UInt8(index % 200))))
        }
        try await waitUntil { server.voiceRefusals.tooFast == 15 }
        #expect(await receiver.drainAsync().count == allowed)
    }

    @Test("Un message texte passe encore après des trames voix")
    func textAfterVoice() async throws {
        try pairTestDevice()
        let (server, ports) = await startServer(trustLoopback: false, voiceSink: RecordingSink())
        let task = try await authenticatedDevice(ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        try await task.send(.data(voiceFrame(1)))
        try await send(.move(pan: 1, tilt: 0), on: task)
        _ = try await next(task) { if case let .state(s) = $0 { s.moving } else { false } }
        withExtendedLifetime(server) {}
    }

    @Test("Déconnexion pendant la parole : une ligne de journal pour la prise de parole, sans le son")
    func voiceJournal() async throws {
        try pairTestDevice()
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false, voiceSink: RecordingSink())
        let task = try await authenticatedDevice(ports["127.0.0.1"]!)

        let distinctive = Data((0..<VoiceFrame.byteCount).map { UInt8(truncatingIfNeeded: 0x30 + $0) })
        try await task.send(.data(distinctive))
        try await task.send(.data(distinctive))
        task.cancel(with: .goingAway, reason: nil)
        try await waitUntil { lines.values.contains { $0.hasPrefix("Parole de l'appareil \(deviceID.prefix(8)) (iPhone de test)") } }
        let line = lines.values.first { $0.hasPrefix("Parole") } ?? ""
        #expect(line.contains("2 trames relayées"))
        #expect(!lines.values.joined().contains(distinctive.base64EncodedString()))
        withExtendedLifetime(server) {}
    }

    @Test("L'état envoyé aux clients porte le talkback du contrôleur")
    func stateCarriesTalkback() async throws {
        let (server, ports) = await startServer()
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        guard case let .state(first) = try await next(task, where: { if case .state = $0 { true } else { false } }) else { return }
        #expect(first.talkback == .unavailable)

        controller.setTalkback(.ready)
        guard case let .state(second) = try await next(task, where: { if case let .state(s) = $0 { s.talkback == .ready } else { false } }) else { return }
        #expect(second.talkback == .ready)
        withExtendedLifetime(server) {}
    }
}
