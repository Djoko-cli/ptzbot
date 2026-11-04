import Foundation
import Testing
@testable import PTZBotKit

/// Les écrans et le journal de la pause de veille, simulés : le test allume ou éteint les écrans, compte les
/// acquittements de la veille et relit les lignes écrites.
@MainActor
final class SleepSurroundings {
    var screensAwake = true
    private(set) var lines: [String] = []
    private(set) var acknowledgements = 0

    func note(_ line: String) {
        lines.append(line)
    }

    func acknowledge() {
        acknowledgements += 1
    }

    /// Les lignes qui commencent par ce début.
    func count(startingWith prefix: String) -> Int {
        lines.filter { $0.hasPrefix(prefix) }.count
    }
}

@MainActor
@Suite("go2rtc : veille du Mac", .french, .timeLimit(.minutes(1)))
struct Go2RTCSleepPauseTests {
    let launcher = FakeLauncher()
    let settings = FakeSettings()
    let scheduler = FakeScheduler()
    let preparer = FakePreparer()
    let around = SleepSurroundings()
    let paths = Go2RTCSupervisor.Paths(
        gardien: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/gardien"),
        go2rtc: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/go2rtc"),
        log: URL(fileURLWithPath: "/logs/go2rtc.log")
    )

    static let announced = "veille annoncée : go2rtc s'arrête avant la veille"
    static let notRunning = "veille annoncée : go2rtc ne tournait pas"
    static let powerOn = "sortie de veille : reprise de go2rtc si les écrans restent allumés 5 s"
    static let darkWake = "écrans toujours éteints (réveil sombre) : go2rtc reste arrêté"
    static let resumed = "réveil complet : go2rtc relancé"
    static let stillOff = "réveil complet : go2rtc éteint, rien à relancer"
    static let resumedAfterGardien = "réveil complet : gardien pas encore sorti, go2rtc repartira s'il sort"
    static let stillFailed = "réveil complet : go2rtc en échec, rien à relancer"
    static let quittingNow = "réveil complet : l'app se termine, rien à relancer"
    static let limitReached = "go2rtc toujours en cours d'arrêt après 20 s : la veille part quand même"
    static func stopped(in seconds: String) -> String {
        "go2rtc arrêté en \(seconds) s : la veille peut partir"
    }

    private func makeSupervisor(enabled: Bool = true) -> Go2RTCSupervisor {
        if enabled {
            settings.values[Go2RTCSupervisor.enabledKey] = true
        }
        return Go2RTCSupervisor(paths: paths, launcher: launcher, preparer: preparer, settings: settings, scheduler: scheduler,
                                parentPID: 4242, configuration: Go2RTCFixtures.settings())
    }

    private func makePause(_ supervisor: Go2RTCSupervisor) -> Go2RTCSleepPause {
        Go2RTCSleepPause(supervisor: supervisor, scheduler: scheduler,
                         screensAwake: { [around] in around.screensAwake }, log: { [around] in around.note($0) })
    }

    /// go2rtc en marche (un gardien lancé), avec sa pause de veille.
    private func running() async -> (supervisor: Go2RTCSupervisor, pause: Go2RTCSleepPause) {
        let supervisor = makeSupervisor()
        supervisor.start()
        await supervisor.waitForPreparation()
        return (supervisor, makePause(supervisor))
    }

    /// Le Mac annonce sa veille ; le test compte les acquittements.
    private func announceSleep(_ pause: Go2RTCSleepPause) {
        pause.systemWillSleep { [around] in around.acknowledge() }
    }

    // MARK: - L'arrêt avant la veille

    @Test("Les délais : 20 s pour acquitter, 5 s d'écrans allumés, 30 s entre deux vérifications ; 20 s laisse au gardien son pire cas")
    func delays() {
        #expect(Go2RTCSleepPause.acknowledgeLimit == 20)
        #expect(Go2RTCSleepPause.resumeDelay == 5)
        #expect(Go2RTCSleepPause.recheckInterval == 30)
        // Le gardien sort en 15 s au pire (10 s pour go2rtc, 5 s pour ses ffmpeg) ; macOS attend 30 s chaque client.
        #expect(Go2RTCSleepPause.acknowledgeLimit > Go2RTCSupervisor.stopDelay + Go2RTCSupervisor.gardienOrphanWait)
        #expect(Go2RTCSleepPause.acknowledgeLimit < 30)
    }

