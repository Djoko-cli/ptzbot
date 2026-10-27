import Foundation

/// Le blocage de coreaudiod (spec B3 § 5) : plus d'un ffmpeg vidéo sous go2rtc à deux contrôles de suite, ou un
/// `exec: timeout` dans le journal depuis moins de 2 min **confirmé par deux sondes de suite** de coreaudiod qui ne
/// répondent pas. Un timeout seul ne suffit plus : la caméra qui quitte le bus USB pendant une veille du Mac en donne un
/// aussi (24/10) ; et une sonde lente juste après un réveil (appareils qui se réénumèrent) ne suffit pas non plus.
/// PTZBot ne le répare jamais lui-même (il faudrait les droits root) : il donne la commande.
public enum CoreAudioDetector {
    /// Durée de la suspicion ouverte par un `exec: timeout`.
    public static let timeoutWindow: TimeInterval = 120
    /// Au plus une sonde de coreaudiod pendant ce délai.
    public static let probeInterval: TimeInterval = 30
    /// La sonde est un processus enfant limité à ce délai : au-delà, coreaudiod est tenu pour figé.
    public static let probeTimeout: TimeInterval = 5
    /// Garde du moniteur : une sonde qui n'a rien rendu à ce délai (enfant impossible à tuer, 5 s + 2 s de grâce au pire
    /// sinon) compte comme ratée, et une nouvelle sonde reste possible.
    public static let probeGuard: TimeInterval = 10
    /// Sondes ratées de suite, pendant la même suspicion, avant d'alerter.
    public static let failedProbesToAlert = 2
    /// Contrôles de suite où plus d'un ffmpeg vidéo doit être vu : un seul peut être le chevauchement passager d'un
    /// redémarrage d'ffmpeg (au réveil du Mac).
    public static let extraVideoChecks = 2
    /// Au-delà de ce délai entre deux contrôles (deux fois la lecture de 2 s du panneau), ils ne sont plus « de suite ».
    public static let extraVideoMaxGap: TimeInterval = 4
    public static let repairCommand = "sudo killall -9 coreaudiod"

    /// Une ligne de `ps -A -ww -o pid=,ppid=,command=`.
    struct Entry {
        var pid: pid_t
        var parent: pid_t
        var command: String
    }

