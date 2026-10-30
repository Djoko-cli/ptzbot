import Foundation

/// Les délais du ménage des ffmpeg décrochés (spec B3 § 3.2) : un passage toutes les `period` secondes ; un ffmpeg
/// plus jeune que `minimumAge` n'est jamais visé ; ses SIGTERM partent à `signalInterval` secondes d'intervalle, comme
/// ceux de l'arrêt de go2rtc. Réglables pour les tests seulement (`--delais-menage`).
public struct SweepTiming: Equatable, Sendable {
    public var period: TimeInterval
    public var minimumAge: TimeInterval
    public var signalInterval: TimeInterval

    public init(period: TimeInterval, minimumAge: TimeInterval, signalInterval: TimeInterval) {
        self.period = period
        self.minimumAge = minimumAge
        self.signalInterval = signalInterval
    }

    /// Les délais de PTZBot : 60 s, 180 s, 1 s.
    public static let standard = SweepTiming(period: 60, minimumAge: 180, signalInterval: 1)
}

/// Les options du gardien (spec B3 § 3.2) :
/// `gardien --parent <pid> --arret <secondes> [--rtsp <port> [--capture <md5>]…] -- <programme> [arguments…]`.
public struct GardienOptions: Equatable, Sendable {
    /// Le processus surveillé (PTZBot) : s'il disparaît, le programme est arrêté.
    public var parent: pid_t
    /// Le délai laissé au programme entre SIGTERM et SIGKILL, en secondes.
    public var stopDelay: TimeInterval
    /// Le programme, par son chemin absolu.
    public var program: String
    public var arguments: [String]
    /// Le port RTSP de go2rtc : avec lui, le ménage des ffmpeg décrochés ; sans lui, pas de ménage.
    public var rtspPort: UInt16?
    /// Les empreintes (MD5 en hexadécimal minuscule) des sources `exec:` du yaml généré par PTZBot : un ffmpeg orphelin
    /// dont la sortie est `rtsp://127.0.0.1:<port>/<empreinte>` vient d'un go2rtc de PTZBot. Vide : pas de ménage des
    /// orphelins.
    public var captures: [String]
    public var sweepTiming: SweepTiming

    public init(
        parent: pid_t, stopDelay: TimeInterval, program: String, arguments: [String], rtspPort: UInt16? = nil,
        captures: [String] = [], sweepTiming: SweepTiming = .standard
    ) {
        self.parent = parent
        self.stopDelay = stopDelay
        self.program = program
        self.arguments = arguments
        self.rtspPort = rtspPort
        self.captures = captures
        self.sweepTiming = sweepTiming
    }

    public static let usage = "usage : gardien --parent <pid> --arret <secondes> [--rtsp <port> [--capture <md5>]…] -- <programme> [arguments…]"
    /// Le plus long délai d'arrêt accepté.
    public static let maximumStopDelay: TimeInterval = 300
    /// Le plus long délai du ménage accepté (`--delais-menage`).
    public static let maximumSweepDelay: TimeInterval = 3600

    public enum ParseError: Error, Equatable {
        case unknownOption(String)
        case missingValue(String)
        case invalidValue(option: String, value: String)
        case duplicate(String)
        case missingOption(String)
        case missingProgram
    }

    static let valueOptions: Set<String> = ["--parent", "--arret", "--rtsp", "--capture", "--delais-menage"]

    /// Lit les options, dans n'importe quel ordre, puis `--` : tout ce qui suit est au programme, même ce qui ressemble
    /// à une option. `--parent` et `--arret` sont obligatoires ; `--parent`, `--arret`, `--rtsp` et `--delais-menage`
    /// ne viennent qu'une fois ; `--capture` se répète (une empreinte répétée ne compte qu'une fois) et demande `--rtsp`.
    /// Le PID est un entier strictement positif ; le délai, un nombre de secondes entre 0 et `maximumStopDelay` ; le
    /// port, un entier de 1 à 65535 ; l'empreinte, 32 chiffres hexadécimaux en minuscules ; `--delais-menage`, trois
    /// nombres de secondes séparés par des virgules (passage, âge, intervalle), chacun dans ]0, `maximumSweepDelay`] ;
    /// le programme, un chemin absolu.
    public static func parse(_ arguments: [String]) throws(ParseError) -> GardienOptions {
        var parent: pid_t?
        var stopDelay: TimeInterval?
        var rtspPort: UInt16?
        var captures: [String] = []
        var sweepTiming: SweepTiming?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let option = arguments[index]
            if option == "--" {
                let rest = arguments[arguments.index(after: index)...]
                guard let program = rest.first else { throw .missingProgram }
                guard program.hasPrefix("/") else { throw .invalidValue(option: "--", value: program) }
                guard let parent else { throw .missingOption("--parent") }
                guard let stopDelay else { throw .missingOption("--arret") }
                guard captures.isEmpty || rtspPort != nil else { throw .missingOption("--rtsp") }
                return GardienOptions(
                    parent: parent, stopDelay: stopDelay, program: program, arguments: Array(rest.dropFirst()),
                    rtspPort: rtspPort, captures: captures, sweepTiming: sweepTiming ?? .standard
                )
            }
            guard valueOptions.contains(option) else { throw .unknownOption(option) }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else { throw .missingValue(option) }
            let value = arguments[next]
            switch option {
            case "--parent":
                guard parent == nil else { throw .duplicate(option) }
                guard let pid = pid_t(value), pid > 0 else { throw .invalidValue(option: option, value: value) }
                parent = pid
            case "--arret":
                guard stopDelay == nil else { throw .duplicate(option) }
                guard let seconds = TimeInterval(value), seconds.isFinite, (0...maximumStopDelay).contains(seconds) else {
                    throw .invalidValue(option: option, value: value)
                }
                stopDelay = seconds
            case "--rtsp":
                guard let port = UInt16(value), port > 0 else { throw .invalidValue(option: option, value: value) }
                guard rtspPort == nil else { throw .duplicate(option) }
                rtspPort = port
            case "--capture":
                guard isFingerprint(value) else { throw .invalidValue(option: option, value: value) }
                if !captures.contains(value) {
                    captures.append(value)
                }
            default:
                guard sweepTiming == nil else { throw .duplicate(option) }
                let delays = value.split(separator: ",", omittingEmptySubsequences: false).compactMap { TimeInterval(String($0)) }
                guard delays.count == 3, value.split(separator: ",", omittingEmptySubsequences: false).count == 3,
                      delays.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= maximumSweepDelay }) else {
                    throw .invalidValue(option: option, value: value)
                }
                sweepTiming = SweepTiming(period: delays[0], minimumAge: delays[1], signalInterval: delays[2])
            }
            index = arguments.index(after: next)
        }
        throw .missingProgram
    }

    /// Un MD5 tel que go2rtc l'écrit dans le chemin RTSP d'une source `exec:` : 32 chiffres hexadécimaux en minuscules.
    static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
