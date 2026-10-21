import Foundation
import NacelleProtocol

/// Les textes du service, du SDK et de la migration (spec ptzd dans l'app § 5.6, § 6.1 et § 6.2), au vouvoiement,
/// traduits en anglais (spec distribution § 7.1).
extension Labels {
    /// L'état sous le titre : la supervision de ptzd, puis la connexion de confiance pour « Actif ».
    public static func service(_ state: ServiceSupervisor.State, connection: PanelModel.Service, legacy: Bool) -> String {
        if legacy {
            return Localization.text("Ancienne installation")
        }
        switch state {
        case .stopped, .failed:
            return Localization.text("Arrêté")
        case .starting:
            return Localization.text("Démarrage…")
        case let .restarting(count):
            return Localization.text("Relancé après un arrêt inattendu (\(count))")
        case .running:
            return service(connection)
        }
    }

    /// Service éteint ou en échec : tout est grisé sauf l'interrupteur, le SDK, « Ouvrir à la connexion »
    /// et « Quitter ». Ancienne installation : seule la connexion décide.
    public static func controlsEnabled(_ state: ServiceSupervisor.State, connection: PanelModel.Service, legacy: Bool) -> Bool {
        guard connection == .active else { return false }
        if legacy {
            return true
        }
        switch state {
        case .running: return true
        case .stopped, .starting, .restarting, .failed: return false
        }
    }

    /// Le journal est proposé quand ptzd ne répond pas ou s'arrête sans cesse.
    public static func showsLog(_ state: ServiceSupervisor.State, connection: PanelModel.Service) -> Bool {
        if case .failed = state {
            return true
        }
        return state == .running && connection == .unreachable
    }

    /// L'état court, à droite de la ligne « SDK OBSBOT » ; l'explication va dessous (`sdkDetail`).
    public static func sdk(_ status: SDKStatus?) -> String {
        switch status {
        case .ready: Localization.text("Prêt")
        case .absent: Localization.text("Absent")
        case .quarantined: Localization.text("En quarantaine")
        case .incompatible: Localization.text("Incompatible")
        case .unloadable: Localization.text("Ne se charge pas")
        case .sourceMissing: Localization.text("obsbot-ai introuvable")
        case .toolsRequired: Localization.text("Outils requis")
        case .incomplete: Localization.text("À compléter")
        case .recompiling: Localization.text("Recompilation…")
        case .compileFailed: Localization.text("Compilation impossible")
        case nil: Localization.text("Vérification…")
        }
    }

