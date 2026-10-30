import Foundation

/// Les ffmpeg de capture de PTZBot sur la machine (spec B3 § 3.2), lus par libproc et `sysctl`.
///
/// Un ffmpeg de capture s'appelle `ffmpeg`, appartient à l'utilisateur du gardien, a `avfoundation` dans ses arguments,
/// et son dernier argument est sa sortie vers le serveur RTSP de go2rtc : `rtsp://127.0.0.1:<port>/<empreinte>`, où
/// go2rtc 1.9.14 remplace `{output}` (`internal/exec`). Sa propriété est prouvée :
/// - par la parenté : membre du groupe de go2rtc, ou enfant direct de go2rtc ; sa sortie doit viser `port` (un
///   fichier personnalisé sur un autre port, ou une source sans `{output}`, n'est jamais jugé) ;
/// - ou, orphelin (PPID 1) d'un go2rtc précédent, par sa sortie exacte, `rtsp://127.0.0.1:<port>/<empreinte>`, avec une
///   empreinte donnée par PTZBot (`--capture`).
/// Les sockets ne sont lues que pour ces processus-là.
public struct LiveCaptureSystem: CaptureSystem {
    public let go2rtc: pid_t
    public let port: UInt16
    public let fingerprints: [String]

    public init(go2rtc: pid_t, port: UInt16, fingerprints: [String]) {
        self.go2rtc = go2rtc
        self.port = port
        self.fingerprints = fingerprints
    }

    public func captures() -> [Capture] {
        var seen: Set<ProcessIdentity.Key> = []
        var found: [Capture] = []
        let now = Self.wallClock()
        for identity in ProcessTable.liveMembers(ofGroup: go2rtc) + ProcessTable.children(of: go2rtc)
        where identity.pid != go2rtc && seen.insert(identity.key).inserted {
            guard let output = Self.captureOutput(identity), Self.outputPort(output) == port else { continue }
            found.append(capture(identity, now: now, origin: .go2rtc))
        }
        guard !fingerprints.isEmpty else { return found }
        let outputs = Set(fingerprints.map { "rtsp://127.0.0.1:\(port)/\($0)" })
        for pid in ProcessTable.pids(withParent: 1) {
            guard let identity = ProcessTable.identity(of: pid), identity.name == "ffmpeg", seen.insert(identity.key).inserted,
                  let output = Self.captureOutput(identity), outputs.contains(output) else { continue }
            found.append(capture(identity, now: now, origin: .orphan))
        }
        return found
    }

    public func recheck(_ identity: ProcessIdentity) -> Capture.Link? {
        guard ProcessTable.isAlive(identity) else { return nil }
        return ProcessTable.rtspLink(of: identity.pid, port: port)
    }

    public func terminate(_ identity: ProcessIdentity) {
        kill(identity.pid, SIGTERM)
    }

    private func capture(_ identity: ProcessIdentity, now: TimeInterval, origin: Capture.Origin) -> Capture {
        let start = TimeInterval(identity.startSeconds) + TimeInterval(identity.startMicroseconds) / 1_000_000
        return Capture(identity: identity, age: now - start, link: ProcessTable.rtspLink(of: identity.pid, port: port), origin: origin)
    }

    /// La sortie d'un ffmpeg de capture (son dernier argument) ; nil si ce n'en est pas un : autre programme, autre
    /// utilisateur, pas d'`avfoundation`, arguments illisibles.
    static func captureOutput(_ identity: ProcessIdentity) -> String? {
        guard identity.name == "ffmpeg", ProcessTable.userID(of: identity.pid) == getuid(),
              let arguments = ProcessTable.arguments(of: identity.pid), arguments.count > 1,
              arguments.dropFirst().contains(where: { $0.contains("avfoundation") }) else { return nil }
        return arguments.last
    }

    /// Le port d'une sortie `rtsp://127.0.0.1:<port>/<chemin>` ; nil pour toute autre forme.
    static func outputPort(_ output: String) -> UInt16? {
        let prefix = "rtsp://127.0.0.1:"
        guard output.hasPrefix(prefix) else { return nil }
        let rest = output.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/"), let port = UInt16(rest[..<slash]), port > 0 else { return nil }
        return port
    }

    /// L'heure murale, celle des heures de démarrage des processus.
    static func wallClock() -> TimeInterval {
        var now = timeval()
        gettimeofday(&now, nil)
        return TimeInterval(now.tv_sec) + TimeInterval(now.tv_usec) / 1_000_000
    }
}
