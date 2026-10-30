import Foundation
import Testing
@testable import GardienCore

/// La table des processus simulée : les ffmpeg de capture vus par le ménage, et les SIGTERM qu'il envoie. Aucun
/// processus réel n'est touché.
final class FakeCaptureSystem: CaptureSystem {
    var table: [Capture] = []
    /// Les pid visés, dans l'ordre des signaux.
    private(set) var signals: [pid_t] = []

    func captures() -> [Capture] { table }

    func recheck(_ identity: ProcessIdentity) -> Capture.Link? {
        table.first { $0.identity.key == identity.key }?.link
    }

    func terminate(_ identity: ProcessIdentity) {
        signals.append(identity.pid)
    }

    func set(_ pid: pid_t, link: Capture.Link) {
        for index in table.indices where table[index].identity.pid == pid {
            table[index].link = link
        }
    }

    /// Les âges avancent avec l'horloge du test.
    func age(by seconds: TimeInterval) {
        for index in table.indices {
            table[index].age += seconds
        }
    }

    func remove(_ pid: pid_t) {
        table.removeAll { $0.identity.pid == pid }
    }

    func count(_ pid: pid_t) -> Int {
        signals.filter { $0 == pid }.count
    }
}

@Suite("Ménage des ffmpeg décrochés : machine à états")
struct MenageTests {
    static let port: UInt16 = 18554

