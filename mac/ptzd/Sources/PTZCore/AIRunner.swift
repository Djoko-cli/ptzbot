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

/// Un ordre de l'utilitaire : le suivi IA, la vie privée native de la caméra, ou la lecture de son état réel
/// (spec § 6.5 bis).
enum AIOrder: Equatable, Sendable {
    case tracking(on: Bool)
    case privacy(on: Bool)
    case privacyStatus

    /// La ligne écrite sur l'entrée de `obsbot-ai serve`.
    var line: String {
        switch self {
        case let .tracking(on): on ? "on" : "off"
        case let .privacy(on): on ? "privacy on" : "privacy off"
        case .privacyStatus: "privacy status"
        }
    }
}

/// Allume (`on`) ou coupe le suivi IA de la caméra, lui fait entrer ou quitter sa vie privée native, et lit son état
/// réel. L'utilitaire ne traite qu'un ordre à la fois : un ordre donné pendant un autre est refusé
/// (`launchFailed`) ; `AIOrderQueue` les met à la file.
@MainActor
public protocol AIRunner: AnyObject {
    func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void)
    /// Vie privée native de l'OBSBOT : image et micro coupés (spec § 6.5 bis). Même contrat que `run`.
    func runPrivacy(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void)
    /// Lit l'état réel de la caméra (`privacy status`, spec § 6.5 bis).
    func readPrivacy(completion: @escaping @MainActor @Sendable (PrivacyReading) -> Void)
    /// L'utilitaire existe : sans lui (pas de SDK), la vie privée se limite à l'inclinaison de l'objectif.
    var supportsNativePrivacy: Bool { get }
    /// Un client pilote : l'utilitaire peut se préparer pour que le prochain ordre parte vite.
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
    public var supportsNativePrivacy: Bool { false }
}