    @Test("Veille, go2rtc en cours : SIGTERM au gardien, veille acquittée à sa sortie seulement ; arrêté, en pause")
    func sleepStopsGardienThenAcknowledges() async throws {
        let (supervisor, pause) = await running()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        announceSleep(pause)
        #expect(process.terminations == 1)
        #expect(supervisor.isPausedForSleep)
        #expect(supervisor.state == .running, "jusqu'à la sortie du gardien")
        scheduler.advance(by: 2.4)
        #expect(around.acknowledgements == 0)
        process.exit(ProcessExit(status: SIGTERM, signaled: true))
        #expect(around.acknowledgements == 1)
        #expect(supervisor.state == .stopped)
        #expect(supervisor.gardienPID == nil)
        #expect(supervisor.isPausedForSleep)
        #expect(process.kills == 0)
        #expect(around.lines == [Self.announced, Self.stopped(in: "2,4")])
        // La limite de 20 s est retirée avec l'acquittement.
        #expect(scheduler.pendingCount == 0)
        scheduler.advance(by: 60)
        #expect(around.acknowledgements == 1)
        #expect(around.lines.count == 2)
    }

    @Test("Gardien qui sort tout de suite : veille acquittée aussitôt, arrêt en 0,0 s")
    func gardienExitsAtOnce() async throws {
        let (supervisor, pause) = await running()
        announceSleep(pause)
        #expect(try #require(launcher.last).terminations == 1)
        #expect(around.acknowledgements == 1)
        #expect(supervisor.state == .stopped)
        #expect(around.lines == [Self.announced, Self.stopped(in: "0,0")])
    }

    @Test("Le gardien ne sort pas : veille acquittée à 20 s ; sa sortie plus tard n'acquitte pas une seconde fois")
    func gardienStaysAlive() async throws {
        let (supervisor, pause) = await running()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        process.ignoresKill = true
        announceSleep(pause)
        scheduler.advance(by: 19.9)
        #expect(around.acknowledgements == 0)
        scheduler.advance(by: 0.1)
        #expect(around.acknowledgements == 1)
        #expect(around.lines == [Self.announced, Self.limitReached])
        #expect(supervisor.isPausedForSleep)
        scheduler.advance(by: 5)
        process.exit(ProcessExit(status: SIGKILL, signaled: true))
        #expect(supervisor.state == .stopped)
        #expect(around.acknowledgements == 1)
        #expect(around.lines == [Self.announced, Self.limitReached])
    }

    @Test("Gardien qui ne sort pas même après SIGKILL : acquittement à 20 s, puis échec « ne s'arrête pas » sans second acquittement ; le réveil ne relance rien")
    func gardienUnkillable() async throws {
        let (supervisor, pause) = await running()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        process.ignoresKill = true
        announceSleep(pause)
        scheduler.advance(by: Go2RTCSupervisor.killDelay * 2 + 1)
        #expect(process.kills == 1)
        #expect(supervisor.state == .failed(.unkillable))
        #expect(around.acknowledgements == 1)
        #expect(around.lines == [Self.announced, Self.limitReached])
        // Un échec reste un échec, comme hors pause : un second gardien doublerait les captures du premier, peut-être vivant.
        pause.systemDidWake()
        scheduler.advance(by: 5)
        await supervisor.waitForPreparation()
        #expect(!supervisor.isPausedForSleep)
        #expect(launcher.launched.count == 1)
        #expect(supervisor.state == .failed(.unkillable))
        #expect(around.lines.last == Self.stillFailed)
    }

    @Test("Veille sans rien à arrêter : veille acquittée tout de suite, pas de pause, état inchangé, réveil sans effet",
          arguments: NothingToStop.allCases)
    func nothingToStop(_ situation: NothingToStop) async {
        let supervisor = makeSupervisor(enabled: situation != .switchedOff)
        let pause = makePause(supervisor)
        if situation == .failed {
            preparer.result = .blocked(.ffmpegMissing)
            supervisor.start()
            await supervisor.waitForPreparation()
        }
        let state = supervisor.state
        announceSleep(pause)
        #expect(around.acknowledgements == 1)
        #expect(!supervisor.isPausedForSleep)
        #expect(supervisor.state == state)
        #expect(around.lines == [Self.notRunning])
        // Sans pause, aucun événement de réveil ne fait rien ni ne s'écrit.
        pause.systemDidPowerOn()
        pause.systemDidWake()
        pause.screensDidWake()
        scheduler.advance(by: 120)
        await supervisor.waitForPreparation()
        #expect(supervisor.state == state)
        #expect(launcher.launched.isEmpty)
        #expect(around.lines == [Self.notRunning])
        #expect(around.acknowledgements == 1)
    }

