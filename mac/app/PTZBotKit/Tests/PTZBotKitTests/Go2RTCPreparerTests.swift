import Foundation
import Testing
@testable import PTZBotKit

// Sérialisée : les deux tests « Ports réels » ouvrent de vraies sockets, l'un après l'autre.
@Suite("go2rtc : préparation du lancement et ports", .french, .serialized)
struct Go2RTCPreparerTests {
    private func preparer(_ directory: URL, locator: FFmpegLocator = .homebrew, catalog: FakeCatalog = FakeCatalog(),
                          ports: FakePorts = FakePorts()) -> Go2RTCPreparer {
        Go2RTCPreparer(configURL: directory.appending(path: "go2rtc.yaml"), locator: locator, catalog: catalog, ports: ports)
    }

    @Test("Prêt : yaml écrit en mode 600 (vraie caméra, pas la virtuelle), ports vérifiés, dossier de ffmpeg pour le PATH")
    func ready() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ports = FakePorts()
        let result = await preparer(directory, ports: ports).prepare(Go2RTCFixtures.settings())
        guard case let .ready(launch) = result else {
            Issue.record("attendu : prêt, reçu \(result)")
            return
        }
        let config = directory.appending(path: "go2rtc.yaml")
        #expect(launch.config == config)
        #expect(launch.ffmpegDirectory?.path == "/opt/homebrew/bin")
        #expect(!launch.custom)
        // Le ménage du gardien : le port RTSP réglé, et les empreintes des deux sources du yaml écrit.
        #expect(launch.rtspPort == 8554)
        #expect(launch.captures == foldedEntries(try String(contentsOf: config, encoding: .utf8)).map { Go2RTCConfig.fingerprint(ofSource: $0) })
        #expect(launch.captures.count == 2)
        let expected = try Go2RTCConfig.yaml(settings: Go2RTCFixtures.settings(), ffmpeg: Go2RTCFixtures.ffmpeg,
                                             camera: Go2RTCFixtures.camera, microphone: Go2RTCFixtures.microphone)
        #expect(try String(contentsOf: config, encoding: .utf8) == expected)
        #expect(try Go2RTCFixtures.permissions(config) == 0o600)
        #expect(ports.probed == ["8554/tcp", "8555/tcp", "8555/udp", "1984/tcp/127.0.0.1"])
    }

    @Test("Bloqué : ffmpeg introuvable, caméra ou micro absents, nom réglé débranché ; rien n'est écrit")
    func blocked() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = Go2RTCFixtures.settings()
        #expect(await preparer(directory, locator: .missing).prepare(settings) == .blocked(.ffmpegMissing))
        #expect(await preparer(directory, catalog: FakeCatalog(cameraList: [])).prepare(settings) == .blocked(.cameraMissing))
        #expect(await preparer(directory, catalog: FakeCatalog(microphoneList: [])).prepare(settings) == .blocked(.microphoneMissing))
        var unplugged = settings
        unplugged.cameraName = "Caméra débranchée"
        #expect(await preparer(directory).prepare(unplugged) == .blocked(.cameraMissing))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "go2rtc.yaml").path))
    }

    @Test("Port pris (un autre go2rtc) : bloqué sur ce port, en TCP comme en UDP, et pour l'API")
    func portBusy() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (key, port) in [("8554/tcp", 8554), ("8555/udp", 8555), ("1984/tcp/127.0.0.1", 1984)] {
            let ports = FakePorts()
            ports.busy(key)
            #expect(await preparer(directory, ports: ports).prepare(Go2RTCFixtures.settings()) == .blocked(.portBusy(port)))
        }
    }

    @Test("Réglage refusé par le yaml : bloqué, avec le message")
    func invalidSettings() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = Go2RTCFixtures.settings()
        settings.password = ""
        let message = Go2RTCConfigError.missingCredential.localizedDescription
        #expect(await preparer(directory).prepare(settings) == .blocked(.invalidSettings(message)))
    }

    @Test("Fichier personnalisé : lancé tel quel, sans yaml écrit ni port vérifié ; introuvable : bloqué")
    func customFile() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let custom = directory.appending(path: "perso.yaml")
        try Data("api:\n".utf8).write(to: custom)
        var settings = Go2RTCFixtures.settings()
        settings.customConfigEnabled = true
        settings.customConfigPath = custom.path
        let ports = FakePorts()
        let result = await preparer(directory, catalog: FakeCatalog(cameraList: []), ports: ports).prepare(settings)
        // Le port réglé pour le ménage des enfants de go2rtc ; aucune empreinte : pas de ménage des orphelins.
        #expect(result == .ready(Go2RTCLaunch(config: URL(fileURLWithPath: custom.path), ffmpegDirectory: URL(fileURLWithPath: Go2RTCFixtures.ffmpeg).deletingLastPathComponent(),
                                              custom: true, rtspPort: 8554, captures: [])))
        #expect(ports.probed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "go2rtc.yaml").path))
        settings.customConfigPath = directory.appending(path: "absent.yaml").path
        #expect(await preparer(directory).prepare(settings) == .blocked(.customFileMissing))
    }

    @Test("Appliquer go2rtc éteint : yaml écrit avec l'appareil réglé, même débranché ; ffmpeg absent : bloqué")
    func writeConfig() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = Go2RTCFixtures.settings()
        settings.cameraName = "Caméra débranchée"
        #expect(await preparer(directory).writeConfig(settings) == nil)
        let text = try String(contentsOf: directory.appending(path: "go2rtc.yaml"), encoding: .utf8)
        #expect(text.contains("-i \"Caméra débranchée\""))
        #expect(await preparer(directory, locator: .missing).writeConfig(settings) == .ffmpegMissing)
        settings.customConfigEnabled = true
        #expect(await preparer(directory, locator: .missing).writeConfig(settings) == nil)
    }

    @Test("Ports réels : un serveur d'essai (joker IPv4, 127.0.0.1 ou double pile IPv6) est vu pris, en TCP comme en UDP ; refermé, le port est libre")
    func realPorts() throws {
        let probe = SystemPortProbe()
        for (type, transport) in [(SOCK_STREAM, PortTransport.tcp), (SOCK_DGRAM, .udp)] {
            for kind in TestServer.Kind.allCases {
                let server = try #require(TestServer.onFreePort(kind: kind, type: type), "\(kind) \(transport)")
                #expect(!probe.isFree(server.port, transport: transport, loopbackOnly: false), "\(kind) \(transport)")
                #expect(!probe.isFree(server.port, transport: transport, loopbackOnly: true), "\(kind) \(transport)")
                server.close()
                #expect(TestServer.becomesFree(server.port, transport: transport, loopbackOnly: false), "\(kind) \(transport)")
                #expect(TestServer.becomesFree(server.port, transport: transport, loopbackOnly: true), "\(kind) \(transport)")
            }
        }
    }

    @Test("Ports réels : un port qui n'a que des connexions en TIME_WAIT (après l'arrêt de go2rtc) est libre")
    func timeWaitIsFree() throws {
        let probe = SystemPortProbe()
        let server = try #require(TestServer.onFreePort(kind: .wildcard, type: SOCK_STREAM))
        try #require(server.leaveTimeWait(), "connexion de test")
        // Le serveur est refermé : seules restent les connexions fermées en premier de son côté (TIME_WAIT).
        #expect(TestServer.becomesFree(server.port, transport: .tcp, loopbackOnly: false))
        #expect(TestServer.becomesFree(server.port, transport: .tcp, loopbackOnly: true))
        // Et un serveur qui revient sur ce port est de nouveau vu pris.
        let again = try #require(TestServer.rebinding(kind: .wildcard, type: SOCK_STREAM, port: server.port))
        #expect(!probe.isFree(server.port, transport: .tcp, loopbackOnly: false))
        again.close()
    }
}

