import CryptoKit
import Foundation

/// Pourquoi le yaml de go2rtc ne peut pas être écrit avec ces réglages.
public enum Go2RTCConfigError: LocalizedError, Equatable, Sendable {
    /// go2rtc découpe la commande d'ffmpeg sans échappement (`shell.QuoteSplit`) et coupe la source au premier `#` :
    /// un nom vide, avec `#`, un caractère de contrôle, ou les deux sortes de guillemets à la fois, ne passe pas.
    case unsupportedName(String)
    /// Sans identifiant ou sans mot de passe, le flux RTSP serait ouvert à tout le réseau local.
    case missingCredential
    /// Un caractère de contrôle (saut de ligne, tabulation…) dans l'identifiant ou le mot de passe.
    case unsupportedCredential
    case invalidPort(Int)
    /// RTSP, WebRTC et l'API (1984) ont chacun leur port.
    case portConflict

    public var errorDescription: String? {
        switch self {
        case let .unsupportedName(name): Localization.text("Le nom « \(name) » contient un caractère que go2rtc ne sait pas lire.")
        case .missingCredential: Localization.text("L'identifiant et le mot de passe RTSP sont obligatoires.")
        case .unsupportedCredential: Localization.text("L'identifiant ou le mot de passe contient un caractère interdit (saut de ligne, tabulation…).")
        case let .invalidPort(port): Localization.text("Port \(String(port)) invalide : choisissez un port entre 1024 et 65535.")
        case .portConflict: Localization.text("Les ports RTSP, WebRTC et 1984 doivent être différents.")
        }
    }
}

/// Le yaml de go2rtc écrit par PTZBot (spec B3 § 4) : le pipeline en service chez le premier utilisateur, paramétré.
public enum Go2RTCConfig {
    public static let fileName = "go2rtc.yaml"
    public static let validPorts = 1024...65535

