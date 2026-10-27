import Foundation
import Testing
@testable import PTZBotKit

/// L'API de go2rtc simulée : le corps rendu, ou une erreur.
final class FakeGo2RTCAPI: Go2RTCAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _body: Data?
    private var _calls = 0

    /// nil : l'API ne répond pas.
    var body: Data? {
        get { lock.withLock { _body } }
        set { lock.withLock { _body = newValue } }
    }

    var calls: Int { lock.withLock { _calls } }

    func streams() async throws -> Data {
        let body = lock.withLock {
            _calls += 1
            return _body
        }
        guard let body else { throw URLError(.cannotConnectToHost) }
        return body
    }
}

/// La liste des processus simulée.
final class FakeProcessListing: ProcessListing, @unchecked Sendable {
    private let lock = NSLock()
    private var _output: String?

    var output: String? {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
    }

    func psOutput() -> String? {
        output
    }
}

/// La sonde de coreaudiod simulée : répond, ou non (expirée, en échec) ; peut rester bloquée jusqu'à `release()`.
final class FakeCoreAudioProbe: CoreAudioProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _responds = true
    private var _calls = 0
    private var _running = 0
    private var _maxRunning = 0
    private var gate: DispatchSemaphore?

    var responds: Bool {
        get { lock.withLock { _responds } }
        set { lock.withLock { _responds = newValue } }
    }

    var calls: Int { lock.withLock { _calls } }
    /// Sondes en cours au même moment, au plus (jamais deux, hors sonde abandonnée par la garde du moniteur).
    var maxRunning: Int { lock.withLock { _maxRunning } }
    /// Sondes en cours maintenant.
    var running: Int { lock.withLock { _running } }

    /// Les sondes suivantes restent bloquées jusqu'à `release()`.
    func block() {
        lock.withLock { gate = DispatchSemaphore(value: 0) }
    }

    func release() {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            defer { self.gate = nil }
            return self.gate
        }
        gate?.signal()
    }

    /// Libère toutes les sondes bloquées.
    func releaseAll() {
        let (gate, count) = lock.withLock { () -> (DispatchSemaphore?, Int) in
            defer { self.gate = nil }
            return (self.gate, _running)
        }
        for _ in 0..<count {
            gate?.signal()
        }
    }

    func coreAudioResponds() -> Bool {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            _calls += 1
            _running += 1
            _maxRunning = max(_maxRunning, _running)
            return self.gate
        }
        gate?.wait()
        return lock.withLock {
            _running -= 1
            return _responds
        }
    }
}