    @Test("Veille pendant une relance programmée : relance annulée, veille acquittée tout de suite, en pause ; la reprise relance")
    func sleepWhileRestarting() async throws {
        let (supervisor, pause) = await running()
        try #require(launcher.last).exit()
        #expect(supervisor.state == .restarting(count: 1))
        announceSleep(pause)
        #expect(around.acknowledgements == 1)
        #expect(supervisor.isPausedForSleep)
        #expect(supervisor.state == .stopped)
        #expect(around.lines == [Self.announced, Self.stopped(in: "0,0")])
        scheduler.advance(by: 60)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1, "la relance programmée est annulée")
        pause.systemDidWake()
        scheduler.advance(by: 5)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
        #expect(supervisor.state == .running)
        #expect(!supervisor.isPausedForSleep)
    }

    @Test("Veille pendant un arrêt déjà en cours : la veille attend la même sortie ; deux annonces, deux acquittements")
    func sleepDuringStop() async throws {
        let (supervisor, pause) = await running()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        supervisor.stop()
        announceSleep(pause)
        announceSleep(pause)
        #expect(process.terminations == 1, "un seul SIGTERM")
        #expect(around.acknowledgements == 0)
        process.exit(ProcessExit(status: SIGTERM, signaled: true))
        #expect(around.acknowledgements == 2)
        #expect(supervisor.state == .stopped)
        #expect(supervisor.isPausedForSleep)
    }

    // MARK: - Interrupteur et sortie de l'app

    @Test("Interrupteur éteint pendant la pause : la reprise ne lance rien et le dit")
    func switchedOffDuringPause() async throws {
        let (supervisor, pause) = await running()
        announceSleep(pause)
        supervisor.setEnabled(false)
        pause.systemDidWake()
        scheduler.advance(by: 5)
        await supervisor.waitForPreparation()
        #expect(!supervisor.isPausedForSleep)
        #expect(supervisor.state == .stopped)
        #expect(launcher.launched.count == 1)
        #expect(around.lines.last == Self.stillOff)
    }

    @Test("Quitter pendant la pause : rien ne repart au réveil")
    func quitDuringPause() async throws {
        let (supervisor, pause) = await running()
        announceSleep(pause)
        var done = 0
        supervisor.stop(forQuit: true) { done += 1 }
        #expect(done == 1)
        pause.systemDidWake()
        scheduler.advance(by: 30)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1)
        #expect(supervisor.state == .stopped)
        #expect(around.lines.last == Self.quittingNow)
    }

    @Test("Veille annoncée pendant que l'app quitte : rien à arrêter de plus, veille acquittée tout de suite")
    func sleepWhileQuitting() async throws {
        let (supervisor, pause) = await running()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        supervisor.stop(forQuit: true)
        announceSleep(pause)
        #expect(around.acknowledgements == 1)
        #expect(!supervisor.isPausedForSleep)
        #expect(process.terminations == 1)
        #expect(around.lines == [Self.notRunning])
    }

    // MARK: - La reprise au réveil

    @Test("Réveil complet, écrans allumés : go2rtc repart 5 s après, pas avant")
    func fullWake() async throws {
        let (supervisor, pause) = await running()
        // Comme le vrai gardien, qui sort après le SIGTERM et non pendant l'appel : le délai de SIGKILL est armé puis retiré.
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        announceSleep(pause)
        process.exit(ProcessExit(status: SIGTERM, signaled: true))
        pause.systemDidWake()
        scheduler.advance(by: 4.9)
        #expect(supervisor.state == .stopped)
        #expect(supervisor.isPausedForSleep)
        scheduler.advance(by: 0.1)
        #expect(!supervisor.isPausedForSleep)
        #expect(supervisor.state == .starting)
        await supervisor.waitForPreparation()
        #expect(supervisor.state == .running)
        #expect(launcher.launched.count == 2)
        #expect(around.lines.last == Self.resumed)
        let lines = around.lines
        scheduler.advance(by: 120)
        #expect(around.lines == lines, "plus aucune vérification en attente")
        #expect(launcher.launched.count == 2)
        #expect(supervisor.state == .running)
    }

    @Test("Réveil sombre : rien ne repart, nouvelle vérification toutes les 30 s ; go2rtc repart quand les écrans sont allumés")
    func darkWake() async throws {
        let (supervisor, pause) = await running()
        announceSleep(pause)
        around.screensAwake = false
        pause.systemDidPowerOn()
        scheduler.advance(by: 4.9)
        #expect(around.count(startingWith: "écrans toujours éteints") == 0)
        scheduler.advance(by: 0.1)
        #expect(Array(around.lines.suffix(2)) == [Self.powerOn, Self.darkWake])
        #expect(supervisor.isPausedForSleep)
        scheduler.advance(by: 29.9)
        #expect(around.count(startingWith: "écrans toujours éteints") == 1)
        scheduler.advance(by: 0.1)
        #expect(around.count(startingWith: "écrans toujours éteints") == 2)
        #expect(launcher.launched.count == 1)
        // Les écrans s'allument sans qu'un événement soit arrivé : la vérification suivante le voit.
        around.screensAwake = true
        scheduler.advance(by: 30)
        await supervisor.waitForPreparation()
        #expect(!supervisor.isPausedForSleep)
        #expect(launcher.launched.count == 2)
        #expect(supervisor.state == .running)
        #expect(around.lines.last == Self.resumed)
    }

    @Test("Écrans rallumés pendant un réveil sombre : go2rtc repart 5 s après")
    func screensWakeAfterDarkWake() async throws {
        let (supervisor, pause) = await running()
        announceSleep(pause)
        around.screensAwake = false
        pause.systemDidPowerOn()
        scheduler.advance(by: 12)
        around.screensAwake = true
        pause.screensDidWake()
        scheduler.advance(by: 4.9)
        #expect(supervisor.state == .stopped)
        scheduler.advance(by: 0.1)
        await supervisor.waitForPreparation()
        #expect(supervisor.state == .running)
        #expect(launcher.launched.count == 2)
    }

    @Test("Écrans éteints dans les 5 s qui suivent un réveil : la vérification est reportée à 30 s, rien ne repart écrans éteints")
    func screensSleepPostponesCheck() async throws {
        let (supervisor, pause) = await running()
        announceSleep(pause)
        let baseline = scheduler.pendingCount
        pause.systemDidWake()
        #expect(scheduler.pendingCount == baseline + 1)
        scheduler.advance(by: 2)
        around.screensAwake = false
        pause.screensDidSleep()
        #expect(scheduler.pendingCount == baseline + 1, "une seule vérification en attente, reportée")
        scheduler.advance(by: 29.9)
        #expect(around.count(startingWith: "écrans toujours éteints") == 0)
        scheduler.advance(by: 0.1)
        #expect(around.count(startingWith: "écrans toujours éteints") == 1)
        scheduler.advance(by: 120)
        await supervisor.waitForPreparation()
        #expect(supervisor.isPausedForSleep)
        #expect(supervisor.state == .stopped)
        #expect(launcher.launched.count == 1)
        // Les écrans se rallument plus tard : la reprise suit.
        around.screensAwake = true
        pause.screensDidWake()
        scheduler.advance(by: 5)
        await supervisor.waitForPreparation()
        #expect(supervisor.state == .running)
    }

    @Test("Nouvelle annonce de veille : la vérification de reprise en attente est annulée")
    func sleepCancelsCheck() async throws {
        let (supervisor, pause) = await running()
        announceSleep(pause)
        let baseline = scheduler.pendingCount
        pause.systemDidWake()
        scheduler.advance(by: 3)
        #expect(scheduler.pendingCount == baseline + 1)
        announceSleep(pause)
        #expect(around.acknowledgements == 2)
        #expect(scheduler.pendingCount == baseline)
        scheduler.advance(by: 120)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1)
        #expect(supervisor.isPausedForSleep)
    }

    @Test("Plusieurs événements de réveil : une seule vérification en attente, reportée à chaque événement")
    func wakeEventsPostponeCheck() async throws {
        let (supervisor, pause) = await running()
        announceSleep(pause)
        let baseline = scheduler.pendingCount
        pause.systemDidPowerOn()
        #expect(scheduler.pendingCount == baseline + 1)
        scheduler.advance(by: 3)
        pause.systemDidWake()
        pause.screensDidWake()
        #expect(scheduler.pendingCount == baseline + 1)
        scheduler.advance(by: 4.9)
        #expect(supervisor.state == .stopped, "5 s après le dernier événement, non après le premier")
        scheduler.advance(by: 0.1)
        await supervisor.waitForPreparation()
        #expect(supervisor.state == .running)
        #expect(launcher.launched.count == 2)
        #expect(around.count(startingWith: "sortie de veille") == 1, "une ligne par réveil")
    }

    @Test("Réveil pendant que l'arrêt dure encore : go2rtc est relancé à la sortie du gardien")
    func wakeDuringStop() async throws {
        let (supervisor, pause) = await running()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        announceSleep(pause)
        scheduler.advance(by: 3)
        pause.systemDidPowerOn()
        scheduler.advance(by: 5)
        #expect(!supervisor.isPausedForSleep)
        #expect(launcher.launched.count == 1, "le gardien n'est pas encore sorti")
        #expect(around.acknowledgements == 0)
        #expect(around.lines.last == Self.resumedAfterGardien)
        process.exit(ProcessExit(status: SIGTERM, signaled: true))
        #expect(around.acknowledgements == 1)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
        #expect(supervisor.state == .running)
    }

    @Test("Gardien resté en vie après la limite de 20 s : au réveil, relancé à sa sortie seulement")
    func wakeWithGardienStillAlive() async throws {
        let (supervisor, pause) = await running()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        process.ignoresKill = true
        announceSleep(pause)
        scheduler.advance(by: Go2RTCSleepPause.acknowledgeLimit)
        #expect(around.acknowledgements == 1)
        pause.systemDidWake()
        scheduler.advance(by: 5)
        #expect(!supervisor.isPausedForSleep)
        #expect(launcher.launched.count == 1)
        #expect(around.lines.last == Self.resumedAfterGardien)
        process.exit(ProcessExit(status: SIGKILL, signaled: true))
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
        #expect(supervisor.state == .running)
        #expect(around.acknowledgements == 1)
    }

    @Test("Deuxième annonce de veille pendant la pause (réveil sombre, puis veille) : acquittement tout de suite")
    func secondAnnouncementDuringPause() async throws {
        let (supervisor, pause) = await running()
        announceSleep(pause)
        around.screensAwake = false
        pause.systemDidPowerOn()
        scheduler.advance(by: 5)
        announceSleep(pause)
        #expect(around.acknowledgements == 2)
        #expect(around.lines.last == Self.notRunning)
        #expect(supervisor.isPausedForSleep)
        #expect(supervisor.state == .stopped)
        scheduler.advance(by: 120)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1)
        #expect(around.count(startingWith: "écrans toujours éteints") == 1, "la vérification en attente est annulée")
        // Le vrai réveil qui suit relance go2rtc.
        around.screensAwake = true
        pause.systemDidPowerOn()
        pause.systemDidWake()
        scheduler.advance(by: 5)
        await supervisor.waitForPreparation()
        #expect(supervisor.state == .running)
    }

    // MARK: - Le journal

    @Test("Les lignes du journal ne contiennent aucun motif que Go2RTCLogPatterns reconnaît, avec ou sans l'horodatage")
    func journalLinesAreNotLogPatterns() async throws {
        let (supervisor, pause) = await running()
        // Premier cycle : arrêt en 2,4 s, réveil sombre, deuxième annonce, vrai réveil.
        let first = try #require(launcher.last)
        first.ignoresTerminate = true
        announceSleep(pause)
        scheduler.advance(by: 2.4)
        first.exit(ProcessExit(status: SIGTERM, signaled: true))
        around.screensAwake = false
        pause.systemDidPowerOn()
        scheduler.advance(by: 5)
        announceSleep(pause)
        around.screensAwake = true
        pause.systemDidPowerOn()
        scheduler.advance(by: 5)
        await supervisor.waitForPreparation()
        // Second cycle : le gardien ne sort pas, l'interrupteur est éteint avant le réveil.
        let second = try #require(launcher.last)
        second.ignoresTerminate = true
        second.ignoresKill = true
        announceSleep(pause)
        scheduler.advance(by: Go2RTCSleepPause.acknowledgeLimit)
        supervisor.setEnabled(false)
        pause.systemDidWake()
        scheduler.advance(by: 5)

        let everyLine: Set<String> = [
            Self.announced, Self.stopped(in: "2,4"), Self.powerOn, Self.darkWake, Self.notRunning, Self.resumed,
            Self.limitReached, Self.stillOff,
        ]
        #expect(Set(around.lines) == everyLine, "le scénario écrit chacune des lignes")
        // Les lignes de la reprise que ce scénario n'atteint pas (gardien sorti tard, échec, app qui quitte).
        let outcomes: [SleepResume] = [.notPaused, .relaunched, .afterGardienExits, .switchedOff, .failed, .quitting]
        let resumeLines = outcomes.compactMap(Go2RTCSleepPause.resumeLine)
        #expect(resumeLines == [Self.resumed, Self.resumedAfterGardien, Self.stillOff, Self.stillFailed, Self.quittingNow])
        for line in around.lines + resumeLines {
            #expect(Go2RTCLogPatterns.scan(line) == Go2RTCLogScan(), "\(line)")
            #expect(Go2RTCLogPatterns.scan(Go2RTCJournal.line(line, at: Date()) + "\n") == Go2RTCLogScan(), "\(line)")
        }
    }

    @Test("Ligne du journal : l'heure locale « HH:mm:ss », puis « PTZBot : » et le texte")
    func journalLineFormat() throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9, minute: 5, second: 7)))
        #expect(Go2RTCJournal.line("veille annoncée : go2rtc ne tournait pas", at: date) == "09:05:07 PTZBot : veille annoncée : go2rtc ne tournait pas")
        let evening = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 20, minute: 50, second: 0)))
        #expect(Go2RTCJournal.line("x", at: evening) == "20:50:00 PTZBot : x")
    }

    /// Une ligne du journal sans son heure : « PTZBot : … » ; l'heure doit être « HH:mm:ss ».
    private func withoutTime(_ line: some StringProtocol) -> String? {
        let time = line.prefix(8)
        guard time.count == 8, time.enumerated().allSatisfy({ $0.offset % 3 == 2 ? $0.element == ":" : $0.element.isNumber }) else {
            return nil
        }
        return String(line.dropFirst(9))
    }

    @Test("Journal : les lignes sont ajoutées en fin de fichier, le dossier et le fichier sont créés au besoin, une erreur est ignorée")
    func journalAppend() throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "logs/go2rtc.log")
        Go2RTCJournal.append("première", to: log)
        try Data("gardien : une ligne du gardien\n".utf8).append(to: log)
        Go2RTCJournal.append("seconde", to: log)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 4 && lines[3].isEmpty, "chaque ligne finit par un saut de ligne")
        #expect(withoutTime(lines[0]) == "PTZBot : première")
        #expect(lines[1] == "gardien : une ligne du gardien")
        #expect(withoutTime(lines[2]) == "PTZBot : seconde")

        // Un « dossier » qui est un fichier : l'écriture échoue, sans rien lever.
        let blocked = directory.appending(path: "bloque")
        try Data().write(to: blocked)
        Go2RTCJournal.append("perdue", to: blocked.appending(path: "go2rtc.log"))
        #expect(try Data(contentsOf: blocked).isEmpty)
    }

    @Test("Câblage de l'app : les lignes de la pause vont dans go2rtc.log, datées et signées « PTZBot »")
    func systemWiring() async throws {
        let home = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let appPaths = AppPaths(bundle: URL(fileURLWithPath: "/Applications/PTZBot.app"), home: home)
        let supervisor = makeSupervisor()
        let pause = Go2RTCSleepPause.system(supervisor: supervisor, paths: appPaths, scheduler: scheduler)
        supervisor.start()
        await supervisor.waitForPreparation()
        var acknowledged = 0
        pause.systemWillSleep { acknowledged += 1 }
        #expect(acknowledged == 1)
        let lines = try String(contentsOf: appPaths.go2rtcLog, encoding: .utf8).split(separator: "\n")
        #expect(lines.compactMap(withoutTime) == ["PTZBot : " + Self.announced, "PTZBot : " + Self.stopped(in: "0,0")])
    }
}

private extension Data {
    /// Ajoute ces octets en fin de fichier (le gardien écrit ainsi dans go2rtc.log).
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
