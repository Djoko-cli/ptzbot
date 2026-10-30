import Foundation

/// Ce qui empêche de lancer go2rtc (spec B3 § 5) ; la ligne d'état le dit.
public enum Go2RTCBlock: Error, Equatable, Sendable {
    case ffmpegMissing
    case cameraMissing
    case microphoneMissing
    /// Le port est déjà tenu : un autre go2rtc tourne sans doute.
    case portBusy(Int)
    case customFileMissing
    /// Un réglage que le yaml refuse (`Go2RTCConfigError`), en clair.
    case invalidSettings(String)
    case writeFailed(String)
}

/// De quoi lancer go2rtc.
public struct Go2RTCLaunch: Equatable, Sendable {
    public var config: URL
    /// Le dossier de ffmpeg, en tête du PATH de go2rtc (nil : fichier personnalisé, ffmpeg introuvable).
    public var ffmpegDirectory: URL?
    /// Un fichier personnalisé : ni ports ni appareils vérifiés.
    public var custom: Bool
    /// Le port RTSP réglé, pour le ménage des ffmpeg du gardien (`--rtsp`) ; nil : pas de ménage.
    public var rtspPort: Int?
    /// Les empreintes des sources `exec:` du yaml généré (`--capture`) ; vides pour un fichier personnalisé : pas de
    /// ménage des orphelins.
    public var captures: [String]

    public init(config: URL, ffmpegDirectory: URL?, custom: Bool, rtspPort: Int? = nil, captures: [String] = []) {
        self.config = config
        self.ffmpegDirectory = ffmpegDirectory
        self.custom = custom
        self.rtspPort = rtspPort
        self.captures = captures
    }
}

public enum Go2RTCPreparation: Equatable, Sendable {
    case ready(Go2RTCLaunch)
    case blocked(Go2RTCBlock)
}

/// Prépare chaque lancement de go2rtc : ffmpeg, appareils, yaml, ports. Bloquant (`ffmpeg -version`, fichiers,
/// sockets) : le superviseur l'appelle hors du fil de l'interface.
public protocol Go2RTCPreparing: Sendable {
    func prepare(_ settings: Go2RTCSettings) async -> Go2RTCPreparation
    /// Écrit le yaml sans rien lancer (« Appliquer » go2rtc éteint) : les appareils réglés n'ont pas besoin d'être
    /// branchés. nil : c'est fait (ou fichier personnalisé : rien à écrire).
    func writeConfig(_ settings: Go2RTCSettings) async -> Go2RTCBlock?
}

public final class Go2RTCPreparer: Go2RTCPreparing {
    public let configURL: URL
    private let locator: FFmpegLocator
    private let catalog: any CaptureDeviceCatalog
    private let ports: any PortProbe

    public init(configURL: URL, locator: FFmpegLocator, catalog: any CaptureDeviceCatalog, ports: any PortProbe) {
        self.configURL = configURL
        self.locator = locator
        self.catalog = catalog
        self.ports = ports
    }

    /// Le préparateur de l'app : `go2rtc.yaml` de l'utilisateur, vrais appareils, vrai ffmpeg, vrais ports.
    public static func system(paths: AppPaths) -> Go2RTCPreparer {
        Go2RTCPreparer(configURL: paths.go2rtcConfig, locator: .system(), catalog: AVFoundationDeviceCatalog(), ports: SystemPortProbe())
    }

    /// Fichier personnalisé : lancé tel quel s'il se lit, avec le port RTSP réglé pour le ménage des enfants de go2rtc
    /// (le gardien ne juge que les ffmpeg dont la sortie vise ce port) et sans empreinte. Sinon : ffmpeg, appareils
    /// branchés, yaml (réécrit s'il a changé), puis les ports RTSP (TCP), WebRTC (TCP et UDP) et l'API (127.0.0.1:1984) ;
    /// le port RTSP et les empreintes des sources du yaml vont au ménage.
    public func prepare(_ settings: Go2RTCSettings) async -> Go2RTCPreparation {
        if settings.customConfigEnabled {
            guard let path = settings.customConfigPath, FileManager.default.isReadableFile(atPath: path) else {
                return .blocked(.customFileMissing)
            }
            let ffmpeg = locator.locate(configured: settings.ffmpegPath)
            return .ready(Go2RTCLaunch(config: URL(fileURLWithPath: path), ffmpegDirectory: ffmpeg?.deletingLastPathComponent(), custom: true,
                                       rtspPort: settings.rtspPort))
        }
        let generated: Generated
        switch generate(settings, requirePresence: true) {
        case let .failure(block): return .blocked(block)
        case let .success(found): generated = found
        }
        let checks: [(Int, PortTransport, Bool)] = [
            (settings.rtspPort, .tcp, false), (settings.webrtcPort, .tcp, false), (settings.webrtcPort, .udp, false),
            (Go2RTCSettings.apiPort, .tcp, true),
        ]
        for (port, transport, loopbackOnly) in checks where !ports.isFree(port, transport: transport, loopbackOnly: loopbackOnly) {
            return .blocked(.portBusy(port))
        }
        return .ready(Go2RTCLaunch(config: configURL, ffmpegDirectory: generated.ffmpeg.deletingLastPathComponent(), custom: false,
                                   rtspPort: settings.rtspPort, captures: generated.captures))
    }

    public func writeConfig(_ settings: Go2RTCSettings) async -> Go2RTCBlock? {
        guard !settings.customConfigEnabled else { return nil }
        if case let .failure(block) = generate(settings, requirePresence: false) {
            return block
        }
        return nil
    }

    private struct Generated {
        var ffmpeg: URL
        var captures: [String]
    }

    /// ffmpeg, les noms des appareils, puis le yaml, écrit s'il a changé. Rend le chemin de ffmpeg et les empreintes des
    /// sources du yaml. Sans `requirePresence`, un appareil réglé est écrit même débranché.
    private func generate(_ settings: Go2RTCSettings, requirePresence: Bool) -> Result<Generated, Go2RTCBlock> {
        guard let ffmpeg = locator.locate(configured: settings.ffmpegPath) else { return .failure(.ffmpegMissing) }
        let cameras = catalog.cameras()
        let microphones = catalog.microphones()
        let camera = requirePresence
            ? CaptureDeviceChoice.resolve(configured: settings.cameraName, in: cameras)
            : settings.cameraName ?? CaptureDeviceChoice.preferred(in: cameras)
        let microphone = requirePresence
            ? CaptureDeviceChoice.resolve(configured: settings.microphoneName, in: microphones)
            : settings.microphoneName ?? CaptureDeviceChoice.preferred(in: microphones)
        guard let camera else { return .failure(.cameraMissing) }
        guard let microphone else { return .failure(.microphoneMissing) }
        let text: String
        let captures: [String]
        do {
            text = try Go2RTCConfig.yaml(settings: settings, ffmpeg: ffmpeg.path, camera: camera, microphone: microphone)
            captures = try Go2RTCConfig.captureFingerprints(settings: settings, ffmpeg: ffmpeg.path, camera: camera, microphone: microphone)
        } catch {
            return .failure(.invalidSettings(error.localizedDescription))
        }
        do {
            try Go2RTCConfigFile.write(text, to: configURL)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
        return .success(Generated(ffmpeg: ffmpeg, captures: captures))
    }
}