    /// Le texte du yaml. Les entrées `exec:` sont des blocs repliés `- >-` (sans saut de ligne final), toutes leurs
    /// lignes au même retrait : repliées, elles ne font qu'une ligne, et `killsignal=15` n'est jamais suivi d'un saut
    /// de ligne (avec `- >`, go2rtc lirait le signal « 15\n », enverrait le signal 0, et le ffmpeg vidéo fuirait).
    public static func yaml(settings: Go2RTCSettings, ffmpeg: String, camera: String, microphone: String) throws(Go2RTCConfigError) -> String {
        let entries = try execEntries(settings: settings, ffmpeg: ffmpeg, camera: camera, microphone: microphone)
        var lines = [
            "# Écrit par PTZBot (Réglages › Caméra) : ne pas modifier, PTZBot le réécrit.",
            "# Written by PTZBot (Settings › Camera): do not edit, PTZBot rewrites it.",
            "api:",
            "  listen: \"127.0.0.1:\(Go2RTCSettings.apiPort)\"",
            "rtsp:",
            "  listen: \":\(settings.rtspPort)\"",
            "  username: \(quoted(settings.username))",
            "  password: \(quoted(settings.password))",
            "webrtc:",
            "  listen: \":\(settings.webrtcPort)\"",
            "ffmpeg:",
            "  bin: \(quoted(ffmpeg))",
            "log:",
            "  level: info",
            "preload:",
            "  \(Go2RTCSettings.streamName):",
            "streams:",
            "  \(Go2RTCSettings.streamName):",
        ]
        for entry in entries {
            lines.append("    - >-")
            lines += entry.map { "      " + $0 }
        }
        lines.append("    - ffmpeg:\(Go2RTCSettings.streamName)#audio=opus")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Les empreintes des entrées `exec:` du yaml (vidéo, puis micro), pour le ménage du gardien (`--capture`, spec B3
    /// § 3.2) : le chemin RTSP de leurs ffmpeg, `rtsp://127.0.0.1:<port>/<empreinte>`.
    public static func captureFingerprints(settings: Go2RTCSettings, ffmpeg: String, camera: String, microphone: String) throws(Go2RTCConfigError) -> [String] {
        try execEntries(settings: settings, ffmpeg: ffmpeg, camera: camera, microphone: microphone).map {
            fingerprint(ofSource: $0.joined(separator: " "))
        }
    }

    /// L'empreinte d'une source `exec:` telle que go2rtc 1.9.14 la calcule (`internal/exec`, `execHandle`) : la source
    /// coupée au premier `#` (le reste, ce sont ses paramètres), puis le MD5 de ses octets UTF-8, en hexadécimal
    /// minuscule ; go2rtc remplace `{output}` par `rtsp://127.0.0.1:<port>/<empreinte>`. La source est l'entrée repliée
    /// (`- >-` : lignes jointes par une espace).
    public static func fingerprint(ofSource source: String) -> String {
        let path = source.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Les deux entrées `exec:` (vidéo, puis micro), ligne à ligne, avant repli.
    static func execEntries(settings: Go2RTCSettings, ffmpeg: String, camera: String, microphone: String) throws(Go2RTCConfigError) -> [[String]] {
        try validate(settings)
        let program = try argument(ffmpeg)
        let rate = settings.framerate
        let size = "\(settings.resolution.width)x\(settings.resolution.height)"
        let output = "-rtsp_transport tcp -f rtsp {output}#timeout=30s#killsignal=15"
        let video = [
            "exec:\(program) -hide_banner -fflags nobuffer -flags low_delay",
            "-thread_queue_size 1024",
            "-f avfoundation -framerate \(rate) -video_size \(size) -pixel_format nv12 -probesize 32M",
            "-i \(try argument(camera))",
            "-c:v h264_videotoolbox -realtime 1 -g \(rate) -bf 0 -level 4.0",
            "-color_range mpeg -r \(rate)",
            "-b:v \(settings.videoBitrate) -maxrate \(settings.videoMaxrate) -bufsize \(settings.videoBuffer)",
            "-bsf:v dump_extra=freq=keyframe",
            "-an",
            output,
        ]
        let audio = [
            "exec:\(program) -hide_banner -fflags nobuffer -flags low_delay",
            "-thread_queue_size 2048",
            "-f avfoundation -i \(try argument(":" + microphone))",
            "-af aresample=async=1000:first_pts=0",
            "-c:a aac -ar 48000 -ac 2 -b:a 128k",
            "-vn",
            output,
        ]
        return [video, audio]
    }

    static func validate(_ settings: Go2RTCSettings) throws(Go2RTCConfigError) {
        guard !settings.username.isEmpty, !settings.password.isEmpty else { throw .missingCredential }
        guard !hasControlCharacters(settings.username), !hasControlCharacters(settings.password) else { throw .unsupportedCredential }
        for port in [settings.rtspPort, settings.webrtcPort] where !validPorts.contains(port) {
            throw .invalidPort(port)
        }
        guard Set([settings.rtspPort, settings.webrtcPort, Go2RTCSettings.apiPort]).count == 3 else { throw .portConflict }
    }

    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Un argument de la commande d'ffmpeg, tel que go2rtc le découpe (`shell.QuoteSplit`) : nu s'il n'a ni espace ni
    /// guillemet ; sinon entre guillemets doubles, ou simples s'il contient un guillemet double. go2rtc ne connaît pas
    /// d'échappement : un nom avec les deux sortes de guillemets, un `#` (fin de la source), un caractère de contrôle
    /// ou rien du tout est refusé.
    static func argument(_ value: String) throws(Go2RTCConfigError) -> String {
        let hasDouble = value.contains("\"")
        let hasSingle = value.contains("'")
        guard !value.isEmpty, !value.contains("#"), !hasControlCharacters(value), !(hasDouble && hasSingle) else {
            throw .unsupportedName(value)
        }
        if !hasDouble, !hasSingle, !value.contains(" ") {
            return value
        }
        return hasDouble ? "'\(value)'" : "\"\(value)\""
    }

    /// Une chaîne yaml entre guillemets doubles : `\` et `"` échappés (les caractères de contrôle sont refusés avant).
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// L'écriture du yaml.
public enum Go2RTCConfigFile {
    /// Écrit `text` dans `url`, de façon atomique (fichier temporaire du même dossier, puis `rename`), en mode 600 dès
    /// la création : le yaml porte le mot de passe RTSP. Un contenu identique n'est pas réécrit (son mode est remis à
    /// 600 au besoin). Rend true si le fichier a changé.
    @discardableResult
    public static func write(_ text: String, to url: URL) throws -> Bool {
        let data = Data(text.utf8)
        if let current = try? Data(contentsOf: url), current == data {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return false
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return true
    }
}