/// Un vrai serveur d'essai sur un port haut éphémère, avec `SO_REUSEADDR` comme go2rtc (Go).
struct TestServer {
    enum Kind: CaseIterable, CustomStringConvertible {
        /// 0.0.0.0
        case wildcard
        /// 127.0.0.1 seulement
        case loopback
        /// `[::]` en double pile, comme un serveur Go qui écoute sur `:port`
        case dualStack

        var description: String {
            switch self {
            case .wildcard: "0.0.0.0"
            case .loopback: "127.0.0.1"
            case .dualStack: "[::] double pile"
            }
        }
    }

    let descriptor: Int32
    let family: Int32
    let kind: Kind
    let type: Int32
    let port: Int

    /// `port` 0 : le système en choisit un.
    init?(kind: Kind, type: Int32, port: Int = 0) {
        self.kind = kind
        self.type = type
        family = kind == .dualStack ? AF_INET6 : AF_INET
        let descriptor = socket(family, type, 0)
        guard descriptor >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var bound: Int32
        var assigned = 0
        if family == AF_INET6 {
            var off: Int32 = 0
            setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            bound = withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr = in_addr(s_addr: (kind == .loopback ? 0x7F00_0001 : UInt32(0)).bigEndian)
            bound = withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard bound == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { assigned = Int(UInt16(bigEndian: $0.pointee.sin_port)) }
        }
        // sockaddr_in et sockaddr_in6 ont le port au même endroit (octets 2 et 3).
        if type == SOCK_STREAM, listen(descriptor, 4) != 0 {
            Darwin.close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        self.port = assigned
    }

    /// Un serveur sur un port que la sonde voit libre juste avant (TCP ou UDP, IPv4 et IPv6). Le port que choisit le
    /// système n'est garanti libre que pour l'adresse et la famille de la socket : il peut être tenu ailleurs, en IPv6
    /// par exemple. Quelques essais bornés, avec un nouveau port à chaque fois ; nil si aucun n'a abouti.
    static func onFreePort(kind: Kind, type: Int32, attempts: Int = 20) -> TestServer? {
        let probe = SystemPortProbe()
        let transport: PortTransport = type == SOCK_STREAM ? .tcp : .udp
        for _ in 0..<attempts {
            guard let scout = TestServer(kind: kind, type: type) else { continue }
            let port = scout.port
            scout.close()
            guard probe.isFree(port, transport: transport, loopbackOnly: false) else { continue }
            if let server = TestServer(kind: kind, type: type, port: port) { return server }
        }
        return nil
    }

    /// Les essais bornés de `becomesFree` et de `rebinding` : 5 ms d'écart, 2 s au plus.
    private static let pollInterval: useconds_t = 5_000
    private static let pollCount = 400

    /// Le port est-il vu libre, à 2 s près ? Une socket qu'on vient de fermer peut rester tenue un instant (EADDRINUSE
    /// moins d'une milliseconde, mesuré) quand un autre test du même processus lance un programme (`Process`) : l'enfant
    /// copie la table des descripteurs et ne lâche la socket qu'à son `exec` (explication probable, l'effet disparaît
    /// quand ces suites ne tournent pas en même temps). Une vraie régression de la sonde reste fausse jusqu'au bout.
    static func becomesFree(_ port: Int, transport: PortTransport, loopbackOnly: Bool) -> Bool {
        let probe = SystemPortProbe()
        for _ in 0..<pollCount {
            if probe.isFree(port, transport: transport, loopbackOnly: loopbackOnly) { return true }
            usleep(pollInterval)
        }
        return false
    }

    /// Un serveur qui revient sur un port qu'on vient de quitter, avec les mêmes essais bornés que `becomesFree`.
    static func rebinding(kind: Kind, type: Int32, port: Int) -> TestServer? {
        for _ in 0..<pollCount {
            if let server = TestServer(kind: kind, type: type, port: port) { return server }
            usleep(pollInterval)
        }
        return nil
    }

    func close() {
        Darwin.close(descriptor)
    }

    /// Une connexion en 127.0.0.1, acceptée puis fermée par le serveur en premier, puis le serveur est refermé :
    /// il reste des connexions en TIME_WAIT sur son port. false si la connexion de test a échoué.
    func leaveTimeWait() -> Bool {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let connected = withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(client)
            close()
            return false
        }
        let accepted = accept(descriptor, nil, nil)
        guard accepted >= 0 else {
            Darwin.close(client)
            close()
            return false
        }
        Darwin.close(accepted)
        Darwin.close(client)
        close()
        return true
    }
}
