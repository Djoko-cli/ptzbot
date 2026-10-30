import Foundation
import NacelleProtocol

/// La pastille d'un service dans le panneau (spec B3 § 6.1) : verte à l'état normal (actif, prêt, installé), sans
/// ligne ; sinon la ligne d'état, en orange quand il faut agir ou regarder le journal, en rouge pour un échec.
public struct ServiceIndicator: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Pastille verte.
        case normal
        /// Éteint, démarrage, arrêt : pastille grise.
        case neutral
        /// Orange : une action, ou un coup d'œil au journal.
        case attention
        /// Rouge : en échec.
        case failure
    }

    public var tone: Tone
    /// nil à l'état normal : la pastille suffit.
    public var line: String?

    public init(tone: Tone, line: String?) {
        self.tone = tone
        self.line = line
    }

    public static let normal = ServiceIndicator(tone: .normal, line: nil)
}

extension Labels {
    /// ptzd : actif quand la connexion de confiance est établie (spec ptzd dans l'app § 6.1). En échec, la ligne est la
    /// raison.
    public static func ptzdIndicator(_ state: ServiceSupervisor.State, connection: PanelModel.Service, legacy: Bool) -> ServiceIndicator {
        if legacy {
            return connection == .active
                ? ServiceIndicator(tone: .attention, line: service(state, connection: connection, legacy: true))
                : ServiceIndicator(tone: .attention, line: service(connection))
        }
        switch state {
        case .running where connection == .active:
            return .normal
        case .running where connection == .unreachable:
            return ServiceIndicator(tone: .attention, line: service(connection))
        case let .failed(reason):
            return ServiceIndicator(tone: .failure, line: reason)
        case .restarting:
            return ServiceIndicator(tone: .attention, line: service(state, connection: connection, legacy: false))
        case .stopped, .starting, .running:
            return ServiceIndicator(tone: .neutral, line: service(state, connection: connection, legacy: false))
        }
    }

    /// Talkback : prêt ou en lecture, c'est l'état normal.
    public static func talkbackIndicator(_ status: TalkbackModel.Status) -> ServiceIndicator {
        switch status {
        case .ready, .playing:
            .normal
        case .disabled, .starting, .stopping:
            ServiceIndicator(tone: .neutral, line: talkbackStatus(status))
        case .requiresApproval, .failed, .notRunning:
            ServiceIndicator(tone: .attention, line: talkbackStatus(status))
        }
    }

    /// Le SDK OBSBOT : prêt, c'est l'état normal ; sinon son état court, à droite de la ligne.
    public static func sdkIndicator(_ status: SDKStatus?) -> ServiceIndicator {
        switch status {
        case .ready:
            .normal
        case nil, .recompiling:
            ServiceIndicator(tone: .neutral, line: sdk(status))
        case .absent, .quarantined, .incompatible, .unloadable, .sourceMissing, .toolsRequired, .incomplete, .compileFailed:
            ServiceIndicator(tone: .attention, line: sdk(status))
        }
    }

    /// go2rtc (spec B3 § 5) : l'état du superviseur, puis, quand il tourne, les alertes (coreaudiod d'abord, puis les
    /// captures ffmpeg bloquées). Un fichier personnalisé le dit, pastille verte.
    public static func go2rtcIndicator(_ state: Go2RTCSupervisor.State, isEnabled: Bool, usesCustomFile: Bool, health: Go2RTCHealth) -> ServiceIndicator {
        guard isEnabled else {
            return ServiceIndicator(tone: .neutral, line: Localization.text("Désactivé"))
        }
        switch state {
        case .stopped:
            return ServiceIndicator(tone: .neutral, line: Localization.text("Arrêté"))
        case .starting:
            return ServiceIndicator(tone: .neutral, line: Localization.text("Démarrage…"))
        case let .restarting(count):
            return ServiceIndicator(tone: .attention, line: Localization.text("Relancé après un arrêt inattendu (\(count))"))
        case let .failed(failure):
            return ServiceIndicator(tone: go2rtcFailureTone(failure), line: go2rtcFailure(failure))
        case .running:
            if health.coreAudioStuck {
                return ServiceIndicator(tone: .attention, line: coreAudioStuck)
            }
            if health.capturesStuck {
                return ServiceIndicator(tone: .attention, line: capturesStuck)
            }
            if health.accessDenied {
                return ServiceIndicator(tone: .attention, line: cameraAccessDenied)
            }
            if health.cameraMissing {
                return ServiceIndicator(tone: .attention, line: go2rtcBlock(.cameraMissing))
            }
            return usesCustomFile ? ServiceIndicator(tone: .normal, line: customConfigFile) : .normal
        }
    }