    /// La petite ligne sous « SDK OBSBOT », sur toute la largeur : ce que l'état veut dire et quoi faire ; nil si
    /// l'état se suffit. Quand les outils manquent et que le bouton les installe, elle le dit aussi.
    public static func sdkDetail(_ status: SDKStatus?, toolsAvailable: Bool = true) -> String? {
        var parts: [String] = []
        switch status {
        case .incomplete:
            parts.append(sdkIncompleteDetail)
        case let .toolsRequired(fallback):
            parts.append(sdkToolsDetail)
            if fallback {
                parts.append(sdkFallback)
            }
        case let .compileFailed(fallback):
            if fallback {
                parts.append(sdkFallback)
            }
            parts.append(compileLogHint)
        case .quarantined:
            parts.append(sdkQuarantinedDetail)
        case .incompatible:
            parts.append(sdkIncompatibleDetail)
        case .unloadable:
            parts.append(sdkUnloadableDetail)
        case .sourceMissing:
            parts.append(sdkSourceMissingDetail)
        case .ready, .absent, .recompiling, nil:
            break
        }
        if case .toolsRequired = status {
            // Déjà dit par sdkToolsDetail.
        } else if sdkActionInstallsTools(status, toolsAvailable: toolsAvailable) {
            parts.append(sdkToolsFirst)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public static var sdkFallback: String { Localization.text("L'ancien obsbot-ai reste en service.") }
    public static var compileLogHint: String { Localization.text("Le détail est dans le journal obsbot-ai-compilation.log.") }
    public static var sdkIncompleteDetail: String { Localization.text("Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent.") }
    public static var sdkToolsDetail: String { Localization.text("Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai.") }
    public static var sdkQuarantinedDetail: String { Localization.text("Le SDK ne se charge pas : réinstallez-le pour retirer la quarantaine de sa copie.") }
    public static var sdkIncompatibleDetail: String { Localization.text("Ce SDK n'a pas de version pour Apple Silicon.") }
    public static var sdkUnloadableDetail: String { Localization.text("obsbot-ai ne charge pas ce SDK : réinstallez-le.") }
    public static var sdkSourceMissingDetail: String { Localization.text("La source d'obsbot-ai manque dans l'app : réinstallez PTZBot.") }
    public static var sdkToolsFirst: String { Localization.text("Installez d'abord les outils de développement d'Apple.") }

    /// Le bouton de la ligne SDK : « Changer… » quand il est prêt (la fenêtre reste joignable), « Installer les
    /// outils de développement… » quand ils manquent (obsbot-ai ne pourrait pas être compilé), « Installer le SDK… »
    /// sinon ; aucun pendant la vérification ou la recompilation.
    public static func sdkAction(_ status: SDKStatus?, toolsAvailable: Bool = true) -> String? {
        if sdkActionInstallsTools(status, toolsAvailable: toolsAvailable) {
            return installTools
        }
        switch status {
        case nil, .recompiling, .sourceMissing: return nil
        case .ready: return Localization.text("Changer…")
        case .toolsRequired: return installTools
        case .absent, .quarantined, .incompatible, .unloadable, .incomplete, .compileFailed: return Localization.text("Installer le SDK…")
        }
    }

    /// Le bouton de la ligne SDK lance `xcode-select --install` plutôt que d'ouvrir l'onglet « SDK OBSBOT » des Réglages :
    /// les outils manquent et le SDK est à installer (ou obsbot-ai à compiler). Sur le clic de l'utilisateur seulement.
    public static func sdkActionInstallsTools(_ status: SDKStatus?, toolsAvailable: Bool = true) -> Bool {
        switch status {
        case .toolsRequired:
            return true
        case .absent, .quarantined, .incompatible, .unloadable, .incomplete, .compileFailed:
            return !toolsAvailable
        case nil, .ready, .recompiling, .sourceMissing:
            return false
        }
    }

    /// La fenêtre « SDK OBSBOT » quand les outils manquent : elle propose de les installer avant de choisir le SDK.
    public static var sdkToolsExplanation: String { Localization.text("Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai avec le SDK. Installez-les, puis vérifiez à nouveau.") }
    public static var checkToolsAgain: String { Localization.text("Vérifier à nouveau") }

    public static var installTools: String { Localization.text("Installer les outils de développement…") }

    public static var replaceLegacy: String { Localization.text("Remplacer l'ancienne installation…") }

    // MARK: - Sections du panneau

    public static var serviceSection: String { Localization.text("Service") }
    public static var noIPhone: String { Localization.text("Aucun iPhone connecté") }

    /// « Caméra · branchée » ou « Caméra · débranchée » (débranchée aussi hors connexion).
    public static func cameraSection(_ presence: CameraPresence?) -> String {
        presence == .connected ? Localization.text("Caméra · branchée") : Localization.text("Caméra · débranchée")
    }

    /// « iPhone connectés · n ».
    public static func iPhoneSection(count: Int) -> String {
        Localization.text("iPhone connectés · \(count)")
    }

    /// La petite ligne sous « Suivi IA » : le SDK manque, ou l'état ne se lit pas.
    public static func aiNote(_ tracking: AITracking?, needsSDK: Bool) -> String? {
        if needsSDK {
            return sdkRequired
        }
        return tracking == .unknown ? Localization.text("État inconnu") : nil
    }

    /// L'icône de l'exposition automatique, la même que sur iOS pour que la fonction se reconnaisse d'une app à l'autre.
    public static let exposureIcon = "sun.max"

    /// L'interrupteur « Exposition auto » est utilisable : ptzd tient l'ordre (SDK là, utilitaire à jour) et l'app a le
    /// SDK. Un ptzd d'avant l'exposition automatique ne publie rien (`nil`) : l'interrupteur reste grisé.
    public static func exposureEnabled(_ exposure: AutoExposure?, needsSDK: Bool) -> Bool {
        guard let exposure else { return false }
        return exposure != .unavailable && !needsSDK
    }

    /// La petite ligne sous « Exposition auto » : le SDK manque (« SDK OBSBOT requis »), ou ptzd dit l'exposition
    /// indisponible alors que le SDK est là (obsbot-ai en cours de mise à jour). Rien d'un ptzd ancien.
    public static func exposureNote(_ exposure: AutoExposure?, needsSDK: Bool) -> String? {
        if needsSDK {
            return sdkRequired
        }
        return exposure == .unavailable ? Localization.text("Indisponible : obsbot-ai est en cours de mise à jour.") : nil
    }

    /// La petite ligne sous « Vie privée » (spec § 6.5 bis). En vie privée, ce qui tient vraiment : « Image et micro
    /// coupés » seulement quand ptzd a constaté le mode natif, « Protection en cours » tant que l'objectif n'a pas été vu
    /// à −70° (rebranchement, démarrage, réveil de la caméra), « Objectif détourné » sinon (mode natif en cours ou
    /// impossible, ptzd ancien). Hors vie privée, ce qu'elle fera : couper l'image et le micro seulement si le SDK est prêt.
    public static func privacySubtitle(active: Bool, mode: PrivacyMode?, reason: PrivacyReason? = nil, sdkReady: Bool) -> String {
        if active {
            if mode == .native {
                return Localization.text("Image et micro coupés")
            }
            return reason == .pending ? Localization.text("Protection en cours") : Localization.text("Objectif détourné")
        }
        return sdkReady
            ? Localization.text("Coupe l'image et le micro de la caméra")
            : Localization.text("Détourne l'objectif de la caméra")
    }

    /// Le repli de ptzd : le SDK est là, mais le mode natif de la caméra a échoué (le message qui accompagne le repli).
    public static var privacyFallbackNote: String {
        Localization.text("La vie privée n'a pas pu couper l'image ni le micro de la caméra : l'objectif est seulement détourné.")
    }

    /// La note sous « Vie privée » quand elle ne tient que par l'inclinaison de l'objectif (mode `tilt`), selon la raison
    /// donnée par ptzd. Pour un obsbot-ai à recompiler, l'état du SDK dit ce qui bloque et quoi faire. Nil en mode natif,
    /// pendant que le mode natif est en cours (pas de raison), pendant la protection en cours (le sous-titre le dit), et
    /// chez un ptzd ancien.
    public static func privacyNote(mode: PrivacyMode?, reason: PrivacyReason?, sdk: SDKStatus?) -> String? {
        guard mode == .tilt, let reason else { return nil }
        switch reason {
        case .pending:
            return nil
        case .noSDK:
            return Localization.text("Sans le SDK OBSBOT, la vie privée détourne seulement l'objectif : l'image et le micro ne sont pas coupés.")
        case .failed:
            return privacyFallbackNote
        case .updating:
            switch sdk {
            case .toolsRequired:
                return Localization.text("obsbot-ai doit être recompilé : installez les outils de développement d'Apple pour que la vie privée coupe l'image et le micro. En attendant, elle détourne seulement l'objectif.")
            case .compileFailed:
                return Localization.text("La recompilation d'obsbot-ai a échoué : la vie privée détourne seulement l'objectif. Le détail est dans le journal obsbot-ai-compilation.log.")
            default:
                return Localization.text("Mise à jour du SDK OBSBOT en cours : la vie privée détourne seulement l'objectif pour l'instant.")
            }
        }
    }

    /// Le lien « Installer les outils de développement… » sous la note : obsbot-ai attend sa recompilation et les outils
    /// manquent.
    public static func privacyNeedsTools(mode: PrivacyMode?, reason: PrivacyReason?, sdk: SDKStatus?) -> Bool {
        guard mode == .tilt, reason == .updating, case .toolsRequired = sdk else { return false }
        return true
    }

    /// Le suivi IA a besoin du SDK de l'app et d'un obsbot-ai qui le charge ; l'ancienne installation a le sien
    /// dans `lib/`.
    public static func aiNeedsSDK(_ status: SDKStatus?, legacy: Bool) -> Bool {
        !legacy && status?.aiUsable != true
    }

    /// Le lien « Installer le SDK… » sous « Suivi IA » : le suivi attend le SDK et l'onglet « SDK OBSBOT » a quelque
    /// chose à proposer. Pas avant la lecture de l'état (nil) ni pendant la recompilation, où le SDK est déjà là, ni
    /// quand la source d'obsbot-ai manque (rien à installer : c'est PTZBot qu'il faut réinstaller) : `sdkAction` y est nil.
    public static func aiSDKLink(_ status: SDKStatus?, toolsAvailable: Bool = true, legacy: Bool) -> Bool {
        aiNeedsSDK(status, legacy: legacy) && sdkAction(status, toolsAvailable: toolsAvailable) != nil
    }

    public static var sdkRequired: String { Localization.text("SDK OBSBOT requis") }
    public static var tailscaleMissing: String { Localization.text("Tailscale introuvable : accès depuis l'extérieur indisponible") }
    public static var localNetworkDenied: String { Localization.text("PTZBot n'a pas accès au réseau local : les iPhone ne le trouveront qu'avec Tailscale") }

    public static var migrationMessage: String { Localization.text("Une ancienne installation de ptzd tourne en arrière-plan. PTZBot va la remplacer : le service sera désormais actif seulement quand PTZBot est ouvert. Vos iPhone appairés sont conservés.") }
    public static var migrationReplace: String { Localization.text("Remplacer") }
    public static var migrationLater: String { Localization.text("Plus tard") }

    public static var sdkExplanation: String { Localization.text("Le SDK OBSBOT est propriétaire : il ne peut pas être fourni avec PTZBot. Téléchargez-le sur obsbot.com, puis choisissez l'archive reçue (.zip) ou son dossier décompressé.") }
    public static var sdkConfirmation: String { Localization.text("PTZBot va copier ce fichier dans sa bibliothèque et retirer la quarantaine de cette copie. Ne le faites que si vous l'avez téléchargé depuis obsbot.com.") }

    /// Une ligne des vérifications de la fenêtre « SDK OBSBOT ».
    public struct SDKCheck: Equatable, Sendable {
        public var title: String
        public var value: String
    }

    /// La ligne « Signature » : le signataire (et l'équipe) seulement si la signature est intacte et d'un
    /// certificat reconnu par Apple. Ces contrôles ne remplacent pas Gatekeeper.
    static func signatureText(_ candidate: SDKCandidate) -> String {
        switch candidate.signatureValid {
        case false:
            return Localization.text("Signature invalide")
        case true:
            guard candidate.appleAnchored == true else { return Localization.text("Signé, certificat non reconnu par Apple") }
            guard let signer = candidate.signer else { return Localization.text("Signé") }
            return candidate.team.map { Localization.text("\(signer) (équipe \($0))") } ?? signer
        case nil:
            return Localization.text("non signé")
        }
    }

    /// Architecture, signature, provenance et quarantaine (§ 6.2).
    public static func sdkChecks(_ candidate: SDKCandidate) -> [SDKCheck] {
        let architecture = candidate.isArm64
            ? Localization.text("Apple Silicon : ✓")
            : Localization.text("Apple Silicon : ✗ (\(candidate.architectures.joined(separator: ", ")))")
        var origin = [String]()
        if let url = candidate.origin?.url {
            origin.append(url)
        }
        if let date = candidate.origin?.date {
            let formatted = date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(Localization.locale))
            origin.append(Localization.text("le \(formatted)"))
        }
        var provenance = origin.isEmpty ? Localization.text("inconnue") : origin.joined(separator: " · ")
        if !origin.isEmpty, candidate.origin?.fromInsideArchive == true {
            provenance = Localization.text("\(provenance) (indiquée dans l'archive)")
        }
        let signature = signatureText(candidate)
        var checks = [
            SDKCheck(title: Localization.text("Architecture"), value: architecture),
            SDKCheck(title: Localization.text("Signature"), value: signature),
            SDKCheck(title: Localization.text("Provenance"), value: provenance),
            SDKCheck(title: Localization.text("Quarantaine"), value: candidate.quarantined ? Localization.text("oui") : Localization.text("non")),
        ]
        if !candidate.otherCopies.isEmpty {
            checks.append(SDKCheck(title: Localization.text("Autres copies ignorées"), value: candidate.otherCopies.joined(separator: ", ")))
        }
        return checks
    }
}

/// Le pied du panneau et la fenêtre « Réglages » (spec distribution § 8).
extension Labels {
    public static var checkForUpdates: String { Localization.text("Rechercher les mises à jour…") }
    public static var settings: String { Localization.text("Réglages…") }
    public static var quit: String { Localization.text("Quitter") }
    public static var automaticallyChecks: String { Localization.text("Rechercher automatiquement") }
    public static var automaticallyInstalls: String { Localization.text("Installer automatiquement") }
    public static var openAtLogin: String { Localization.text("Ouvrir à la connexion") }
    public static var loginApproval: String { Localization.text("Autorisez PTZBot dans Réglages › Général › Ouverture") }
    public static var languageTitle: String { Localization.text("Langue") }
    public static var languageUpdateNote: String { Localization.text("Les fenêtres de mise à jour suivront au prochain lancement.") }

    /// Un choix de la langue : « Automatique (langue du système) », traduit ; « Français » et « English » toujours
    /// dans leur propre langue.
    public static func languageChoice(_ language: AppLanguage) -> String {
        switch language {
        case .automatic: Localization.text("Automatique (langue du système)")
        case .french: "Français"
        case .english: "English"
        }
    }

    public static var updatesDisabled: String { Localization.text("Mises à jour désactivées dans une compilation de travail.") }

    /// « PTZBot 1.0.0 (412) » : la version et le numéro de compilation, tels qu'ils sont dans l'app.
    public static func version(short: String?, build: String?) -> String {
        switch (short, build) {
        case let (short?, build?): "PTZBot \(short) (\(build))"
        case let (short?, nil): "PTZBot \(short)"
        default: "PTZBot"
        }
    }
}