    static func identity(_ pid: pid_t, start: Int64 = 1000) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startSeconds: start, startMicroseconds: 0, groupID: 100, name: "ffmpeg")
    }

    static func capture(_ pid: pid_t, age: TimeInterval, _ link: Capture.Link, origin: Capture.Origin = .go2rtc, start: Int64 = 1000) -> Capture {
        Capture(identity: identity(pid, start: start), age: age, link: link, origin: origin)
    }

    /// Un passage à `now`, après avoir vieilli la table depuis le passage précédent.
    private func pass(_ menage: inout Menage, _ system: FakeCaptureSystem, at now: TimeInterval, last: inout TimeInterval, log: inout [String]) {
        system.age(by: now - last)
        last = now
        var lines: [String] = []
        menage.pass(system, now: now) { lines.append($0) }
        log += lines
    }

    private func fire(_ menage: inout Menage, _ system: FakeCaptureSystem, at now: TimeInterval, log: inout [String]) {
        var lines: [String] = []
        menage.fire(system, now: now) { lines.append($0) }
        log += lines
    }

    @Test("Visé : plus de 180 s, aucune socket établie vers le port RTSP, à deux passages de suite ; 4 SIGTERM à 1 s, puis plus rien")
    func detachedTwice() {
        let system = FakeCaptureSystem()
        system.table = [
            Self.capture(11, age: 200, .detached),
            Self.capture(12, age: 200, .connected),
            Self.capture(13, age: 10, .detached),
            Self.capture(14, age: 200, .unreadable),
            Self.capture(15, age: 200, .detached, origin: .orphan),
        ]
        var menage = Menage(port: Self.port, timing: .standard)
        var log: [String] = []
        var last: TimeInterval = 0
        pass(&menage, system, at: 0, last: &last, log: &log)
        #expect(system.signals.isEmpty, "une seule fois décroché : rien")
        #expect(menage.nextSignal == nil)
        pass(&menage, system, at: 60, last: &last, log: &log)
        // Le premier SIGTERM part tout de suite, après revérification ; les suivants à 1 s d'intervalle.
        #expect(system.signals.sorted() == [11, 15])
        #expect(menage.nextSignal == 61)
        for second in [61.0, 62, 63] {
            fire(&menage, system, at: second, log: &log)
        }
        #expect(system.count(11) == 4)
        #expect(system.count(15) == 4)
        #expect(Set(system.signals) == [11, 15], "jamais un connecté, un jeune ni une socket illisible")
        // Un dernier coup d'œil, 1 s après le 4e : encore là, laissé en vie.
        #expect(menage.nextSignal == 64)
        fire(&menage, system, at: 64, log: &log)
        #expect(menage.nextSignal == nil)
        #expect(log.contains { $0.contains("ffmpeg (11)") && $0.contains("4 SIGTERM") && $0.contains("port RTSP 18554") })
        #expect(log.contains { $0.contains("ffmpeg orphelin (15)") })
        #expect(log.contains { $0.contains("ffmpeg (11) vit encore après 4 SIGTERM") && $0.contains("laissé en vie") })
        // Puis plus rien, même toujours décroché.
        pass(&menage, system, at: 120, last: &last, log: &log)
        pass(&menage, system, at: 180, last: &last, log: &log)
        #expect(system.count(11) == 4)
        #expect(system.count(15) == 4)
        #expect(system.signals.count == 8)
    }

    @Test("Décroché, puis connecté au passage suivant : épargné, et la série repart de zéro")
    func reconnectedResetsStreak() {
        let system = FakeCaptureSystem()
        system.table = [Self.capture(21, age: 300, .detached)]
        var menage = Menage(port: Self.port, timing: .standard)
        var log: [String] = []
        var last: TimeInterval = 0
        pass(&menage, system, at: 0, last: &last, log: &log)
        system.set(21, link: .connected)
        pass(&menage, system, at: 60, last: &last, log: &log)
        system.set(21, link: .detached)
        pass(&menage, system, at: 120, last: &last, log: &log)
        #expect(system.signals.isEmpty)
        // Illisible au milieu : ne rien conclure, la série repart aussi.
        system.set(21, link: .unreadable)
        pass(&menage, system, at: 180, last: &last, log: &log)
        system.set(21, link: .detached)
        pass(&menage, system, at: 240, last: &last, log: &log)
        #expect(system.signals.isEmpty)
        pass(&menage, system, at: 300, last: &last, log: &log)
        #expect(system.signals == [21])
    }

    @Test("Le même processus aux deux passages : un pid réutilisé (autre heure de démarrage) repart de zéro")
    func sameIdentityRequired() {
        let system = FakeCaptureSystem()
        system.table = [Self.capture(31, age: 300, .detached, start: 1000)]
        var menage = Menage(port: Self.port, timing: .standard)
        var log: [String] = []
        var last: TimeInterval = 0
        pass(&menage, system, at: 0, last: &last, log: &log)
        system.table = [Self.capture(31, age: 300, .detached, start: 2000)]
        pass(&menage, system, at: 60, last: &last, log: &log)
        #expect(system.signals.isEmpty)
    }

    @Test("Revérifié avant chaque signal : reconnecté, sorti, pid réutilisé ou socket illisible, plus aucun SIGTERM")
    func recheckBeforeEachSignal() {
        let system = FakeCaptureSystem()
        system.table = [
            Self.capture(41, age: 300, .detached),
            Self.capture(42, age: 300, .detached),
            Self.capture(43, age: 300, .detached),
            Self.capture(44, age: 300, .detached),
        ]
        var menage = Menage(port: Self.port, timing: .standard)
        var log: [String] = []
        var last: TimeInterval = 0
        pass(&menage, system, at: 0, last: &last, log: &log)
        pass(&menage, system, at: 60, last: &last, log: &log)
        #expect(system.signals.sorted() == [41, 42, 43, 44])
        // 41 se reconnecte ; 42 sort ; le pid de 43 est repris par un autre processus ; les sockets de 44 deviennent
        // illisibles.
        system.set(41, link: .connected)
        system.remove(42)
        system.remove(43)
        system.table.append(Self.capture(43, age: 0, .detached, start: 5000))
        system.set(44, link: .unreadable)
        fire(&menage, system, at: 61, log: &log)
        #expect(system.signals.sorted() == [41, 42, 43, 44], "aucun signal de plus")
        #expect(menage.nextSignal == nil)
        #expect(log.contains { $0.contains("ffmpeg (41)") && $0.contains("de nouveau connecté") })
        #expect(log.contains { $0.contains("ffmpeg (42) est sorti après 1 SIGTERM") })
        #expect(log.contains { $0.contains("ffmpeg (43) est sorti après 1 SIGTERM") })
        #expect(log.contains { $0.contains("ffmpeg (44)") && $0.contains("illisible") })
    }

    @Test("Fin constatée entre deux signaux : une ligne, plus de signal ; les délais suivent `SweepTiming`")
    func exitAfterThirdSignal() {
        let system = FakeCaptureSystem()
        system.table = [Self.capture(51, age: 5, .detached)]
        let timing = SweepTiming(period: 0.5, minimumAge: 1, signalInterval: 0.25)
        var menage = Menage(port: Self.port, timing: timing)
        var log: [String] = []
        var last: TimeInterval = 0
        pass(&menage, system, at: 0, last: &last, log: &log)
        pass(&menage, system, at: 0.5, last: &last, log: &log)
        #expect(menage.nextSignal == 0.75)
        fire(&menage, system, at: 0.75, log: &log)
        // Un réveil un peu en avance ne fait pas partir le signal suivant avant l'heure.
        fire(&menage, system, at: 0.8, log: &log)
        #expect(system.count(51) == 2)
        fire(&menage, system, at: 1.0, log: &log)
        #expect(system.count(51) == 3)
        system.remove(51)
        fire(&menage, system, at: 1.25, log: &log)
        #expect(system.count(51) == 3)
        #expect(menage.nextSignal == nil)
        #expect(log.filter { $0.contains("ffmpeg (51) est sorti après 3 SIGTERM") }.count == 1)
    }

    @Test("Visé pendant une salve : pas de seconde salve ; un passage pendant la salve ne la relance pas")
    func noDoubleSalvo() {
        let system = FakeCaptureSystem()
        system.table = [Self.capture(61, age: 5, .detached)]
        var menage = Menage(port: Self.port, timing: SweepTiming(period: 1, minimumAge: 1, signalInterval: 1))
        var log: [String] = []
        var last: TimeInterval = 0
        pass(&menage, system, at: 0, last: &last, log: &log)
        pass(&menage, system, at: 1, last: &last, log: &log)
        #expect(system.count(61) == 1)
        pass(&menage, system, at: 1.5, last: &last, log: &log)
        #expect(system.count(61) == 1)
        fire(&menage, system, at: 2, log: &log)
        fire(&menage, system, at: 3, log: &log)
        fire(&menage, system, at: 4, log: &log)
        fire(&menage, system, at: 5, log: &log)
        pass(&menage, system, at: 6, last: &last, log: &log)
        pass(&menage, system, at: 7, last: &last, log: &log)
        #expect(system.count(61) == 4)
    }
}