/// Des réponses de `GET /api/streams` de la forme de go2rtc 1.9.14 (relevée le 12/10 sur un go2rtc en service, valeurs
/// remplacées par des fictives).
enum StreamsFixtures {
    static let active = Data(#"""
    {"obsbot":{
      "producers":[
        {"id":1,"format_name":"rtsp","protocol":"rtsp+tcp","source":"exec:…","medias":["video, recvonly, H264"],"receivers":[{}],"bytes_recv":1200},
        {"id":2,"format_name":"rtsp","protocol":"rtsp+tcp","source":"exec:…","medias":["audio, recvonly, MPEG4-GENERIC/48000/2"],"receivers":[{}],"bytes_recv":300},
        {"url":"ffmpeg:obsbot#audio=opus"}],
      "consumers":[
        {"id":3,"format_name":"preload","medias":["video, sendonly, ANY"],"senders":[{}],"bytes_send":0},
        {"id":4,"format_name":"rtsp","protocol":"rtsp+tcp","remote_addr":"192.168.0.10:50000","medias":[],"senders":[],"bytes_send":10},
        {"id":5,"format_name":"webrtc","protocol":"udp","medias":[],"senders":[],"bytes_send":10},
        {"id":6,"format_name":"rtsp","protocol":"rtsp+tcp","medias":[],"senders":[],"bytes_send":10}]
    }}
    """#.utf8)

    /// La caméra débranchée : les producteurs exec ne reçoivent plus rien, seul le préchargement reste.
    static let noProducer = Data(#"""
    {"obsbot":{"producers":[{"url":"exec:…"},{"url":"exec:…"},{"url":"ffmpeg:obsbot#audio=opus"}],
     "consumers":[{"id":3,"format_name":"preload","medias":[],"senders":[],"bytes_send":0}]}}
    """#.utf8)
}

@Suite("go2rtc : API, coreaudiod et journal", .french)
struct Go2RTCSignalsTests {
    @Test("Clients par type, sans le préchargement ; producteur actif")
    func clients() throws {
        let status = try #require(Go2RTCStreams.status(of: "obsbot", in: StreamsFixtures.active))
        #expect(status.clients == Go2RTCClients(byType: ["rtsp": 2, "webrtc": 1]))
        #expect(status.clients.total == 3)
        #expect(status.hasActiveProducer)
    }

    @Test("Stream sans producteur actif : la caméra est absente ; stream absent ou réponse illisible : nil")
    func noProducer() throws {
        let status = try #require(Go2RTCStreams.status(of: "obsbot", in: StreamsFixtures.noProducer))
        #expect(!status.hasActiveProducer)
        #expect(status.clients.total == 0)
        #expect(Go2RTCStreams.status(of: "autre", in: StreamsFixtures.active) == nil)
        #expect(Go2RTCStreams.status(of: "obsbot", in: Data("pas du json".utf8)) == nil)
    }

    /// pid, ppid, commande : le gardien 500, son go2rtc 501, deux ffmpeg vidéo, un audio, le transcodeur Opus, et un ffmpeg
    /// vidéo d'un autre programme (900).
    static let ps = """
      1     0 /sbin/launchd
    400     1 /Applications/PTZBot.app/Contents/MacOS/PTZBot
    500   400 /Applications/PTZBot.app/Contents/Helpers/gardien --parent 400 --arret 10 -- /Applications/PTZBot.app/Contents/Helpers/go2rtc -config /support/go2rtc.yaml
    501   500 /Applications/PTZBot.app/Contents/Helpers/go2rtc -config /support/go2rtc.yaml
    502   501 /opt/homebrew/bin/ffmpeg -hide_banner -f avfoundation -framerate 30 -i OBSBOT Tiny 2 StreamCamera -an -f rtsp rtsp://127.0.0.1:8554/a
    503   501 /opt/homebrew/bin/ffmpeg -hide_banner -f avfoundation -i :OBSBOT Tiny2 Microphone -vn -f rtsp rtsp://127.0.0.1:8554/b
    504   501 ffmpeg -hide_banner -i rtsp://127.0.0.1:8554/obsbot -c:a libopus -f rtsp rtsp://127.0.0.1:8554/c
    505   501 /opt/homebrew/bin/ffmpeg -hide_banner -f avfoundation -framerate 30 -i OBSBOT Tiny 2 StreamCamera -an -f rtsp rtsp://127.0.0.1:8554/a
    900     1 /usr/local/bin/ffmpeg -f avfoundation -i 0 sortie.mp4
    """

    @Test("coreaudiod : les ffmpeg vidéo comptés sous le gardien seulement ; plus d'un : bloqué")
    func videoFFmpegs() {
        #expect(CoreAudioDetector.videoFFmpegCount(psOutput: Self.ps, root: 500) == 2)
        let healthy = Self.ps.split(separator: "\n").filter { !$0.hasPrefix("505 ") }.joined(separator: "\n")
        #expect(CoreAudioDetector.videoFFmpegCount(psOutput: healthy, root: 500) == 1)
        #expect(CoreAudioDetector.videoFFmpegCount(psOutput: Self.ps, root: 999) == 0)
    }

    @Test("coreaudiod : un ffmpeg vidéo en trop vu une seule fois n'alerte pas (redémarrage d'ffmpeg) ; deux contrôles de suite, si")
    func extraVideoTwiceInARow() {
        var watch = CoreAudioWatch()
        watch.videoCount(2, now: 0)
        #expect(!watch.isStuck(now: 0))
        watch.videoCount(2, now: 2)
        #expect(watch.isStuck(now: 2))
        watch.videoCount(1, now: 4)
        #expect(!watch.isStuck(now: 4))
        watch.videoCount(2, now: 6)
        #expect(!watch.isStuck(now: 6))
        #expect(CoreAudioDetector.repairCommand == "sudo killall -9 coreaudiod")
    }

    @Test("coreaudiod : deux contrôles trop espacés (panneau fermé entre les deux) ne comptent pas « de suite »")
    func extraVideoChecksTooFarApart() {
        var watch = CoreAudioWatch()
        watch.videoCount(2, now: 0)
        watch.videoCount(2, now: CoreAudioDetector.extraVideoMaxGap + 1)
        #expect(!watch.isStuck(now: 100))
        // Le second contrôle ouvre une nouvelle série : un troisième, à cadence normale, alerte.
        watch.videoCount(2, now: CoreAudioDetector.extraVideoMaxGap + 3)
        #expect(watch.isStuck(now: 100))
        // Un arrêt de la surveillance remet le compte à zéro.
        watch.videoCount(0, now: 200)
        watch.videoCount(2, now: 202)
        #expect(!watch.isStuck(now: 202))
    }

    @Test("coreaudiod : un exec: timeout seul n'alerte pas ; il ouvre une suspicion, et la sonde qui répond la lève")
    func timeoutThenProbeResponds() {
        var watch = CoreAudioWatch()
        watch.sawTimeout(at: 100)
        #expect(!watch.isStuck(now: 100))
        #expect(watch.shouldProbe(now: 100))
        let probe = watch.probeStarted(now: 100)
        // Jamais deux sondes en même temps.
        #expect(!watch.shouldProbe(now: 101))
        watch.probeFinished(responds: true, probe: probe)
        #expect(!watch.isStuck(now: 101))
        // Suspicion levée : plus de sonde sans nouveau timeout.
        #expect(!watch.shouldProbe(now: 200))
    }

    /// Deux sondes ratées de suite, à `probeInterval` l'une de l'autre, pendant la même suspicion.
    private func failTwice(_ watch: inout CoreAudioWatch, from start: TimeInterval) {
        let first = watch.probeStarted(now: start)
        watch.probeFinished(responds: false, probe: first)
        let second = watch.probeStarted(now: start + CoreAudioDetector.probeInterval)
        watch.probeFinished(responds: false, probe: second)
    }

    @Test("coreaudiod : exec: timeout et deux sondes ratées de suite : alerte, tant que la suspicion dure (2 min sans nouveau timeout) ; une seule sonde ratée n'alerte pas")
    func timeoutThenProbeFails() {
        var watch = CoreAudioWatch()
        watch.sawTimeout(at: 100)
        let first = watch.probeStarted(now: 100)
        watch.probeFinished(responds: false, probe: first)
        #expect(!watch.isStuck(now: 105))
        // La suspicion dure : une seconde sonde part après `probeInterval`.
        #expect(watch.shouldProbe(now: 100 + CoreAudioDetector.probeInterval))
        let second = watch.probeStarted(now: 100 + CoreAudioDetector.probeInterval)
        watch.probeFinished(responds: false, probe: second)
        #expect(watch.isStuck(now: 100 + CoreAudioDetector.probeInterval + 5))
        #expect(watch.isStuck(now: 100 + CoreAudioDetector.timeoutWindow - 1))
        #expect(!watch.isStuck(now: 100 + CoreAudioDetector.timeoutWindow))
        #expect(!watch.shouldProbe(now: 100 + CoreAudioDetector.timeoutWindow))
    }

    @Test("coreaudiod : une sonde qui répond entre deux ratées remet le compte à zéro, même si la suspicion dure")
    func respondingProbeResetsFailures() {
        var watch = CoreAudioWatch()
        watch.sawTimeout(at: 0)
        let first = watch.probeStarted(now: 0)
        watch.probeFinished(responds: false, probe: first)
        let second = watch.probeStarted(now: 30)
        // Un timeout lu pendant la sonde : la suspicion dure, malgré la réponse.
        watch.sawTimeout(at: 31)
        watch.probeFinished(responds: true, probe: second)
        let third = watch.probeStarted(now: 60)
        watch.probeFinished(responds: false, probe: third)
        #expect(!watch.isStuck(now: 61))
    }

    @Test("coreaudiod : une sonde ratée d'une suspicion passée ne survit pas : un nouveau timeout ne montre l'alerte qu'après deux sondes ratées")
    func failuresDoNotSurviveSuspicion() {
        var watch = CoreAudioWatch()
        watch.sawTimeout(at: 100)
        failTwice(&watch, from: 100)
        #expect(watch.isStuck(now: 140))
        // L'utilisateur répare, les timeouts cessent, la suspicion s'éteint.
        #expect(!watch.isStuck(now: 100 + CoreAudioDetector.timeoutWindow))
        // Une veille plus tard : un nouveau timeout ouvre une autre suspicion, sans alerte avant le verdict des sondes.
        watch.sawTimeout(at: 1000)
        #expect(!watch.isStuck(now: 1000))
        let probe = watch.probeStarted(now: 1000)
        #expect(!watch.isStuck(now: 1001))
        watch.probeFinished(responds: false, probe: probe)
        #expect(!watch.isStuck(now: 1002))
    }

    @Test("coreaudiod : la réponse d'une sonde lancée avant reset() est ignorée")
    func probeBeforeResetIsIgnored() {
        var watch = CoreAudioWatch()
        watch.sawTimeout(at: 0)
        let first = watch.probeStarted(now: 0)
        watch.probeFinished(responds: false, probe: first)
        let stale = watch.probeStarted(now: CoreAudioDetector.probeInterval)
        // Un nouveau go2rtc, un nouveau timeout, et sa propre sonde.
        watch.reset()
        watch.sawTimeout(at: 40)
        #expect(!watch.isStuck(now: 40))
        watch.probeFinished(responds: false, probe: stale)
        #expect(!watch.isStuck(now: 41))
        let fresh = watch.probeStarted(now: 70)
        // La sonde périmée répond enfin, alors que la nouvelle tourne : ignorée, ce n'est plus la sonde en cours.
        watch.probeFinished(responds: true, probe: stale)
        watch.probeFinished(responds: false, probe: fresh)
        // Une seule sonde ratée dans la nouvelle série (pas d'alerte), et la suspicion du nouveau timeout reste ouverte.
        #expect(!watch.isStuck(now: 71))
        #expect(watch.shouldProbe(now: 70 + CoreAudioDetector.probeInterval))
    }

    @Test("coreaudiod : au plus une sonde toutes les 30 s ; une sonde qui répond ne lève pas un timeout vu pendant qu'elle tournait")
    func probeCadence() {
        var watch = CoreAudioWatch()
        watch.sawTimeout(at: 0)
        let probe = watch.probeStarted(now: 0)
        watch.sawTimeout(at: 1)
        watch.probeFinished(responds: true, probe: probe)
        #expect(!watch.isStuck(now: 2))
        #expect(!watch.shouldProbe(now: 10))
        #expect(!watch.shouldProbe(now: CoreAudioDetector.probeInterval - 1))
        #expect(watch.shouldProbe(now: CoreAudioDetector.probeInterval))
        // Un nouveau go2rtc efface tout.
        watch.reset()
        #expect(!watch.shouldProbe(now: 100))
    }

    @Test("Journal : exec: timeout et refus d'accès d'avfoundation reconnus ; le reste ignoré")
    func logPatterns() {
        #expect(Go2RTCLogPatterns.scan("12:00:01.000 ERR [exec] timeout source=exec:…\n") == Go2RTCLogScan(sawTimeout: true))
        #expect(Go2RTCLogPatterns.scan(#"WRN [streams] error="exec: timeout""#) == Go2RTCLogScan(sawTimeout: true))
        let denied = #"WRN [streams] error="exec/rtsp\n[avfoundation @ 0x1] Failed to create AV capture input device: Cannot use OBSBOT""#
        #expect(Go2RTCLogPatterns.scan(denied) == Go2RTCLogScan(sawAccessDenied: true))
        #expect(Go2RTCLogPatterns.scan("ERR [rtsp] wrong user/pass denied") == Go2RTCLogScan())
        #expect(Go2RTCLogPatterns.scan("INF [api] listen addr=127.0.0.1:1984\n") == Go2RTCLogScan())
    }

    @Test("Lecteur du journal : seulement la suite ; au plus les derniers octets ; journal raccourci relu du début")
    func logReader() throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "go2rtc.log")
        try Data("ancien\n".utf8).write(to: url)
        var reader = Go2RTCLogReader(url: url, offset: 7)
        #expect(reader.readNew() == "")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("nouveau\n".utf8))
        try handle.close()
        #expect(reader.readNew() == "nouveau\n")
        #expect(reader.readNew() == "")
        try Data("court\n".utf8).write(to: url)
        #expect(reader.readNew() == "court\n")
        try Data("0123456789".utf8).write(to: url)
        reader.reset(to: 0)
        #expect(reader.readNew(maxBytes: 4) == "6789")
        #expect(Go2RTCLogReader(url: directory.appending(path: "absent.log")).offset == 0)
    }
}

@MainActor
@Suite("go2rtc : surveillance pour le panneau", .french, .timeLimit(.minutes(1)))
struct Go2RTCMonitorTests {
    let launcher = FakeLauncher()
    let settings = FakeSettings()
    let scheduler = FakeScheduler()
    let api = FakeGo2RTCAPI()
    let processes = FakeProcessListing()
    let probe = FakeCoreAudioProbe()

    /// Un go2rtc qui tourne (gardien simulé de pid 1000), son journal dans `directory`.
    private func running(_ directory: URL) async -> (Go2RTCSupervisor, Go2RTCMonitor, URL) {
        let log = directory.appending(path: "go2rtc.log")
        settings.values[Go2RTCSupervisor.enabledKey] = true
        let supervisor = Go2RTCSupervisor(
            paths: Go2RTCSupervisor.Paths(gardien: URL(fileURLWithPath: "/app/gardien"), go2rtc: URL(fileURLWithPath: "/app/go2rtc"), log: log),
            launcher: launcher, preparer: FakePreparer(), settings: settings, scheduler: scheduler, parentPID: 4242,
            configuration: Go2RTCFixtures.settings()
        )
        supervisor.start()
        await supervisor.waitForPreparation()
        let monitor = Go2RTCMonitor(supervisor: supervisor, api: api, processes: processes, probe: probe, logURL: log, scheduler: scheduler)
        return (supervisor, monitor, log)
    }

    /// Attend qu'une condition devienne vraie (une sonde tourne sur un autre fil), 2 s au plus.
    private func eventuallyTrue(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test("Panneau ouvert : clients et producteur lus dans l'API ; un seul ffmpeg vidéo : pas d'alerte")
    func clients() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, _) = await running(directory)
        api.body = StreamsFixtures.active
        processes.output = "1000 1 gardien\n1001 1000 go2rtc\n1002 1001 /opt/homebrew/bin/ffmpeg -f avfoundation -i Cam -an\n"
        monitor.beginWatching()
        await monitor.waitForPoll()
        #expect(monitor.stream?.clients.total == 3)
        #expect(monitor.health == Go2RTCHealth())
    }

    @Test("Deux ffmpeg vidéo à deux contrôles de suite : coreaudiod bloqué ; à un seul, non ; caméra sans producteur : absente")
    func alerts() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, _) = await running(directory)
        api.body = StreamsFixtures.noProducer
        processes.output = "1000 1 g\n1001 1000 go2rtc\n1002 1001 ffmpeg -f avfoundation -an\n1003 1001 ffmpeg -f avfoundation -an\n"
        await monitor.refresh()
        // Un chevauchement passager pendant un redémarrage d'ffmpeg (au réveil) : pas encore d'alerte.
        #expect(monitor.health == Go2RTCHealth(cameraMissing: true))
        await monitor.refresh()
        #expect(monitor.health == Go2RTCHealth(coreAudioStuck: true, cameraMissing: true))
        #expect(probe.calls == 0)
    }

    @Test("Journal : un refus d'accès écrit après le lancement est vu ; avant, non ; un nouveau go2rtc l'efface")
    func accessDenied() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "go2rtc.log")
        try append("[avfoundation] not authorized (exec, avant le lancement)\n", to: log)
        let (supervisor, monitor, _) = await running(directory)
        monitor.scanLog()
        #expect(!monitor.health.accessDenied)
        try append(#"WRN error="exec/rtsp [avfoundation @ 0x1] Failed to create AV capture input device""# + "\n", to: log)
        monitor.scanLog()
        #expect(monitor.health.accessDenied)
        supervisor.restart()
        await supervisor.waitForPreparation()
        monitor.scanLog()
        #expect(!monitor.health.accessDenied)
    }

    @Test("exec: timeout, deux sondes expirées de suite : alerte coreaudiod, puis plus rien 2 min après ; relu toutes les 10 s sans panneau")
    func timeout() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, log) = await running(directory)
        probe.responds = false
        monitor.start()
        try append("ERR [exec] timeout source=exec:…\n", to: log)
        scheduler.advance(by: Go2RTCMonitor.logScanInterval)
        await monitor.waitForProbe()
        #expect(probe.calls == 1)
        // Une seule sonde ratée (une veille lente, des appareils qui se réénumèrent) : pas d'alerte.
        #expect(!monitor.health.coreAudioStuck)
        for _ in 0..<3 {
            scheduler.advance(by: Go2RTCMonitor.logScanInterval)
        }
        await monitor.waitForProbe()
        #expect(probe.calls == 2)
        #expect(monitor.health.coreAudioStuck)
        scheduler.advance(by: CoreAudioDetector.timeoutWindow)
        #expect(!monitor.health.coreAudioStuck)
    }

    @Test("exec: timeout après la veille (caméra sortie du bus USB), coreaudiod qui répond : pas d'alerte")
    func timeoutWithHealthyCoreAudio() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, log) = await running(directory)
        monitor.start()
        try append("12:00:16.000 ERR [exec] timeout source=exec:ffmpeg -f avfoundation -i :Micro\n", to: log)
        scheduler.advance(by: Go2RTCMonitor.logScanInterval)
        #expect(!monitor.health.coreAudioStuck)
        await monitor.waitForProbe()
        #expect(probe.calls == 1)
        #expect(!monitor.health.coreAudioStuck)
        scheduler.advance(by: Go2RTCMonitor.logScanInterval * 3)
        await monitor.waitForProbe()
        #expect(!monitor.health.coreAudioStuck)
        #expect(probe.calls == 1)
    }

    @Test("Cadence des sondes : des timeouts toutes les 10 s, au plus une sonde toutes les 30 s, jamais deux en même temps")
    func probeCadence() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, log) = await running(directory)
        probe.responds = false
        monitor.start()
        for _ in 0..<12 {
            try append("ERR [exec] timeout source=exec:…\n", to: log)
            scheduler.advance(by: Go2RTCMonitor.logScanInterval)
            await monitor.waitForProbe()
        }
        // 120 s de timeouts : une sonde à 10, 40, 70 et 100 s, jamais deux ensemble ; deux ratées de suite : l'alerte.
        #expect(probe.calls == 4)
        #expect(probe.maxRunning == 1)
        #expect(monitor.health.coreAudioStuck)
    }

    @Test("Sonde sans réponse au bout de la garde : comptée ratée, une nouvelle sonde reste possible ; sa réponse tardive est ignorée")
    func probeGuard() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, log) = await running(directory)
        probe.responds = true
        probe.block()
        monitor.start()
        // t = 10 : la première sonde part, et reste bloquée (même la SIGKILL du processus enfant ne la libère pas).
        try append("ERR [exec] timeout source=exec:…\n", to: log)
        scheduler.advance(by: Go2RTCMonitor.logScanInterval)
        #expect(await eventuallyTrue { probe.calls == 1 })
        // Avant la garde : rien.
        scheduler.advance(by: CoreAudioDetector.probeGuard - 1)
        #expect(!monitor.health.coreAudioStuck)
        // La garde passe (t = 20) : la sonde compte pour ratée ; une seule : pas d'alerte.
        scheduler.advance(by: 1)
        #expect(!monitor.health.coreAudioStuck)
        // La suspicion dure (un timeout toutes les 10 s) ; 30 s après la première, une nouvelle sonde part malgré la
        // première, toujours bloquée.
        for _ in 0..<2 {
            try append("ERR [exec] timeout source=exec:…\n", to: log)
            scheduler.advance(by: Go2RTCMonitor.logScanInterval)
        }
        #expect(await eventuallyTrue { probe.calls == 2 })
        // Sa garde passe à son tour : deux sondes ratées de suite, l'alerte.
        scheduler.advance(by: CoreAudioDetector.probeGuard)
        #expect(monitor.health.coreAudioStuck)
        // Les réponses tardives (elles répondent !) sont ignorées : l'alerte tient.
        probe.releaseAll()
        #expect(await eventuallyTrue { probe.running == 0 })
        await monitor.waitForProbe()
        #expect(monitor.health.coreAudioStuck)
    }

    @Test("Deux contrôles de ffmpeg vidéo séparés par la fermeture du panneau ne comptent pas « de suite »")
    func panelClosedBetweenVideoChecks() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, _) = await running(directory)
        api.body = StreamsFixtures.active
        processes.output = "1000 1 g\n1001 1000 go2rtc\n1002 1001 ffmpeg -f avfoundation -an\n1003 1001 ffmpeg -f avfoundation -an\n"
        monitor.beginWatching()
        await monitor.waitForPoll()
        #expect(!monitor.health.coreAudioStuck)
        monitor.endWatching()
        // Le panneau reste fermé plus de deux minutes, puis se rouvre : le premier contrôle repart de zéro.
        scheduler.advance(by: 150)
        monitor.beginWatching()
        await monitor.waitForPoll()
        #expect(!monitor.health.coreAudioStuck)
        scheduler.advance(by: Go2RTCMonitor.pollInterval)
        await monitor.waitForPoll()
        #expect(monitor.health.coreAudioStuck)
    }

    @Test("Panneau fermé : plus de lecture de l'API ; go2rtc arrêté : ni clients ni alerte")
    func endWatching() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (supervisor, monitor, _) = await running(directory)
        api.body = StreamsFixtures.active
        monitor.beginWatching()
        await monitor.waitForPoll()
        #expect(api.calls == 1)
        scheduler.advance(by: Go2RTCMonitor.pollInterval)
        await monitor.waitForPoll()
        #expect(api.calls == 2)
        monitor.endWatching()
        scheduler.advance(by: Go2RTCMonitor.pollInterval * 3)
        await monitor.waitForPoll()
        #expect(api.calls == 2)
        supervisor.stop()
        await monitor.refresh()
        #expect(monitor.stream == nil)
        #expect(monitor.health == Go2RTCHealth())
    }
}
