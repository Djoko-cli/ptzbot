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

    /// Le motif, en français, pour les messages montrés à l'utilisateur (le journal garde la forme brute).
    public var userDescription: String {
        switch self {
        case .success: "réussi"
        case .cameraNotFound: AIFailureText.cameraNotFound
        case .sdkError: AIFailureText.sdkError
        case .timeout: AIFailureText.timeout
        case .launchFailed: AIFailureText.launchFailed
        case let .unexpectedExit(status): AIFailureText.unexpectedExitPrefix + String(status)
        }
    }
}

/// Un ordre de l'utilitaire : le suivi IA, ou la vie privée native de la caméra (spec § 6.5 bis).
enum AIOrder: Equatable, Sendable {
    case tracking(on: Bool)
    case privacy(on: Bool)

    /// La ligne écrite sur l'entrée de `obsbot-ai serve`.
    var line: String {
        switch self {
        case let .tracking(on): on ? "on" : "off"
        case let .privacy(on): on ? "privacy on" : "privacy off"
        }
    }
}

/// Allume (`on`) ou coupe le suivi IA de la caméra, et lui fait entrer ou quitter sa vie privée native.
@MainActor
public protocol AIRunner: AnyObject {
    func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void)
    /// Vie privée native de l'OBSBOT : image et micro coupés (spec § 6.5 bis). Même contrat que `run`.
    func runPrivacy(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void)
    /// L'utilitaire existe : sans lui (pas de SDK), la vie privée se limite à l'inclinaison de l'objectif.
    var supportsNativePrivacy: Bool { get }
    /// Un client pilote : l'utilitaire peut se préparer pour que le prochain ordre parte vite.
    func prewarm()
    /// La caméra a été branchée ou débranchée : l'utilitaire garde une session du SDK qui ne vaut plus.
    func reset()
}

extension AIRunner {
    public func prewarm() {}
    public func reset() {}
    public func runPrivacy(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        completion(.launchFailed("vie privée native indisponible"))
    }
    public var supportsNativePrivacy: Bool { false }
}
