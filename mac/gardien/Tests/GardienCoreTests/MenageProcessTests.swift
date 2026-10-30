import Foundation
import Testing
@testable import GardienCore

/// Le ménage et l'arrêt, avec de vrais processus : le gardien compilé, un shell pour go2rtc, et le faux ffmpeg
/// (`Tests/FauxFFmpeg`, construit par `swift build` à côté du gardien), qui compte ses SIGTERM et sort au-delà de 3.
/// Sécurité de la machine : un port tiré par le système (jamais 8554), des empreintes aléatoires (aucun vrai ffmpeg ne
/// peut correspondre), et les seuls signaux envoyés par le test vont à des processus qu'il a lancés, reconnus par leur
/// heure de démarrage.
@MainActor
@Suite("Gardien : ménage des ffmpeg, vrais processus", .timeLimit(.minutes(1)))
struct MenageProcessTests {
    static let fakeFFmpeg = GardienProcessTests.executable.deletingLastPathComponent().appending(path: "ffmpeg")
    /// Des délais courts : un passage toutes les 0,3 s, visé au-delà de 1 s, SIGTERM toutes les 0,2 s.
    static let fastSweep = ["--delais-menage", "0.3,1,0.2"]

    static func randomFingerprint() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Les fichiers d'un faux ffmpeg : le nombre de SIGTERM reçus, et son pid.
    struct FakeFiles {
        let count: URL
        let pid: URL

        init() {
            let directory = FileManager.default.temporaryDirectory
            count = directory.appending(path: "menage-\(UUID().uuidString).compte")
            pid = directory.appending(path: "menage-\(UUID().uuidString).pid")
        }

