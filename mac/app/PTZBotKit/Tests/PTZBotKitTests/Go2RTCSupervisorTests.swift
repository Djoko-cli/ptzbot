import Foundation
import Testing
@testable import PTZBotKit

/// Ce qui n'a rien à arrêter avant une veille du Mac : go2rtc ne tourne pas.
enum NothingToStop: CaseIterable, Sendable, CustomTestStringConvertible {
    case stopped
    case switchedOff
    case failed

    var testDescription: String {
        switch self {
        case .stopped: "arrêté"
        case .switchedOff: "interrupteur éteint"
        case .failed: "en échec"
        }
    }
}

@MainActor
@Suite("Supervision de go2rtc", .french, .timeLimit(.minutes(1)))
struct Go2RTCSupervisorTests {
    let launcher = FakeLauncher()
    let settings = FakeSettings()
    let scheduler = FakeScheduler()
    let preparer = FakePreparer()
    let paths = Go2RTCSupervisor.Paths(
        gardien: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/gardien"),
        go2rtc: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/go2rtc"),
        log: URL(fileURLWithPath: "/logs/go2rtc.log")
    )

    private func makeSupervisor(enabled: Bool = true, log: URL? = nil) -> Go2RTCSupervisor {
        if enabled {
            settings.values[Go2RTCSupervisor.enabledKey] = true
        }
        var paths = paths
        if let log {
            paths.log = log
        }
        return Go2RTCSupervisor(paths: paths, launcher: launcher, preparer: preparer, settings: settings, scheduler: scheduler,
                                parentPID: 4242, configuration: Go2RTCFixtures.settings())
    }

    /// `start()`, puis la préparation attendue.
    private func started(_ supervisor: Go2RTCSupervisor) async {
        supervisor.start()
        await supervisor.waitForPreparation()
    }

    @Test("Éteint par défaut : ni préparation ni lancement")
    func offByDefault() async {
        let supervisor = makeSupervisor(enabled: false)
        #expect(!supervisor.isEnabled)
        await started(supervisor)
        #expect(supervisor.state == .stopped)
        #expect(preparer.prepared.isEmpty)
        #expect(launcher.launched.isEmpty)
    }

