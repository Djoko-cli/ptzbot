import Foundation
@testable import PTZBotKit

/// La préparation de go2rtc simulée : le test choisit le résultat ; `holds` la retient jusqu'à `release()`.
/// Appelée hors du fil principal (Task.detached), d'où le verrou.
final class FakePreparer: Go2RTCPreparing, @unchecked Sendable {
    /// Des empreintes inventées.
    static let fingerprints = ["0123456789abcdef0123456789abcdef", "fedcba9876543210fedcba9876543210"]
    static let readyLaunch = Go2RTCLaunch(
        config: URL(fileURLWithPath: "/support/go2rtc.yaml"),
        ffmpegDirectory: URL(fileURLWithPath: "/opt/homebrew/bin"),
        custom: false,
        rtspPort: 8554,
        captures: fingerprints
    )

    private let lock = NSLock()
    private var _result: Go2RTCPreparation = .ready(FakePreparer.readyLaunch)
    private var _queued: [Go2RTCPreparation] = []
    private var _writeResult: Go2RTCBlock?
    private var _prepared: [Go2RTCSettings] = []
    private var _written: [Go2RTCSettings] = []
    private var _onMainThread: [Bool] = []
    private var _holds = false
    private var held: CheckedContinuation<Void, Never>?

    var result: Go2RTCPreparation {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    /// Les résultats des prochaines préparations, dans l'ordre ; ensuite, `result`.
    var queued: [Go2RTCPreparation] {
        get { lock.withLock { _queued } }
        set { lock.withLock { _queued = newValue } }
    }

    var writeResult: Go2RTCBlock? {
        get { lock.withLock { _writeResult } }
        set { lock.withLock { _writeResult = newValue } }
    }

    var holds: Bool {
        get { lock.withLock { _holds } }
        set { lock.withLock { _holds = newValue } }
    }

    /// Les réglages de chaque préparation, dans l'ordre.
    var prepared: [Go2RTCSettings] { lock.withLock { _prepared } }
    /// Les réglages de chaque `writeConfig`.
    var written: [Go2RTCSettings] { lock.withLock { _written } }
    /// Pour chaque préparation : tournait-elle sur le fil principal ?
    var onMainThread: [Bool] { lock.withLock { _onMainThread } }
    var isHeld: Bool { lock.withLock { held != nil } }

    func prepare(_ settings: Go2RTCSettings) async -> Go2RTCPreparation {
        let onMain = pthread_main_np() != 0
        lock.withLock {
            _prepared.append(settings)
            _onMainThread.append(onMain)
        }
        if holds {
            await withCheckedContinuation { continuation in
                lock.withLock { held = continuation }
            }
        }
        return lock.withLock { _queued.isEmpty ? _result : _queued.removeFirst() }
    }

    func writeConfig(_ settings: Go2RTCSettings) async -> Go2RTCBlock? {
        lock.withLock {
            _written.append(settings)
            return _writeResult
        }
    }

    /// Laisse finir la préparation retenue.
    func release() {
        let continuation = lock.withLock {
            let continuation = held
            held = nil
            _holds = false
            return continuation
        }
        continuation?.resume()
    }
}

/// Les ports simulés : chaque essai est noté (« 8554/tcp », « 8555/udp », « 1984/tcp/127.0.0.1 ») ; `busy` les prend.
final class FakePorts: PortProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _busy: Set<String> = []
    private var _probed: [String] = []

    static func key(_ port: Int, _ transport: PortTransport, _ loopbackOnly: Bool) -> String {
        "\(port)/\(transport == .tcp ? "tcp" : "udp")\(loopbackOnly ? "/127.0.0.1" : "")"
    }

    var probed: [String] { lock.withLock { _probed } }

    func busy(_ keys: String...) {
        lock.withLock { _busy.formUnion(keys) }
    }

    func isFree(_ port: Int, transport: PortTransport, loopbackOnly: Bool) -> Bool {
        let key = Self.key(port, transport, loopbackOnly)
        return lock.withLock {
            _probed.append(key)
            return !_busy.contains(key)
        }
    }
}

/// Les appareils simulés : par défaut, une caméra OBSBOT virtuelle avant la vraie, et le micro OBSBOT.
struct FakeCatalog: CaptureDeviceCatalog {
    var cameraList = [
        CaptureDeviceInfo(name: "OBSBOT Virtual Camera", isVirtual: true),
        CaptureDeviceInfo(name: Go2RTCFixtures.camera, isVirtual: false),
    ]
    var microphoneList = [CaptureDeviceInfo(name: Go2RTCFixtures.microphone, isVirtual: false)]

    func cameras() -> [CaptureDeviceInfo] {
        cameraList
    }

    func microphones() -> [CaptureDeviceInfo] {
        microphoneList
    }
}

extension FFmpegLocator {
    /// ffmpeg de Homebrew présent et qui répond.
    static let homebrew = FFmpegLocator(isExecutable: { $0 == Go2RTCFixtures.ffmpeg }, respondsToVersion: { _ in true })
    /// ffmpeg introuvable.
    static let missing = FFmpegLocator(isExecutable: { _ in false }, respondsToVersion: { _ in false })
}
