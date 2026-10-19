import Foundation
import NacelleProtocol

/// Ce que le bandeau d'état doit connaître.
struct BannerInputs: Equatable {
    var macUnreachable: Bool
    /// Ce qui empêche l'authentification auprès de ptzd.
    var authIssue: PTZClient.AuthIssue? = nil
    /// WebSocket ou vidéo en cours de connexion.
    var connecting: Bool
    var state: StateSnapshot?
}

/// Texte du bandeau d'état (spec § 7.3, spec accès local § 8.5, spec découverte et QR § 8.4). Ordre de
/// priorité : Mac injoignable, appairage, caméra débranchée, vie privée, suivi IA non coupé, connexion.
/// Un ordre de suivi IA en cours (`control == .taking`) n'a pas de bandeau : le bouton du suivi IA l'indique.
enum StatusBanner {
    static let qrRefused = "QR code refusé : relancez l'appairage sur le Mac"

    // Vie privée (spec § 6.5 bis). « Image et micro coupés » seulement quand ptzd a constaté le mode natif ; « protection
    // en cours » tant que l'objectif n'a pas été vu détourné (rebranchement, démarrage, réveil de la caméra) ; sinon
    // l'objectif est seulement détourné, et la raison donnée par ptzd dit pourquoi.
    static let privacy = "Vie privée"
    static let privacyNative = "Vie privée : image et micro coupés"
    /// L'objectif n'a pas encore été vu à −70°, et le mode natif n'est pas lu.
    static let privacyPending = "Vie privée : protection en cours"
    /// Mode natif en cours, pas encore constaté.
    static let privacyTilt = "Vie privée : objectif détourné"
    static let privacyNoSDK = "Vie privée : objectif seulement détourné. Sans le SDK OBSBOT sur le Mac, l'image et le micro ne sont pas coupés."
    static let privacyUpdating = "Vie privée : objectif seulement détourné, en attendant la mise à jour du SDK OBSBOT sur le Mac."
    static let privacyFailed = "Vie privée : objectif seulement détourné, l'image et le micro n'ont pas pu être coupés."

    /// Le texte de la vie privée selon le mode et la raison publiés par ptzd ; le texte d'avant pour un ptzd ancien.
    static func privacyText(mode: PrivacyMode?, reason: PrivacyReason?) -> String {
        switch mode {
        case .native: privacyNative
        case nil: privacy
        case .tilt:
            switch reason {
            case nil: privacyTilt
            case .pending: privacyPending
            case .noSDK: privacyNoSDK
            case .updating: privacyUpdating
            case .failed: privacyFailed
            }
        }
    }

    // Enregistrement (spec enregistrement § 6).
    static let photosDenied = "L'accès à Photos est refusé : autorisez-le dans Réglages › PTZBot › Photos."
    static let lowSpaceAtStart = "Espace insuffisant sur l'iPhone pour enregistrer."
    static let lowSpaceStopped = "Enregistrement arrêté : espace insuffisant."
    static let recordingFailed = "L'enregistrement a échoué."
    static let photosFailed = "La vidéo n'a pas pu être ajoutée à Photos."

    // Parole (spec parler § 6.1).
    static let speakTalkbackOff = "Talkback est éteint sur le Mac"
    static let speakNoConnection = "Pas de connexion au Mac"
    static let speakNoVideo = "La vidéo n'est pas connectée : la parole a besoin du son de la caméra."
    static let micDenied = "L'accès au micro est refusé : autorisez-le dans Réglages › PTZBot"
    static let micFailed = "Le micro n'a pas pu démarrer."

    /// « Vidéo enregistrée dans Photos (0:42) » ; sans durée connue (réessai d'un fichier resté), sans parenthèses.
    static func saved(duration: TimeInterval?) -> String {
        guard let duration else { return "Vidéo enregistrée dans Photos" }
        return "Vidéo enregistrée dans Photos (\(RecordingFormat.duration(duration)))"
    }

    static func text(for inputs: BannerInputs) -> String? {
        if inputs.macUnreachable {
            return "Mac injoignable : Tailscale est-il actif ?"
        }
        switch inputs.authIssue {
        case .unpaired:
            return "iPhone non appairé : scannez le QR code affiché sur le Mac"
        case .badCode:
            return qrRefused
        case .rejected:
            return "Accès refusé par le Mac"
        case .blocked:
            return "Expulsé par le Mac : réessayez plus tard"
        case nil:
            break
        }
        if let state = inputs.state {
            if state.camera == .absent {
                return "Caméra débranchée"
            }
            if state.privacy {
                return privacyText(mode: state.privacyMode, reason: state.privacyReason)
            }
            if state.control == .failed {
                return "Suivi IA non coupé : les mouvements peuvent être contrés"
            }
        }
        return inputs.connecting ? "Connexion…" : nil
    }
}