    @Test("Allumé : préparation hors du fil principal, puis le gardien : --parent, --arret 10, go2rtc -config, PATH de ffmpeg, journal")
    func launch() async throws {
        let supervisor = makeSupervisor(enabled: false)
        supervisor.setEnabled(true)
        #expect(supervisor.state == .starting)
        #expect(settings.values[Go2RTCSupervisor.enabledKey] == true)
        await supervisor.waitForPreparation()
        #expect(supervisor.state == .running)
        #expect(preparer.prepared == [Go2RTCFixtures.settings()])
        #expect(preparer.onMainThread == [false])
        #expect(launcher.executables == [paths.gardien])
        let process = try #require(launcher.last)
        #expect(process.arguments == [
            "--parent", "4242", "--arret", "10", "--rtsp", "8554", "--capture", FakePreparer.fingerprints[0], "--capture", FakePreparer.fingerprints[1],
            "--", paths.go2rtc.path, "-config", "/support/go2rtc.yaml",
        ])
        #expect(launcher.environments == [["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]])
        #expect(process.outputURL == paths.log)
        #expect(supervisor.gardienPID == process.pid)
        #expect(supervisor.launchCount == 1)
        #expect(!supervisor.usesCustomFile)
        supervisor.start()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1)
    }

    @Test("Gardien déjà sorti avant qu'on ait vu son PID (PID 0) : pas de PID de gardien, qui désignerait tous les processus")
    func gardienPIDZero() async throws {
        launcher.pidOverride = 0
        let supervisor = makeSupervisor()
        await started(supervisor)
        #expect(supervisor.state == .running)
        #expect(supervisor.gardienPID == nil)
        supervisor.stop {}
    }

    @Test("Préparation bloquée (ffmpeg introuvable) : échec avec la raison, sans lancement ni relance")
    func blocked() async {
        preparer.result = .blocked(.ffmpegMissing)
        let supervisor = makeSupervisor()
        await started(supervisor)
        #expect(supervisor.state == .failed(.blocked(.ffmpegMissing)))
        scheduler.advance(by: 60)
        #expect(launcher.launched.isEmpty)
        #expect(preparer.prepared.count == 1)
    }

    @Test("Caméra puis micro absents au lancement (réveil, ouverture de session) : nouveaux essais toutes les 2 s ; ils reviennent, go2rtc part")
    func devicesMissingThenBack() async throws {
        #expect(Go2RTCSupervisor.deviceRetryDelay == 2)
        #expect(Go2RTCSupervisor.deviceRetries == 15)
        preparer.queued = [.blocked(.cameraMissing), .blocked(.cameraMissing), .blocked(.microphoneMissing)]
        let supervisor = makeSupervisor()
        await started(supervisor)
        #expect(supervisor.state == .starting, "l'absence n'est pas annoncée tout de suite")
        #expect(preparer.prepared.count == 1)
        scheduler.advance(by: 1.9)
        #expect(preparer.prepared.count == 1)
        scheduler.advance(by: 0.1)
        await supervisor.waitForPreparation()
        #expect(preparer.prepared.count == 2)
        #expect(supervisor.state == .starting)
        scheduler.advance(by: 2)
        await supervisor.waitForPreparation()
        scheduler.advance(by: 2)
        await supervisor.waitForPreparation()
        #expect(preparer.prepared.count == 4)
        #expect(supervisor.state == .running)
        #expect(launcher.launched.count == 1)
    }

    @Test("Caméra ou micro qui reste absent : échec « absente » après 15 essais de plus (30 s), sans relance ; l'interrupteur réessaie",
          arguments: [Go2RTCBlock.cameraMissing, .microphoneMissing])
    func deviceStaysMissing(_ block: Go2RTCBlock) async throws {
        preparer.result = .blocked(block)
        let supervisor = makeSupervisor()
        await started(supervisor)
        for _ in 0 ..< Go2RTCSupervisor.deviceRetries {
            #expect(supervisor.state == .starting)
            scheduler.advance(by: Go2RTCSupervisor.deviceRetryDelay)
            await supervisor.waitForPreparation()
        }
        #expect(supervisor.state == .failed(.blocked(block)))
        #expect(preparer.prepared.count == Go2RTCSupervisor.deviceRetries + 1)
        scheduler.advance(by: 60)
        #expect(preparer.prepared.count == Go2RTCSupervisor.deviceRetries + 1)
        #expect(launcher.launched.isEmpty)
        preparer.result = .ready(FakePreparer.readyLaunch)
        supervisor.setEnabled(false)
        supervisor.setEnabled(true)
        await supervisor.waitForPreparation()
        #expect(supervisor.state == .running)
    }

    @Test("Port pris puis caméra absente : chaque attente a son propre compte d'essais")
    func portThenDeviceRetries() async throws {
        preparer.queued = Array(repeating: .blocked(.portBusy(8554)), count: Go2RTCSupervisor.portRetries)
            + Array(repeating: .blocked(.cameraMissing), count: Go2RTCSupervisor.deviceRetries)
        let supervisor = makeSupervisor()
        await started(supervisor)
        for _ in 0 ..< Go2RTCSupervisor.portRetries {
            scheduler.advance(by: Go2RTCSupervisor.portRetryDelay)
            await supervisor.waitForPreparation()
        }
        for _ in 0 ..< Go2RTCSupervisor.deviceRetries - 1 {
            #expect(supervisor.state == .starting)
            scheduler.advance(by: Go2RTCSupervisor.deviceRetryDelay)
            await supervisor.waitForPreparation()
        }
        scheduler.advance(by: Go2RTCSupervisor.deviceRetryDelay)
        await supervisor.waitForPreparation()
        #expect(supervisor.state == .running)
        #expect(launcher.launched.count == 1)
    }

    @Test("Port pris au lancement : nouveaux essais toutes les secondes, pendant 5 s ; le port se libère, go2rtc part")
    func portBusyThenFree() async throws {
        #expect(Go2RTCSupervisor.portRetryDelay == 1)
        #expect(Go2RTCSupervisor.portRetries == 5)
        preparer.queued = [.blocked(.portBusy(8554)), .blocked(.portBusy(8554)), .blocked(.portBusy(1984))]
        let supervisor = makeSupervisor()
        await started(supervisor)
        #expect(supervisor.state == .starting, "l'échec n'est pas annoncé tout de suite")
        #expect(preparer.prepared.count == 1)
        scheduler.advance(by: 0.9)
        #expect(preparer.prepared.count == 1)
        scheduler.advance(by: 0.1)
        await supervisor.waitForPreparation()
        #expect(preparer.prepared.count == 2)
        #expect(supervisor.state == .starting)
        scheduler.advance(by: 1)
        await supervisor.waitForPreparation()
        scheduler.advance(by: 1)
        await supervisor.waitForPreparation()
        #expect(preparer.prepared.count == 4)
        #expect(supervisor.state == .running)
        #expect(launcher.launched.count == 1)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Port qui reste pris : échec « port déjà utilisé » après 5 essais de plus, sans relance ; Appliquer ou l'interrupteur réessaient")
    func portStaysBusy() async throws {
        preparer.result = .blocked(.portBusy(8554))
        let supervisor = makeSupervisor()
        await started(supervisor)
        for _ in 0 ..< Go2RTCSupervisor.portRetries {
            #expect(supervisor.state == .starting)
            scheduler.advance(by: 1)
            await supervisor.waitForPreparation()
        }
        #expect(supervisor.state == .failed(.blocked(.portBusy(8554))))
        #expect(preparer.prepared.count == 6)
        scheduler.advance(by: 60)
        #expect(preparer.prepared.count == 6)
        #expect(launcher.launched.isEmpty)
        // Une relance ultérieure reste possible, avec de nouveaux essais.
        preparer.result = .ready(FakePreparer.readyLaunch)
        supervisor.setEnabled(false)
        supervisor.setEnabled(true)
        await supervisor.waitForPreparation()
        #expect(supervisor.state == .running)
    }

    @Test("Arrêt pendant les essais (port pris, caméra absente) : plus aucun essai, rien n'est lancé",
          arguments: [Go2RTCBlock.portBusy(8554), .cameraMissing])
    func stopDuringRetries(_ block: Go2RTCBlock) async {
        preparer.result = .blocked(block)
        let supervisor = makeSupervisor()
        await started(supervisor)
        preparer.result = .ready(FakePreparer.readyLaunch)
        var done = 0
        supervisor.stop { done += 1 }
        #expect(done == 1)
        scheduler.advance(by: 60)
        await supervisor.waitForPreparation()
        #expect(supervisor.state == .stopped)
        #expect(preparer.prepared.count == 1)
        #expect(launcher.launched.isEmpty)
    }

    @Test("Arrêt : SIGTERM au gardien ; stopped et completion à sa fin ; pas de relance")
    func stop() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        let process = try #require(launcher.last)
        var done = 0
        supervisor.stop { done += 1 }
        #expect(process.terminations == 1)
        #expect(supervisor.state == .stopped)
        #expect(supervisor.gardienPID == nil)
        #expect(done == 1)
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
        #expect(process.kills == 0)
    }

    @Test("Arrêt en douceur : le gardien laisse 10 s à go2rtc, puis 5 s aux ffmpeg ; SIGKILL au gardien seulement à 16 s")
    func gentleStop() async throws {
        #expect(Go2RTCSupervisor.stopDelay >= 10)
        #expect(Go2RTCSupervisor.killDelay == 16)
        // Le pire cas du gardien (`--arret`, puis l'attente des ffmpeg, `Gardien.orphanWait` = 5 s) reste sous `killDelay`.
        #expect(Go2RTCSupervisor.killDelay > Go2RTCSupervisor.stopDelay + Go2RTCSupervisor.gardienOrphanWait)
        let supervisor = makeSupervisor()
        await started(supervisor)
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        var done = 0
        supervisor.stop { done += 1 }
        scheduler.advance(by: Go2RTCSupervisor.stopDelay)
        #expect(process.kills == 0)
        scheduler.advance(by: Go2RTCSupervisor.killDelay - Go2RTCSupervisor.stopDelay - 0.1)
        #expect(process.kills == 0)
        #expect(done == 0)
        #expect(supervisor.state == .running)
        scheduler.advance(by: 0.1)
        #expect(process.kills == 1)
        #expect(done == 1)
        #expect(supervisor.state == .stopped)
    }

    @Test("Gardien qui ne sort pas même après SIGKILL : arrêt abandonné, échec, completion")
    func unkillable() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        process.ignoresKill = true
        var done = 0
        supervisor.stop { done += 1 }
        scheduler.advance(by: Go2RTCSupervisor.killDelay * 2)
        #expect(done == 1)
        #expect(supervisor.state == .failed(.unkillable))
    }

    @Test("Arrêts inattendus : relances après 1, 2, 4, 8 et 16 s ; au-delà de 5 en 120 s, échec sans relance")
    func crashLoop() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        for (index, delay) in [1.0, 2, 4, 8, 16].enumerated() {
            try #require(launcher.last).exit()
            #expect(supervisor.state == .restarting(count: index + 1))
            scheduler.advance(by: delay - 0.1)
            #expect(launcher.launched.count == index + 1)
            scheduler.advance(by: 0.1)
            await supervisor.waitForPreparation()
            #expect(launcher.launched.count == index + 2)
            #expect(supervisor.state == .running)
        }
        try #require(launcher.last).exit()
        #expect(supervisor.state == .failed(.crashLoop))
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 6)
    }

    @Test("Un go2rtc qui a tenu 120 s repart du premier délai")
    func stableResetsDelays() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        try #require(launcher.last).exit()
        scheduler.advance(by: 1)
        await supervisor.waitForPreparation()
        scheduler.advance(by: Go2RTCSupervisor.failureWindow)
        try #require(launcher.last).exit()
        #expect(supervisor.state == .restarting(count: 1))
    }

    @Test("go2rtc absent de l'app (le gardien sort avec 127) : échec sans relance")
    func missingBinary() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        try #require(launcher.last).exit(ProcessExit(status: 127, signaled: false))
        #expect(supervisor.state == .failed(.missingBinary))
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
    }

    @Test("Éteint pendant la préparation : rien n'est lancé ; rallumé pendant l'arrêt : une seule relance, à la fin")
    func toggles() async throws {
        preparer.holds = true
        let supervisor = makeSupervisor()
        supervisor.start()
        let held = await waitUntil { preparer.isHeld }
        try #require(held)
        supervisor.setEnabled(false)
        #expect(supervisor.state == .stopped)
        preparer.release()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.isEmpty)
        #expect(supervisor.state == .stopped)

        supervisor.setEnabled(true)
        await supervisor.waitForPreparation()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        supervisor.setEnabled(false)
        supervisor.setEnabled(true)
        supervisor.setEnabled(true)
        #expect(launcher.launched.count == 1)
        process.exit(ProcessExit(status: SIGTERM, signaled: true))
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
        #expect(supervisor.state == .running)
    }

    @Test("Appliquer : arrêt en douceur, puis relance avec les nouveaux réglages ; éteint, rien")
    func restart() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        var changed = Go2RTCFixtures.settings()
        changed.framerate = 25
        supervisor.configuration = changed
        supervisor.restart()
        #expect(try #require(launcher.launched.first).terminations == 1)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
        #expect(preparer.prepared.last == changed)
        supervisor.setEnabled(false)
        supervisor.restart()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
    }

    @Test("Quitter : plus de relance ni de lancement, même interrupteur rallumé")
    func quit() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        var done = 0
        supervisor.stop(forQuit: true) { done += 1 }
        #expect(done == 1)
        supervisor.setEnabled(true)
        supervisor.start()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1)
    }

    // MARK: - Pause de veille (spec B3 § 15)

    @Test("Veille : arrêt en douceur, completion à la sortie du gardien ; en pause, start(), restart() et setEnabled(true) ne lancent rien ; la reprise relance")
    func pauseForSleep() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        var done = 0
        supervisor.pauseForSleep { done += 1 }
        #expect(supervisor.isPausedForSleep)
        #expect(process.terminations == 1)
        #expect(done == 0)
        #expect(supervisor.state == .running, "jusqu'à la sortie du gardien")
        process.exit(ProcessExit(status: SIGTERM, signaled: true))
        #expect(done == 1)
        #expect(supervisor.state == .stopped)
        #expect(supervisor.gardienPID == nil)
        #expect(process.kills == 0)

        supervisor.start()
        supervisor.restart()
        supervisor.setEnabled(true)
        await supervisor.waitForPreparation()
        scheduler.advance(by: 60)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1)
        #expect(supervisor.state == .stopped)
        #expect(supervisor.isEnabled)
        #expect(supervisor.isPausedForSleep)

        supervisor.resumeAfterSleep()
        #expect(!supervisor.isPausedForSleep)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
        #expect(supervisor.state == .running)
        // Hors d'une pause, la reprise ne fait rien.
        supervisor.resumeAfterSleep()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
    }

    @Test("Veille sans rien à arrêter (arrêté, interrupteur éteint, en échec) : completion tout de suite, pas de pause, état inchangé",
          arguments: NothingToStop.allCases)
    func pauseForSleepNothingToStop(_ situation: NothingToStop) async {
        let supervisor = makeSupervisor(enabled: situation != .switchedOff)
        if situation == .failed {
            preparer.result = .blocked(.ffmpegMissing)
            await started(supervisor)
        }
        let state = supervisor.state
        var done = 0
        supervisor.pauseForSleep { done += 1 }
        #expect(done == 1)
        #expect(!supervisor.isPausedForSleep)
        #expect(supervisor.state == state)
        // Sans pause, la reprise ne relance rien : un échec reste un échec.
        preparer.result = .ready(FakePreparer.readyLaunch)
        supervisor.resumeAfterSleep()
        await supervisor.waitForPreparation()
        #expect(supervisor.state == state)
        #expect(launcher.launched.isEmpty)
    }

    @Test("Veille pendant une relance programmée : relance annulée, completion tout de suite, en pause ; la reprise relance")
    func pauseForSleepWhileRestarting() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        try #require(launcher.last).exit()
        #expect(supervisor.state == .restarting(count: 1))
        var done = 0
        supervisor.pauseForSleep { done += 1 }
        #expect(done == 1)
        #expect(supervisor.isPausedForSleep)
        #expect(supervisor.state == .stopped)
        scheduler.advance(by: 60)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1, "la relance programmée est annulée")
        supervisor.resumeAfterSleep()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
        #expect(supervisor.state == .running)
    }

    @Test("Veille pendant la préparation : rien ne sera lancé, completion tout de suite ; la reprise relance")
    func pauseForSleepWhilePreparing() async throws {
        preparer.holds = true
        let supervisor = makeSupervisor()
        supervisor.start()
        let held = await waitUntil { preparer.isHeld }
        try #require(held)
        var done = 0
        supervisor.pauseForSleep { done += 1 }
        #expect(done == 1)
        #expect(supervisor.state == .stopped)
        #expect(supervisor.isPausedForSleep)
        preparer.release()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.isEmpty, "la préparation abandonnée ne lance rien")
        supervisor.resumeAfterSleep()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1)
        #expect(supervisor.state == .running)
    }

    @Test("Veille pendant un arrêt déjà en cours : même sortie, un seul SIGTERM, une completion par demande")
    func pauseForSleepDuringStop() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        var stopped = 0
        var paused = 0
        supervisor.stop { stopped += 1 }
        supervisor.pauseForSleep { paused += 1 }
        supervisor.pauseForSleep { paused += 1 }
        #expect(process.terminations == 1)
        #expect(stopped == 0 && paused == 0)
        process.exit(ProcessExit(status: SIGTERM, signaled: true))
        #expect(stopped == 1 && paused == 2)
        #expect(supervisor.state == .stopped)
        #expect(supervisor.isPausedForSleep)
    }

    @Test("Pendant la pause : « Appliquer » met les réglages de côté, la reprise les utilise ; interrupteur éteint, la reprise ne lance rien")
    func pauseSettingsAndSwitch() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        supervisor.pauseForSleep {}
        var changed = Go2RTCFixtures.settings()
        changed.framerate = 25
        supervisor.configuration = changed
        supervisor.restart()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1)
        supervisor.resumeAfterSleep()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
        #expect(preparer.prepared.last == changed)

        supervisor.pauseForSleep {}
        supervisor.setEnabled(false)
        #expect(supervisor.state == .stopped)
        supervisor.resumeAfterSleep()
        await supervisor.waitForPreparation()
        #expect(!supervisor.isPausedForSleep)
        #expect(supervisor.state == .stopped)
        #expect(launcher.launched.count == 2)
    }

    @Test("Reprise pendant que l'arrêt dure encore : go2rtc est relancé à la sortie du gardien, pas avant ; rallumer l'interrupteur entre-temps n'y change rien")
    func resumeDuringStop() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        var done = 0
        supervisor.pauseForSleep { done += 1 }
        supervisor.setEnabled(true)
        supervisor.resumeAfterSleep()
        #expect(!supervisor.isPausedForSleep)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1)
        #expect(done == 0)
        process.exit(ProcessExit(status: SIGTERM, signaled: true))
        #expect(done == 1)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
        #expect(supervisor.state == .running)
    }

    @Test("Quitter pendant la pause, ou pendant l'arrêt de la veille : rien ne repart à la reprise ; quitter avant la veille : pas de pause")
    func quitAndPause() async throws {
        // Pendant la pause.
        let supervisor = makeSupervisor()
        await started(supervisor)
        supervisor.pauseForSleep {}
        var done = 0
        supervisor.stop(forQuit: true) { done += 1 }
        #expect(done == 1)
        supervisor.resumeAfterSleep()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1)
        #expect(supervisor.state == .stopped)

        // Pendant l'arrêt de la veille : le gardien qui sort tard ne fait rien repartir.
        let other = makeSupervisor()
        other.start()
        await other.waitForPreparation()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        other.pauseForSleep {}
        other.stop(forQuit: true)
        other.resumeAfterSleep()
        process.exit(ProcessExit(status: SIGTERM, signaled: true))
        await other.waitForPreparation()
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 2)
        #expect(other.state == .stopped)

        // Avant la veille : l'app se termine, la veille n'attend rien.
        let last = makeSupervisor()
        last.start()
        await last.waitForPreparation()
        let leaving = try #require(launcher.last)
        leaving.ignoresTerminate = true
        last.stop(forQuit: true)
        var acknowledged = 0
        last.pauseForSleep { acknowledged += 1 }
        #expect(acknowledged == 1)
        #expect(!last.isPausedForSleep)
        #expect(leaving.terminations == 1)
    }

    @Test("Fichier personnalisé : lancé sur ce fichier, et l'état le sait ; --rtsp sans --capture (pas de ménage des orphelins)")
    func customFile() async throws {
        preparer.result = .ready(Go2RTCLaunch(config: URL(fileURLWithPath: "/perso/go2rtc.yaml"), ffmpegDirectory: nil, custom: true, rtspPort: 8554))
        let supervisor = makeSupervisor()
        await started(supervisor)
        #expect(supervisor.usesCustomFile)
        #expect(try #require(launcher.last).arguments == ["--parent", "4242", "--arret", "10", "--rtsp", "8554", "--", paths.go2rtc.path, "-config", "/perso/go2rtc.yaml"])
        // Sans port connu, ni --rtsp ni --capture : pas de ménage du tout.
        #expect(supervisor.arguments(for: Go2RTCLaunch(config: URL(fileURLWithPath: "/perso/go2rtc.yaml"), ffmpegDirectory: nil, custom: true))
            == ["--parent", "4242", "--arret", "10", "--", paths.go2rtc.path, "-config", "/perso/go2rtc.yaml"])
        #expect(launcher.environments == [["PATH": "/usr/bin:/bin"]])
    }

    @Test("Le journal : sa taille au lancement est retenue, pour n'en lire que la suite")
    func logOffset() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "go2rtc.log")
        try Data("ancien journal\n".utf8).write(to: log)
        let supervisor = makeSupervisor(log: log)
        await started(supervisor)
        #expect(supervisor.logOffsetAtLaunch == 15)
    }

    @Test("Chemins de l'app : gardien et go2rtc dans Helpers, yaml dans le dossier de PTZBot, journal à côté de ptzd.log")
    func appPaths() {
        let paths = AppPaths(bundle: URL(fileURLWithPath: "/Applications/PTZBot.app"), home: URL(fileURLWithPath: "/maison/exemple"))
        #expect(paths.go2rtcService == Go2RTCSupervisor.Paths(
            gardien: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/gardien"),
            go2rtc: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/go2rtc"),
            log: URL(fileURLWithPath: "/maison/exemple/Library/Logs/obsbot-nacelle/go2rtc.log")
        ))
        #expect(paths.go2rtcConfig.path == "/maison/exemple/Library/Application Support/ObsbotNacelle/go2rtc.yaml")
    }

    /// Attend une condition, 5 s au plus, en laissant tourner les tâches.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while !condition() {
            guard ContinuousClock.now - start < .seconds(5) else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

@MainActor
@Suite("Lanceur réel : environnement", .french, .timeLimit(.minutes(1)))
struct ProcessLauncherEnvironmentTests {
    @Test("Les variables données remplacent celles de l'app ; les autres restent")
    func environment() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "sortie.log")
        let exit = try await withCheckedThrowingContinuation { continuation in
            do {
                _ = try FoundationProcessLauncher().launch(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", #"echo "$PATH"; test -n "$HOME" && echo maison"#],
                    environment: ["PATH": "/outils:/usr/bin:/bin"],
                    outputURL: log
                ) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(exit == ProcessExit(status: 0, signaled: false))
        #expect(try String(contentsOf: log, encoding: .utf8) == "/outils:/usr/bin:/bin\nmaison\n")
    }
}