    /// Ce qui a empêché le lancement.
    public static func go2rtcBlock(_ block: Go2RTCBlock) -> String {
        switch block {
        case .ffmpegMissing: Localization.text("ffmpeg introuvable")
        case .cameraMissing: Localization.text("Caméra OBSBOT absente")
        case .microphoneMissing: Localization.text("Micro OBSBOT absent")
        case let .portBusy(port): Localization.text("Port \(String(port)) déjà utilisé : un autre go2rtc tourne-t-il ?")
        case .customFileMissing: Localization.text("Fichier de configuration personnalisé introuvable")
        case let .invalidSettings(message): message
        case let .writeFailed(reason): Localization.text("go2rtc.yaml n'a pas pu être écrit : \(reason)")
        }
    }

    public static func go2rtcFailure(_ failure: Go2RTCFailure) -> String {
        switch failure {
        case let .blocked(block): go2rtcBlock(block)
        case .crashLoop: Localization.text("go2rtc s'arrête sans cesse : ouvrez le journal")
        case let .launch(reason): Localization.text("go2rtc n'a pas pu être lancé : \(reason)")
        case .missingBinary: Localization.text("go2rtc manque dans PTZBot : réinstallez PTZBot")
        case .unkillable: Localization.text("go2rtc ne s'arrête pas : ouvrez le journal")
        }
    }

    /// Orange pour ce qu'on peut corriger soi-même (ffmpeg, appareil, port, réglage) ; rouge pour le reste.
    static func go2rtcFailureTone(_ failure: Go2RTCFailure) -> ServiceIndicator.Tone {
        switch failure {
        case .blocked(.writeFailed), .crashLoop, .launch, .missingBinary, .unkillable: .failure
        case .blocked: .attention
        }
    }

    /// Le survol de la rangée go2rtc : le nombre de clients et le détail par protocole ; nil sans lecture de l'API.
    public static func go2rtcHelp(_ stream: Go2RTCStreamStatus?) -> String? {
        guard let clients = stream?.clients else { return nil }
        let count = clients.total
        switch count {
        case 0: return Localization.text("Aucun client")
        case 1: return Localization.text("1 client · \(go2rtcClientsDetail(clients))")
        default: return Localization.text("\(count) clients · \(go2rtcClientsDetail(clients))")
        }
    }

    /// « RTSP ×1, WebRTC ×1 » : les protocoles connus d'abord, dans cet ordre.
    public static func go2rtcClientsDetail(_ clients: Go2RTCClients) -> String {
        let order = ["rtsp", "webrtc", "mse", "hls", "mjpeg"]
        let names = ["rtsp": "RTSP", "webrtc": "WebRTC", "mse": "MSE", "hls": "HLS", "mjpeg": "MJPEG"]
        let sorted = clients.byType.keys.sorted { left, right in
            (order.firstIndex(of: left) ?? order.count, left) < (order.firstIndex(of: right) ?? order.count, right)
        }
        return sorted.map { type in
            let name = names[type] ?? (type.isEmpty ? Localization.text("autre") : type.uppercased())
            return "\(name) ×\(clients.byType[type] ?? 0)"
        }.joined(separator: ", ")
    }

    public static var coreAudioStuck: String { Localization.text("coreaudiod ne répond pas : la caméra est bloquée") }
    /// Sans commande de réparation : le gardien nettoie les ffmpeg décrochés (spec B3 § 3.2).
    public static var capturesStuck: String { Localization.text("Des captures ffmpeg sont bloquées : nettoyage en cours") }
    public static var cameraAccessDenied: String { Localization.text("Accès à la caméra refusé") }
    public static var customConfigFile: String { Localization.text("Fichier de configuration personnalisé") }
    /// La confirmation de « Quitter » quand go2rtc est allumé (spec B3 § 3.3).
    public static var quitStopsCamera: String { Localization.text("Quitter PTZBot arrête aussi la caméra HomeKit.") }
}