        var received: Int {
            (try? String(contentsOf: count, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        }

        /// Les arguments du faux ffmpeg : avfoundation, ses fichiers, la connexion, puis la sortie en dernier.
        func arguments(output: String, connectTo port: UInt16? = nil) -> [String] {
            ["-hide_banner", "-f", "avfoundation", "-i", "Caméra test", "-compte", count.path, "-pid", pid.path]
                + (port.map { ["-connecte", String($0)] } ?? []) + ["-f", "rtsp", output]
        }

        func remove() {
            try? FileManager.default.removeItem(at: count)
            try? FileManager.default.removeItem(at: pid)
        }
    }

    private func wait(_ limit: Duration, until condition: () -> Bool) async throws -> Bool {
        let start = ContinuousClock.now
        while !condition() {
            guard ContinuousClock.now - start < limit else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func launch(_ executable: URL, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Le processus dont le pid est écrit dans `file`, attendu 5 s au plus, reconnu par son heure de démarrage.
    private func identity(_ file: URL) async throws -> ProcessIdentity {
        var found: ProcessIdentity?
        _ = try await wait(.seconds(5)) {
            let pid = (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            found = pid.flatMap { ProcessTable.identity(of: $0) }
            return found != nil
        }
        return try #require(found, "le processus n'a pas écrit son pid")
    }

    /// Fin de test : SIGKILL à ce que le test a lancé et qui vit encore (le même processus, pas un pid réutilisé).
    private func cleanUp(_ processes: [Process], _ identities: [ProcessIdentity], files: [FakeFiles], extra: [URL] = []) {
        for process in processes where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        for identity in identities where ProcessTable.isAlive(identity) {
            kill(identity.pid, SIGKILL)
        }
        files.forEach { $0.remove() }
        extra.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Le gardien sur un faux go2rtc (`/bin/sh -c <script>`), avec ces options avant `--`.
    private func launchGardien(parent: Process, options: [String], script: String, arguments: [String]) throws -> Process {
        try #require(FileManager.default.isExecutableFile(atPath: GardienProcessTests.executable.path), "lancez `swift build` avant `swift test`")
        try #require(FileManager.default.isExecutableFile(atPath: Self.fakeFFmpeg.path), "lancez `swift build` avant `swift test`")
        return try launch(GardienProcessTests.executable,
                          ["--parent", String(parent.processIdentifier), "--arret", "10"] + options + ["--", "/bin/sh", "-c", script, "sh"] + arguments)
    }

    /// Le faux go2rtc : `$1` son pid, `$2` le faux ffmpeg, `$3` et `$4` les arguments de deux enfants séparés par `|`
    /// (découpés par le shell lui-même), lancés en arrière-plan : ses enfants directs, dans son groupe. Il sort sur SIGTERM
    /// sans les arrêter.
    static let go2rtcWithChildren = #"""
    echo $$ > "$1"; ffmpeg="$2"; one="$3"; two="$4"
    IFS='|'; set -f
    "$ffmpeg" $one & "$ffmpeg" $two &
    trap 'exit 0' TERM; while :; do /bin/sleep 0.2; done
    """#

    @Test("Enfants de go2rtc : le décroché reçoit 4 SIGTERM et sort ; le connecté, aucun ; à l'arrêt, 4 SIGTERM le font sortir")
    func detachedChildIsSwept() async throws {
        let listener = try LocalListener()
        let output = "rtsp://127.0.0.1:\(listener.port)/\(Self.randomFingerprint())"
        let detached = FakeFiles()
        let connected = FakeFiles()
        let goPID = FileManager.default.temporaryDirectory.appending(path: "menage-\(UUID().uuidString).go")
        let parent = try launch(URL(fileURLWithPath: "/bin/sleep"), ["60"])
        let gardien = try launchGardien(
            parent: parent, options: ["--rtsp", String(listener.port)] + Self.fastSweep, script: Self.go2rtcWithChildren,
            arguments: [goPID.path, Self.fakeFFmpeg.path, detached.arguments(output: output).joined(separator: "|"),
                        connected.arguments(output: output, connectTo: listener.port).joined(separator: "|")]
        )
        let go = try await identity(goPID)
        let lost = try await identity(detached.pid)
        let streaming = try await identity(connected.pid)
        defer { cleanUp([parent, gardien], [go, lost, streaming], files: [detached, connected], extra: [goPID]) }
        #expect(ProcessTable.parentID(of: lost.pid) == go.pid)
        #expect(ProcessTable.rtspLink(of: streaming.pid, port: listener.port) == .connected)
        #expect(try await wait(.seconds(10)) { !ProcessTable.isAlive(lost) }, "le décroché est sorti")
        #expect(detached.received == 4, "au-delà de 3 SIGTERM, pas un de plus")
        // Plusieurs passages encore : le connecté n'est jamais visé.
        try await Task.sleep(for: .seconds(1.5))
        #expect(connected.received == 0)
        #expect(ProcessTable.isAlive(streaming))
        // L'arrêt : go2rtc sort sans arrêter son enfant ; le gardien lui envoie 4 SIGTERM, à 1 s d'intervalle.
        let start = ContinuousClock.now
        kill(gardien.processIdentifier, SIGTERM)
        #expect(try await wait(.seconds(10)) { !gardien.isRunning })
        #expect(connected.received == 4)
        #expect(!ProcessTable.isAlive(streaming))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed > .seconds(2.5) && elapsed < .seconds(5), "4 SIGTERM à t = 0, 1, 2 et 3 s : \(elapsed)")
        #expect(gardien.terminationStatus == 0)
    }

    @Test("Sans --rtsp : aucun ménage, même décroché et vieux")
    func noSweepWithoutPort() async throws {
        let listener = try LocalListener()
        let output = "rtsp://127.0.0.1:\(listener.port)/\(Self.randomFingerprint())"
        let detached = FakeFiles()
        let other = FakeFiles()
        let goPID = FileManager.default.temporaryDirectory.appending(path: "menage-\(UUID().uuidString).go")
        let parent = try launch(URL(fileURLWithPath: "/bin/sleep"), ["60"])
        let gardien = try launchGardien(
            parent: parent, options: Self.fastSweep, script: Self.go2rtcWithChildren,
            arguments: [goPID.path, Self.fakeFFmpeg.path, detached.arguments(output: output).joined(separator: "|"),
                        other.arguments(output: output).joined(separator: "|")]
        )
        let go = try await identity(goPID)
        let lost = try await identity(detached.pid)
        let second = try await identity(other.pid)
        defer { cleanUp([parent, gardien], [go, lost, second], files: [detached, other], extra: [goPID]) }
        try await Task.sleep(for: .seconds(2.5))
        #expect(detached.received == 0)
        #expect(ProcessTable.isAlive(lost))
    }

    @Test("Enfant de go2rtc dont la sortie vise un autre port (fichier personnalisé) : jamais jugé")
    func childOnOtherPortIsSpared() async throws {
        let listener = try LocalListener()
        let otherPort = try unusedPort()
        let detached = FakeFiles()
        let elsewhere = FakeFiles()
        let goPID = FileManager.default.temporaryDirectory.appending(path: "menage-\(UUID().uuidString).go")
        let parent = try launch(URL(fileURLWithPath: "/bin/sleep"), ["60"])
        let gardien = try launchGardien(
            parent: parent, options: ["--rtsp", String(listener.port)] + Self.fastSweep, script: Self.go2rtcWithChildren,
            arguments: [goPID.path, Self.fakeFFmpeg.path,
                        detached.arguments(output: "rtsp://127.0.0.1:\(listener.port)/\(Self.randomFingerprint())").joined(separator: "|"),
                        elsewhere.arguments(output: "rtsp://127.0.0.1:\(otherPort)/\(Self.randomFingerprint())").joined(separator: "|")]
        )
        let go = try await identity(goPID)
        let lost = try await identity(detached.pid)
        let spared = try await identity(elsewhere.pid)
        defer { cleanUp([parent, gardien], [go, lost, spared], files: [detached, elsewhere], extra: [goPID]) }
        #expect(try await wait(.seconds(10)) { !ProcessTable.isAlive(lost) })
        try await Task.sleep(for: .seconds(1))
        #expect(elsewhere.received == 0)
        #expect(ProcessTable.isAlive(spared))
    }

    /// Un faux ffmpeg orphelin (PPID 1) : un shell le lance en arrière-plan et sort aussitôt.
    private func launchOrphan(_ files: FakeFiles, output: String, connectTo port: UInt16? = nil) async throws -> ProcessIdentity {
        let shell = try launch(URL(fileURLWithPath: "/bin/sh"), ["-c", #""$@" &"#, "sh", Self.fakeFFmpeg.path] + files.arguments(output: output, connectTo: port))
        shell.waitUntilExit()
        let orphan = try await identity(files.pid)
        #expect(try await wait(.seconds(5)) { ProcessTable.parentID(of: orphan.pid) == 1 }, "orphelin")
        return orphan
    }

    @Test("Orphelins : la bonne empreinte sur le bon port, décroché : visé ; autre empreinte, autre port ou connecté : épargné")
    func orphans() async throws {
        let listener = try LocalListener()
        let otherPort = try unusedPort()
        let ours = Self.randomFingerprint()
        let foreign = Self.randomFingerprint()
        let target = FakeFiles(), stranger = FakeFiles(), elsewhere = FakeFiles(), streaming = FakeFiles()
        let all = [target, stranger, elsewhere, streaming]
        var identities: [ProcessIdentity] = []
        defer { cleanUp([], identities, files: all) }
        identities.append(try await launchOrphan(target, output: "rtsp://127.0.0.1:\(listener.port)/\(ours)"))
        identities.append(try await launchOrphan(stranger, output: "rtsp://127.0.0.1:\(listener.port)/\(foreign)"))
        identities.append(try await launchOrphan(elsewhere, output: "rtsp://127.0.0.1:\(otherPort)/\(ours)"))
        identities.append(try await launchOrphan(streaming, output: "rtsp://127.0.0.1:\(listener.port)/\(ours)", connectTo: listener.port))
        let goPID = FileManager.default.temporaryDirectory.appending(path: "menage-\(UUID().uuidString).go")
        let parent = try launch(URL(fileURLWithPath: "/bin/sleep"), ["60"])
        let gardien = try launchGardien(
            parent: parent, options: ["--rtsp", String(listener.port), "--capture", ours] + Self.fastSweep,
            script: #"echo $$ > "$1"; exec /bin/sleep 60"#, arguments: [goPID.path]
        )
        let go = try await identity(goPID)
        identities.append(go)
        defer { cleanUp([parent, gardien], [], files: [], extra: [goPID]) }
        #expect(try await wait(.seconds(10)) { !ProcessTable.isAlive(identities[0]) }, "l'orphelin de PTZBot est sorti")
        #expect(target.received == 4)
        try await Task.sleep(for: .seconds(1.5))
        for (files, identity) in zip(all.dropFirst(), identities.dropFirst()) {
            #expect(files.received == 0)
            #expect(ProcessTable.isAlive(identity))
        }
    }

    @Test("Sans --capture : aucun orphelin visé, même avec l'empreinte d'un yaml de PTZBot")
    func noOrphanSweepWithoutFingerprints() async throws {
        let listener = try LocalListener()
        let files = FakeFiles()
        var identities: [ProcessIdentity] = []
        defer { cleanUp([], identities, files: [files]) }
        identities.append(try await launchOrphan(files, output: "rtsp://127.0.0.1:\(listener.port)/\(Self.randomFingerprint())"))
        let goPID = FileManager.default.temporaryDirectory.appending(path: "menage-\(UUID().uuidString).go")
        let parent = try launch(URL(fileURLWithPath: "/bin/sleep"), ["60"])
        let gardien = try launchGardien(parent: parent, options: ["--rtsp", String(listener.port)] + Self.fastSweep,
                                        script: #"echo $$ > "$1"; exec /bin/sleep 60"#, arguments: [goPID.path])
        identities.append(try await identity(goPID))
        defer { cleanUp([parent, gardien], [], files: [], extra: [goPID]) }
        try await Task.sleep(for: .seconds(2.5))
        #expect(files.received == 0)
        #expect(ProcessTable.isAlive(identities[0]))
    }
}
