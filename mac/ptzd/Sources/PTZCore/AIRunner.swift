import Foundation
import NacelleProtocol

/// Issue d'un ordre donné à obsbot-ai (spec § 6.9, spec app Mac § 7.5).
public enum AIResult: Equatable, Sendable {
    case success
    case cameraNotFound
    case sdkError
    case timeout
    case launchFailed(String)
    case unexpectedExit(Int32)
    /// « Ordre inconnu » (code 3) : obsbot-ai est d'avant cet ordre et attend sa recompilation (spec § 6.5 bis). Ce n'est
    /// pas un échec de la caméra.
    case unknownOrder

    /// Le motif, en français, pour les messages montrés à l'utilisateur (le journal garde la forme brute).
    public var userDescription: String {
        switch self {
        case .success: "réussi"
        case .cameraNotFound: AIFailureText.cameraNotFound
        case .sdkError: AIFailureText.sdkError
        case .timeout: AIFailureText.timeout
        case .launchFailed: AIFailureText.launchFailed
        case let .unexpectedExit(status): AIFailureText.unexpectedExitPrefix + String(status)
        case .unknownOrder: AIFailureText.unknownOrder
        }
    }
}

/// État réel de la caméra, lu par `privacy status` (spec § 6.5 bis). obsbot-ai rend `privacy` pour l'état brut 3 ou 4
/// (la Tiny 2 rend 3 en vie privée native, mesuré le 19/10), `run` pour 1 ; toute autre valeur est une erreur.
public enum CameraRunState: String, Equatable, Sendable {
    /// Éveillée : image et micro en service.
    case run
    /// Mode vie privée natif : image noire, micro coupé.
    case privacy
}

/// Issue d'une lecture de l'état réel : l'état lu, ou l'échec de l'ordre. `pitch` est le second témoin : l'inclinaison
/// de la nacelle lue par le SDK (`gimbalGetAttitudeInfoR`, en degrés, positive vers le bas ; environ 70 à −70° UVC,
/// 85 en vie privée native), nil si elle ne se lit pas. Elle accompagne aussi un état illisible.
public enum PrivacyReading: Equatable, Sendable {
    case state(CameraRunState, pitch: Double? = nil)
    case failed(AIResult, pitch: Double? = nil)
}

/// Réglage d'exposition de la caméra : l'obturation et le mode (spec § 6.11). Pour la Tiny 2, c'est tout ce que le SDK lit
/// et écrit (`cameraGetExposureAbsolute`, `cameraSetExposureAbsolute`) ; le gain reste celui d'OBSBOT Center.
public struct ExposureSetting: Codable, Equatable, Sendable {
    public var shutter: Int
    /// Exposition automatique en vigueur (true), ou réglage manuel (false).
    public var auto: Bool

    public init(shutter: Int, auto: Bool) {
        self.shutter = shutter
        self.auto = auto
    }
}

/// Issue d'une lecture du réglage d'exposition : le réglage lu, ou l'échec de l'ordre.
public enum ExposureReading: Equatable, Sendable {
    case setting(ExposureSetting)
    case failed(AIResult)
}

/// Un ordre de l'utilitaire : le suivi IA, la vie privée native de la caméra, la lecture de son état réel
/// (spec § 6.5 bis), ou l'exposition (spec § 6.11).
enum AIOrder: Equatable, Sendable {
    case tracking(on: Bool)
    case privacy(on: Bool)
    case privacyStatus
    case exposureStatus
    case exposure(ExposureSetting)

    /// La ligne écrite sur l'entrée de `obsbot-ai serve`.
    var line: String {
        switch self {
        case let .tracking(on): on ? "on" : "off"
        case let .privacy(on): on ? "privacy on" : "privacy off"
        case .privacyStatus: "privacy status"
        case .exposureStatus: "exposure status"
        case let .exposure(setting): "exposure set \(setting.shutter) \(setting.auto ? "auto" : "manual")"
        }
    }
}

/// Allume (`on`) ou coupe le suivi IA de la caméra, lui fait entrer ou quitter sa vie privée native, lit son état
/// réel, et règle son exposition. L'utilitaire ne traite qu'un ordre à la fois : un ordre donné pendant un autre est refusé
/// (`launchFailed`) ; `AIOrderQueue` les met à la file.
@MainActor
public protocol AIRunner: AnyObject {
    func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void)
    /// Vie privée native de l'OBSBOT : image et micro coupés (spec § 6.5 bis). Même contrat que `run`.
    func runPrivacy(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void)
    /// Lit l'état réel de la caméra (`privacy status`, spec § 6.5 bis).
    func readPrivacy(completion: @escaping @MainActor @Sendable (PrivacyReading) -> Void)
    /// Lit le réglage d'exposition de la caméra (`exposure status`, spec § 6.11).
    func readExposure(completion: @escaping @MainActor @Sendable (ExposureReading) -> Void)
    /// Applique un réglage d'exposition (`exposure set`, spec § 6.11). Même contrat que `run`.
    func runExposure(_ setting: ExposureSetting, completion: @escaping @MainActor @Sendable (AIResult) -> Void)
    /// L'utilitaire existe : sans lui (pas de SDK), la vie privée se limite à l'inclinaison de l'objectif.
    var supportsNativePrivacy: Bool { get }
    /// Le SDK est prêt : l'utilitaire tourne et sa session a trouvé la caméra (« ready »). Un ordre part alors en
    /// quelques millisecondes ; sinon il attend une session neuve, environ 4 s (spec § 6.5 bis, « Accélération »).
    var isReady: Bool { get }
    /// L'utilitaire reste chargé tant que ptzd tourne (ptzd lancé avec le SDK, spec § 6.9) : il n'est plus arrêté pour
    /// inactivité, et ptzd le prépare dès le démarrage, au branchement de la caméra et après une mise à jour.
    var keepsWarm: Bool { get }
    /// L'utilitaire peut se préparer pour que le prochain ordre parte vite (un client pilote, ou ptzd le garde chaud).
    func prewarm()
    /// La caméra a été branchée ou débranchée, ou obsbot-ai a été recompilé : l'utilitaire garde une session du SDK
    /// (ou un programme) qui ne vaut plus. L'ordre en cours échoue.
    func reset()
}

extension AIRunner {
    public func prewarm() {}
    public func reset() {}
    public func runPrivacy(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        completion(.launchFailed("vie privée native indisponible"))
    }
    public func readPrivacy(completion: @escaping @MainActor @Sendable (PrivacyReading) -> Void) {
        completion(.failed(.launchFailed("vie privée native indisponible"), pitch: nil))
    }
    public func readExposure(completion: @escaping @MainActor @Sendable (ExposureReading) -> Void) {
        completion(.failed(.launchFailed("exposition indisponible")))
    }
    public func runExposure(_ setting: ExposureSetting, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        completion(.launchFailed("exposition indisponible"))
    }
    public var supportsNativePrivacy: Bool { false }
    public var isReady: Bool { false }
    public var keepsWarm: Bool { false }
}
