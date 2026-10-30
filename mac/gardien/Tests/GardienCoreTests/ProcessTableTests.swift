import Foundation
import Testing
@testable import GardienCore

/// Un serveur TCP d'écoute sur 127.0.0.1, sur un port libre tiré par le système (jamais 8554 ni un port RTSP réel) :
/// les connexions s'établissent dans la file d'attente, sans `accept`.
final class LocalListener {
    let descriptor: Int32
    let port: UInt16

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(descriptor, 16) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        try #require(port != 0 && port != 8554)
        self.descriptor = descriptor
        self.port = port
    }

    /// Une connexion du processus de test lui-même vers ce serveur.
    func connectHere() throws -> Int32 {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        try #require(client >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(connected == 0)
        return client
    }

    deinit {
        close(descriptor)
    }
}

/// Un port libre au moment du tirage, sans serveur : rien ne s'y connecte.
func unusedPort() throws -> UInt16 {
    let listener = try LocalListener()
    return listener.port
}

@Suite("Table des processus : arguments, sockets, identité")
struct ProcessTableTests {
    @Test("Les arguments d'un processus lancé par le test, argv[0] compris")
    func arguments() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["37"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        #expect(ProcessTable.arguments(of: process.processIdentifier) == ["/bin/sleep", "37"])
        #expect(ProcessTable.parentID(of: process.processIdentifier) == getpid())
        #expect(ProcessTable.userID(of: process.processIdentifier) == getuid())
    }

    @Test("Socket établie vers le port : connecté ; vers un autre port, ou aucune : décroché")
    func sockets() throws {
        let listener = try LocalListener()
        let other = try unusedPort()
        #expect(ProcessTable.rtspLink(of: getpid(), port: listener.port) == .detached, "le serveur d'écoute seul ne compte pas")
        let client = try listener.connectHere()
        defer { close(client) }
        #expect(ProcessTable.rtspLink(of: getpid(), port: listener.port) == .connected)
        #expect(ProcessTable.rtspLink(of: getpid(), port: other) == .detached)
    }

    @Test("Le processus vivant, et lui seul : une autre heure de démarrage (pid réutilisé) n'est pas lui")
    func identity() throws {
        var me = try #require(ProcessTable.identity(of: getpid()))
        #expect(ProcessTable.isAlive(me))
        me.startMicroseconds += 1
        #expect(!ProcessTable.isAlive(me))
    }

    @Test("Les sorties RTSP de go2rtc : rtsp://127.0.0.1:<port>/<chemin>, port lu")
    func rtspOutput() {
        #expect(LiveCaptureSystem.outputPort("rtsp://127.0.0.1:18554/0123456789abcdef0123456789abcdef") == 18554)
        #expect(LiveCaptureSystem.outputPort("rtsp://127.0.0.1:18554") == nil)
        #expect(LiveCaptureSystem.outputPort("rtsp://localhost:18554/x") == nil)
        #expect(LiveCaptureSystem.outputPort("-") == nil)
        #expect(LiveCaptureSystem.outputPort("rtsp://127.0.0.1:99999/x") == nil)
    }
}
