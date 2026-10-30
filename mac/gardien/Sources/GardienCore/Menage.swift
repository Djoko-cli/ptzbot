import Foundation

/// Un ffmpeg de capture vu par un passage du ménage (spec B3 § 3.2).
public struct Capture: Equatable, Sendable {
    /// D'où vient la preuve qu'il appartient à PTZBot.
    public enum Origin: Equatable, Sendable {
        /// Membre du groupe de go2rtc ou enfant direct de go2rtc.
        case go2rtc
        /// PPID 1, sortie `rtsp://127.0.0.1:<port>/<empreinte>` avec une empreinte donnée par PTZBot (`--capture`).
        case orphan
    }

    /// Sa connexion au serveur RTSP de go2rtc.
    public enum Link: Equatable, Sendable {
        /// Au moins une socket TCP `ESTABLISHED` dont le port distant est le port RTSP.
        case connected
        /// Aucune socket de ce genre, et toutes ses sockets ont pu être lues.
        case detached
        /// Une socket au moins n'a pas pu être lue (EPERM…) : rien n'est conclu.
        case unreadable
    }

    public var identity: ProcessIdentity
    /// Depuis son démarrage, en secondes.
    public var age: TimeInterval
    public var link: Link
    public var origin: Origin

    public init(identity: ProcessIdentity, age: TimeInterval, link: Link, origin: Origin) {
        self.identity = identity
        self.age = age
        self.link = link
        self.origin = origin
    }
}

/// Ce que le ménage lit de la machine et ce qu'il y fait, derrière un protocole pour les tests.
public protocol CaptureSystem {
    /// Les ffmpeg de capture de PTZBot, à cet instant.
    func captures() -> [Capture]
    /// Ce processus-là (même pid, même heure de démarrage) et sa connexion ; nil s'il est sorti.
    func recheck(_ identity: ProcessIdentity) -> Capture.Link?
    /// SIGTERM, jamais un autre signal.
    func terminate(_ identity: ProcessIdentity)
}

/// Le ménage des ffmpeg décrochés (spec B3 § 3.2), sans horloge ni processus : le gardien l'appelle à chaque passage
/// (toutes les `period` secondes) et à chaque échéance de `nextSignal`, sur son horloge monotone en secondes.
///
/// Un ffmpeg est **décroché** s'il a plus de `minimumAge` secondes et aucune socket établie vers le port RTSP. Décroché
/// à deux passages de suite (le même processus), il reçoit `signalCount` SIGTERM à `signalInterval` d'intervalle : un
/// ffmpeg figé dans une capture AVFoundation ignore les trois premiers et sort au-delà (« Received > 3 system signals,
/// hard exiting »). Avant chaque signal, il est revérifié : sorti, reconnecté ou illisible, la salve s'arrête. Un
/// dernier coup d'œil, un intervalle après le dernier signal, constate sa fin ; s'il vit encore, il est laissé en vie
/// et n'est plus jamais visé. Jamais de SIGKILL.
public struct Menage {
    /// Un ffmpeg figé ne sort qu'au-delà de 3 signaux.
    public static let signalCount = 4

    public let port: UInt16
    public let timing: SweepTiming

    private struct Salvo {
        var capture: Capture
        var sent = 0
        var next: TimeInterval
    }

    /// Les décrochés du passage précédent.
    private var suspects: Set<ProcessIdentity.Key> = []
    private var salvos: [Salvo] = []
    /// Ceux qui ont reçu leurs signaux sans sortir : plus jamais visés (oubliés quand ils disparaissent du relevé).
    private var spared: Set<ProcessIdentity.Key> = []

    public init(port: UInt16, timing: SweepTiming) {
        self.port = port
        self.timing = timing
    }

    /// L'échéance du prochain signal (ou du dernier coup d'œil) ; nil sans salve en cours.
    public var nextSignal: TimeInterval? {
        salvos.map(\.next).min()
    }

    /// Un passage : les décrochés vus pour la seconde fois de suite reçoivent leur premier SIGTERM tout de suite.
    public mutating func pass(_ system: some CaptureSystem, now: TimeInterval, log: (String) -> Void) {
        let captures = system.captures()
        let seen = Set(captures.map(\.identity.key))
        spared.formIntersection(seen)
        var detached: Set<ProcessIdentity.Key> = []
        for capture in captures {
            let key = capture.identity.key
            guard !spared.contains(key), !salvos.contains(where: { $0.capture.identity.key == key }) else { continue }
            guard capture.age > timing.minimumAge, capture.link == .detached else { continue }
            detached.insert(key)
            guard suspects.contains(key) else { continue }
            log("\(describe(capture)), démarré il y a \(Int(capture.age)) s, sans connexion établie vers le port RTSP \(port) à "
                + "deux passages de suite : \(Self.signalCount) SIGTERM à \(Self.seconds(timing.signalInterval)) d'intervalle")
            salvos.append(Salvo(capture: capture, next: now))
        }
        suspects = detached.subtracting(salvos.map(\.capture.identity.key))
        fire(system, now: now, log: log)
    }

    /// Les signaux arrivés à échéance, chacun après revérification.
    public mutating func fire(_ system: some CaptureSystem, now: TimeInterval, log: (String) -> Void) {
        // Un réveil de minuterie un peu en avance compte pour l'échéance.
        let due = now + 0.005
        var remaining: [Salvo] = []
        for var salvo in salvos {
            guard salvo.next <= due else {
                remaining.append(salvo)
                continue
            }
            let identity = salvo.capture.identity
            let name = describe(salvo.capture)
            switch system.recheck(identity) {
            case nil:
                log("\(name) est sorti après \(salvo.sent) SIGTERM")
                continue
            case .connected?:
                log("\(name) est de nouveau connecté au port RTSP \(port) : plus de SIGTERM (\(salvo.sent) envoyés)")
                continue
            case .unreadable?:
                log("\(name) : ses sockets sont devenues illisibles, rien n'est conclu : plus de SIGTERM (\(salvo.sent) envoyés)")
                continue
            case .detached?:
                guard salvo.sent < Self.signalCount else {
                    log("\(name) vit encore après \(Self.signalCount) SIGTERM : laissé en vie (jamais de SIGKILL)")
                    spared.insert(identity.key)
                    continue
                }
                system.terminate(identity)
                salvo.sent += 1
                salvo.next += timing.signalInterval
                remaining.append(salvo)
            }
        }
        salvos = remaining
    }

    private func describe(_ capture: Capture) -> String {
        switch capture.origin {
        case .go2rtc: "ffmpeg (\(capture.identity.pid))"
        case .orphan: "ffmpeg orphelin (\(capture.identity.pid))"
        }
    }

    /// « 1 s », « 0,25 s ».
    static func seconds(_ value: TimeInterval) -> String {
        value == value.rounded() ? "\(Int(value)) s" : "\(value) s".replacingOccurrences(of: ".", with: ",")
    }
}