    static func entries(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { return nil }
            return Entry(pid: pid, parent: parent, command: fields[2].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Les ffmpeg vidéo (avfoundation, sans `-vn`) parmi les descendants de `root`, le gardien : ceux de go2rtc
    /// seulement, pas ceux d'un autre programme.
    public static func videoFFmpegCount(psOutput: String, root: pid_t) -> Int {
        let all = entries(psOutput)
        var descendants: Set<pid_t> = [root]
        var grew = true
        while grew {
            grew = false
            for entry in all where !descendants.contains(entry.pid) && descendants.contains(entry.parent) {
                descendants.insert(entry.pid)
                grew = true
            }
        }
        return all.filter { entry in
            guard entry.pid != root, descendants.contains(entry.pid) else { return false }
            let program = entry.command.split(separator: " ").first.map(String.init) ?? ""
            return (program as NSString).lastPathComponent == "ffmpeg" && entry.command.contains("avfoundation")
                && !entry.command.contains(" -vn")
        }.count
    }

}

/// L'état du détecteur de coreaudiod (spec B3 § 5), sans horloge ni processus : la surveillance lui donne ce qu'elle voit
/// (timeouts du journal, ffmpeg vidéo comptés, résultats de la sonde) et lui demande s'il faut alerter ou sonder.
public struct CoreAudioWatch: Equatable, Sendable {
    /// Le dernier `exec: timeout` vu (horloge de la surveillance) : la suspicion dure `timeoutWindow` après lui.
    private var lastTimeout: TimeInterval?
    /// Sondes ratées de suite (expirées ou en échec) pendant la suspicion en cours : zéro dès qu'une sonde répond, et dès
    /// qu'une nouvelle suspicion s'ouvre.
    private var failedProbes = 0
    /// Début de la sonde en cours (nil : aucune), et de la dernière.
    private var probeStart: TimeInterval?
    private var lastProbe: TimeInterval?
    /// Numéro de la dernière sonde lancée : le résultat d'une sonde périmée (nouveau go2rtc, garde du moniteur) est écarté.
    private var probeNumber = 0
    /// Contrôles de suite où plus d'un ffmpeg vidéo a été vu, et l'heure du dernier.
    private var extraVideoStreak = 0
    private var lastExtraVideo: TimeInterval?

    public init() {}

    /// Un `exec: timeout` vient d'être lu dans le journal : la suspicion s'ouvre (ou se prolonge). Une suspicion neuve
    /// repart sans les sondes ratées de la précédente : une vraie panne réparée ne doit pas alerter au timeout d'une veille.
    public mutating func sawTimeout(at now: TimeInterval) {
        if !suspicious(now: now) {
            failedProbes = 0
        }
        lastTimeout = now
    }

    /// Le nombre de ffmpeg vidéo sous go2rtc, à un contrôle (`count` à zéro quand la surveillance s'arrête). Deux contrôles
    /// séparés de plus de `extraVideoMaxGap` ne sont pas « de suite ».
    public mutating func videoCount(_ count: Int, now: TimeInterval) {
        guard count > 1 else {
            extraVideoStreak = 0
            lastExtraVideo = nil
            return
        }
        if let last = lastExtraVideo, now - last > CoreAudioDetector.extraVideoMaxGap {
            extraVideoStreak = 0
        }
        extraVideoStreak += 1
        lastExtraVideo = now
    }

    /// Une sonde est en cours (lancée, sans résultat ni garde expirée).
    public var isProbing: Bool { probeStart != nil }

    private func suspicious(now: TimeInterval) -> Bool {
        lastTimeout.map { now - $0 < CoreAudioDetector.timeoutWindow } ?? false
    }

    /// Une sonde est à lancer : suspicion ouverte, aucune sonde en cours, la dernière a au moins `probeInterval`.
    public func shouldProbe(now: TimeInterval) -> Bool {
        guard suspicious(now: now), probeStart == nil else { return false }
        return lastProbe.map { now - $0 >= CoreAudioDetector.probeInterval } ?? true
    }

    /// Une sonde part : son numéro, à rendre avec son résultat.
    @discardableResult
    public mutating func probeStarted(now: TimeInterval) -> Int {
        probeStart = now
        lastProbe = now
        probeNumber += 1
        return probeNumber
    }

    /// Résultat de la sonde `probe` : elle répond, la suspicion est levée (sauf un timeout lu pendant qu'elle tournait) ;
    /// elle ne répond pas, elle compte pour une sonde ratée (l'alerte en demande `failedProbesToAlert` de suite). Le
    /// résultat d'une sonde qui n'est plus la sonde en cours (go2rtc relancé, garde expirée) est ignoré.
    public mutating func probeFinished(responds: Bool, probe: Int) {
        guard probe == probeNumber, let started = probeStart else { return }
        probeStart = nil
        if responds {
            failedProbes = 0
            if let last = lastTimeout, last <= started {
                lastTimeout = nil
            }
        } else {
            failedProbes += 1
        }
    }

    /// Un nouveau go2rtc : les alertes du précédent sont effacées, et la sonde en cours ne vaut plus rien.
    public mutating func reset() {
        lastTimeout = nil
        failedProbes = 0
        probeStart = nil
        extraVideoStreak = 0
        lastExtraVideo = nil
    }

    public func isStuck(now: TimeInterval) -> Bool {
        if extraVideoStreak >= CoreAudioDetector.extraVideoChecks {
            return true
        }
        return failedProbes >= CoreAudioDetector.failedProbesToAlert && suspicious(now: now)
    }
}

/// Ce qu'une lecture du journal de go2rtc a trouvé.
public struct Go2RTCLogScan: Equatable, Sendable {
    public var sawTimeout = false
    public var sawAccessDenied = false

    public init(sawTimeout: Bool = false, sawAccessDenied: Bool = false) {
        self.sawTimeout = sawTimeout
        self.sawAccessDenied = sawAccessDenied
    }
}

/// Les lignes du journal de go2rtc que PTZBot reconnaît (spec B3 § 5).
public enum Go2RTCLogPatterns {
    /// go2rtc 1.9.14 : `[exec] timeout` dans le journal, `exec: timeout` dans l'erreur rendue.
    static let timeout = ["[exec] timeout", "exec: timeout"]
    /// ffmpeg refusé par macOS (avfoundation), tel que go2rtc le rapporte : `exec/rtsp` suivi de la sortie d'ffmpeg.
    static let accessDenied = ["not authorized", "denied", "failed to create av capture input device"]

    public static func scan(_ text: String) -> Go2RTCLogScan {
        var result = Go2RTCLogScan()
        for line in text.split(separator: "\n") {
            if timeout.contains(where: { line.contains($0) }) {
                result.sawTimeout = true
            }
            let lowered = line.lowercased()
            if lowered.contains("avfoundation") || lowered.contains("exec"),
               accessDenied.contains(where: { lowered.contains($0) }) {
                result.sawAccessDenied = true
            }
        }
        return result
    }
}

/// Lit la suite d'un journal depuis un point donné, sans jamais tout relire.
public struct Go2RTCLogReader: Sendable {
    public let url: URL
    public private(set) var offset: UInt64

    public init(url: URL, offset: UInt64 = 0) {
        self.url = url
        self.offset = offset
    }

    public mutating func reset(to offset: UInt64) {
        self.offset = offset
    }

    /// Ce qui a été ajouté depuis la dernière lecture : au plus les `maxBytes` derniers octets. Un journal raccourci
    /// (remplacé) se relit du début.
    public mutating func readNew(maxBytes: Int = 256 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < offset {
            offset = 0
        }
        let start = max(offset, end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
        guard (try? handle.seek(toOffset: start)) != nil else { return "" }
        let data = (try? handle.readToEnd()) ?? Data()
        offset = start + UInt64(data.count)
        return String(decoding: data, as: UTF8.self)
    }
}

/// La liste des processus, derrière un protocole pour les tests. Bloquant : hors du fil de l'interface.
public protocol ProcessListing: Sendable {
    /// `ps -A -ww -o pid=,ppid=,command=` ; nil si ps échoue.
    func psOutput() -> String?
}

public struct SystemProcessListing: ProcessListing {
    public init() {}

    public func psOutput() -> String? {
        guard let result = ChildProcess.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-A", "-ww", "-o", "pid=,ppid=,command="],
                                            timeout: 5, captureOutput: true),
              result.exited, result.status == 0 else { return nil }
        return result.output
    }
}

/// La sonde de coreaudiod, derrière un protocole pour les tests. Bloquante (jusqu'à `probeTimeout`) : hors du fil de
/// l'interface.
public protocol CoreAudioProbe: Sendable {
    /// coreaudiod répond : la sonde a fini à temps, sans erreur.
    func coreAudioResponds() -> Bool
}

/// `system_profiler SPAudioDataType` dans un processus enfant limité à 5 s. Il énumère les appareils audio d'entrée et de
/// sortie par le HAL, donc par coreaudiod : le chemin même qui se fige (HALS_System) quand ffmpeg n'arrive plus à ouvrir
/// le micro. Environ 0,4 s quand tout va bien (mesuré le 28/10). Jamais d'appel CoreAudio dans PTZBot lui-même : figé,
/// il bloquerait un fil pour toujours ; un enfant figé, lui, est tué avec son groupe.
public struct SystemCoreAudioProbe: CoreAudioProbe {
    public init() {}

    public func coreAudioResponds() -> Bool {
        guard let result = ChildProcess.run(URL(fileURLWithPath: "/usr/sbin/system_profiler"), arguments: ["SPAudioDataType"],
                                            timeout: CoreAudioDetector.probeTimeout) else { return false }
        return result.exited && result.status == 0
    }
}

/// Les alertes de go2rtc pour le panneau.
public struct Go2RTCHealth: Equatable, Sendable {
    public var accessDenied = false
    public var coreAudioStuck = false
    public var cameraMissing = false

    public init(accessDenied: Bool = false, coreAudioStuck: Bool = false, cameraMissing: Bool = false) {
        self.accessDenied = accessDenied
        self.coreAudioStuck = coreAudioStuck
        self.cameraMissing = cameraMissing
    }
}
