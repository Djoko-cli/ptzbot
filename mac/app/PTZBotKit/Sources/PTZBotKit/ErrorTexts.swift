import Foundation
import NacelleProtocol

/// Les refus de ptzd, traduits d'après leur code (spec distribution § 7.2) : l'app ne montre plus le texte
/// français envoyé par ptzd, qui reste celui du journal et de la ligne de commande.
public enum ErrorTexts {
    /// Le texte montré pour un refus de ptzd. Pour `uvcFailed`, le motif connu du suivi IA, ou l'un des deux messages de la vie privée native, est repris de `message`.
    public static func text(for code: ErrorCode, message: String) -> String {
        switch code {
        case .privacyActive:
            Localization.text("Vie privée active : commande refusée.")
        case .cameraAbsent:
            Localization.text("Caméra débranchée.")
        case .uvcFailed:
            switch message {
            case PrivacyFailureText.fallbackToTilt:
                Labels.privacyFallbackNote
            case PrivacyFailureText.exitFailed:
                Localization.text("La vie privée n'a pas pu être levée : la caméra n'a pas répondu.")
            default:
                aiMotive(in: message).map(aiText) ?? Localization.text("La caméra a refusé la commande.")
            }
        case .badMessage:
            Localization.text("ptzd a refusé ce message.")
        case .unpaired:
            Localization.text("Appareil inconnu : appairez-le depuis PTZBot sur le Mac.")
        case .authFailed:
            Localization.text("Signature refusée.")
        case .badCode:
            Localization.text("QR code refusé.")
        case .pairingClosed:
            Localization.text("QR code expiré ou déjà utilisé : relancez l'appairage sur le Mac.")
        case .notAuthenticated:
            Localization.text("Authentification requise.")
        case .notLocal:
            Localization.text("Commande réservée au Mac.")
        case .blocked:
            Localization.text("Appareil expulsé pour quelques minutes.")
        }
    }

    /// Les motifs d'échec du suivi IA que ptzd envoie (`AIResult.userDescription`).
    enum AIMotive: Equatable, Sendable {
        case cameraNotFound
        case sdkError
        case timeout
        case launchFailed
        /// obsbot-ai d'avant cet ordre : il attend sa recompilation.
        case unknownOrder
        case unexpectedExit(String)
        /// Un message du suivi IA au motif inconnu (version de ptzd plus récente).
        case other
    }

    /// Le motif du suivi IA dans le message de ptzd, nil si ce n'est pas un échec du suivi IA. Les textes sont ceux
    /// que ptzd compose (`AIFailureText`, partagé par NacelleProtocol), jamais recopiés ici.
    static func aiMotive(in message: String) -> AIMotive? {
        guard let motive = AIFailureText.motive(in: message) else { return nil }
        switch motive {
        case AIFailureText.cameraNotFound: return .cameraNotFound
        case AIFailureText.sdkError: return .sdkError
        case AIFailureText.timeout: return .timeout
        case AIFailureText.launchFailed: return .launchFailed
        case AIFailureText.unknownOrder: return .unknownOrder
        default:
            if motive.hasPrefix(AIFailureText.unexpectedExitPrefix) {
                let status = String(motive.dropFirst(AIFailureText.unexpectedExitPrefix.count))
                if Int32(status) != nil {
                    return .unexpectedExit(status)
                }
            }
            return .other
        }
    }

    static func aiText(_ motive: AIMotive) -> String {
        switch motive {
        case .cameraNotFound:
            Localization.text("Suivi IA non modifié : caméra introuvable.")
        case .sdkError:
            Localization.text("Suivi IA non modifié : erreur du SDK OBSBOT.")
        case .timeout:
            Localization.text("Suivi IA non modifié : délai dépassé.")
        case .launchFailed:
            Localization.text("Suivi IA non modifié : obsbot-ai n'a pas pu être lancé.")
        case .unknownOrder:
            Localization.text("Suivi IA non modifié : obsbot-ai n'est pas à jour.")
        case let .unexpectedExit(code):
            Localization.text("Suivi IA non modifié : obsbot-ai s'est arrêté avec le code \(code).")
        case .other:
            Localization.text("Suivi IA non modifié.")
        }
    }
}
