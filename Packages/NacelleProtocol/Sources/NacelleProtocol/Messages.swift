import Foundation

/// Message de l'app vers ptzd (spec § 5).
public enum ClientMessage: Equatable, Sendable {
    /// Prise en main ; ne coupe plus le suivi IA, gardé pour la compatibilité (spec app Mac § 7.5).
    case takeControl
    /// Consigne de vitesse, de -1 à 1 sur chaque axe. 0,0 arrête le mouvement.
    case move(pan: Double, tilt: Double)
    /// Zoom absolu, de 0 à 100.
    case zoom(value: Int)
    /// Entre en vie privée (true) ou en sort (false).
    case privacy(on: Bool)
    /// Enregistre la clé de l'appareil pour l'appairage `pairingID` du QR code ; `proof` prouve que
    /// l'app connaît le secret du QR (spec découverte et QR § 6).
    case pair(pairingID: String, publicKey: Data, name: String, proof: Data)
    /// Ouvre un appairage ; accepté seulement depuis 127.0.0.1 (`ptzd pair`).
    case openPairing
    /// Répond au défi : signature DER de `NacelleAuth.signedPayload` (spec accès local § 6.3).
    case auth(deviceID: String, signature: Data)
    /// Offre WebRTC à relayer à go2rtc ; `id` croît à chaque offre (spec accès local § 6.5).
    case webrtcOffer(id: Int, sdp: String)
    /// Allume (true) ou coupe (false) le suivi IA de la caméra (spec app Mac § 7.5).
    case aiTracking(on: Bool)
    /// Demande l'état d'administration, puis ses changements ; 127.0.0.1 seulement (spec app Mac § 6).
    case adminWatch
    /// Retire l'appareil et coupe ses connexions ; 127.0.0.1 seulement.
    case revoke(deviceID: String)
    /// Coupe les connexions de l'appareil et le bloque 10 min ; 127.0.0.1 seulement.
    case kick(deviceID: String)
    /// Lève le blocage de l'appareil ; 127.0.0.1 seulement.
    case unblock(deviceID: String)
    /// Annule l'appairage en cours ; 127.0.0.1 seulement.
    case closePairing
    /// L'iPhone oublie son appairage : ptzd retire cet appareil de sa liste et coupe ses connexions.
    /// Accepté d'un iPhone authentifié seulement.
    case forgetMe
    /// PTZBot a recompilé ou réinstallé obsbot-ai : ptzd redémarre son utilitaire et réconcilie la vie privée
    /// (spec § 6.5 bis). 127.0.0.1 seulement.
    case aiUpdated
    /// Active (true) ou désactive (false) l'exposition automatique de la caméra ; désactivée, la caméra revient au réglage
    /// d'avant l'activation (spec § 6.11).
    case autoExposure(on: Bool)
}

/// Présence de la caméra côté Mac.
public enum CameraPresence: String, Codable, Sendable {
    case connected
    case absent
}

/// Dernier ordre de suivi IA envoyé par ptzd : l'état réel ne se lit pas (spec app Mac § 7.5).
public enum AITracking: String, Codable, Sendable {
    case on
    case off
    /// Au démarrage de ptzd et après un rebranchement de la caméra hors vie privée.
    case unknown
}

/// Disponibilité du retour audio (talkd) côté Mac, lue par ptzd dans l'état de talkd (spec parler § 5).
public enum TalkbackAvailability: String, Codable, Sendable {
    case ready
    case unavailable
}

/// Exposition automatique de la caméra, telle que ptzd la publie (spec § 6.11).
public enum AutoExposure: String, Codable, Sendable {
    /// Voulue : la caméra est (ou va être) en exposition automatique continue.
    case on
    /// Non voulue : la caméra garde son réglage manuel.
    case off
    /// ptzd ne peut pas la tenir : pas d'`obsbot-ai` (SDK absent), ou `obsbot-ai` d'avant l'exposition automatique.
    case unavailable
}

/// La trame « voix » : seul message binaire du protocole, de l'app vers ptzd (spec parler § 4).
/// 320 échantillons PCM 16 bits little-endian, 16 kHz, mono, sans en-tête ; la fin d'une prise de parole
/// est détectée par talkd.
public enum VoiceFrame {
    public static let sampleRate = 16_000
    public static let bytesPerSample = 2
    public static let durationMilliseconds = 20
    public static let samplesPerFrame = sampleRate * durationMilliseconds / 1000
    public static let byteCount = samplesPerFrame * bytesPerSample
    /// Au-delà, ptzd ignore l'excédent (fenêtre glissante d'une seconde, par client).
    public static let maxFramesPerSecond = 1000 / durationMilliseconds

    /// Une trame n'est valide qu'à la taille exacte.
    public static func isValid(_ data: Data) -> Bool {
        data.count == byteCount
    }
}

/// Façon dont la vie privée est tenue (spec § 6.5 bis).
public enum PrivacyMode: String, Codable, Sendable {
    /// Mode vie privée de l'OBSBOT, constaté par une lecture de l'état réel de la caméra : image noire et micro coupé.
    case native
    /// Protection à −70° seule : objectif incliné vers le bas, sans coupure de l'image ni du micro. Aussi pendant que le
    /// mode natif est en cours, tant qu'il n'est pas confirmé.
    case tilt
}

/// Pourquoi la vie privée ne tient que par l'inclinaison (`privacyMode` `tilt`, spec § 6.5 bis). Absente pendant que le
/// mode natif est en cours, l'objectif déjà vu à −70°.
public enum PrivacyReason: String, Codable, Sendable {
    /// Protection en cours : l'objectif n'a pas encore été vu à −70°, et le mode natif n'est pas lu (rebranchement,
    /// démarrage, réveil de la caméra par un autre moyen). Un client d'avant cette raison la lit nil.
    case pending
    /// Pas d'obsbot-ai (SDK absent) : la vie privée n'a que l'inclinaison.
    case noSDK
    /// obsbot-ai est d'avant la vie privée V2 (« ordre inconnu ») : PTZBot doit le recompiler.
    case updating
    /// Le mode natif a échoué deux fois, ou l'état réel de la caméra ne se lit pas.
    case failed
}

/// Avancement de la coupure du suivi IA (prise en main).
public enum ControlState: String, Codable, Sendable {
    case idle
    case taking
    case ready
    case failed
}

/// Codes d'erreur renvoyés à l'app.
public enum ErrorCode: String, Codable, Sendable, CaseIterable {
    case privacyActive
    case cameraAbsent
    case uvcFailed
    case badMessage
    /// Appareil inconnu de ptzd.
    case unpaired
    /// Signature fausse.
    case authFailed
    /// Preuve d'appairage fausse.
    case badCode
    /// Aucun appairage en cours, expiré, déjà utilisé, ou autre identifiant.
    case pairingClosed
    /// Message refusé avant l'authentification.
    case notAuthenticated
    /// Message d'administration ou `openPairing` hors de 127.0.0.1, ou `pair` hors de l'écoute du réseau local.
    case notLocal
    /// Appareil expulsé par le Mac, pour quelques minutes (spec app Mac § 7.3).
    case blocked
}

/// Le message `uvcFailed` de ptzd quand obsbot-ai n'a pas pu changer le suivi IA : « Suivi IA non modifié (<motif>). ».
/// ptzd le compose, l'app Mac en lit le motif pour afficher son propre texte traduit (spec distribution § 7.2) :
/// les deux côtés partagent ces textes, en français comme le journal de ptzd.
public enum AIFailureText {
    public static let prefix = "Suivi IA non modifié ("
    public static let suffix = ")."
    public static let cameraNotFound = "caméra introuvable"
    public static let sdkError = "erreur du SDK OBSBOT"
    public static let timeout = "délai dépassé"
    public static let launchFailed = "l'utilitaire n'a pas pu être lancé"
    /// obsbot-ai d'avant cet ordre (réponse « ordre inconnu », code 3) : il attend sa recompilation.
    public static let unknownOrder = "l'utilitaire n'est pas à jour"
    /// Suivi du code de sortie.
    public static let unexpectedExitPrefix = "l'utilitaire s'est arrêté avec le code "

    public static func message(motive: String) -> String {
        prefix + motive + suffix
    }

    /// Le motif d'un message de ce format, nil sinon.
    public static func motive(in message: String) -> String? {
        guard message.hasPrefix(prefix), message.hasSuffix(suffix),
              message.count >= prefix.count + suffix.count else { return nil }
        return String(message.dropFirst(prefix.count).dropLast(suffix.count))
    }
}

/// Les messages `uvcFailed` de la vie privée native (spec § 6.5 bis). ptzd les envoie tels quels ; les apps les
/// reconnaissent par ces textes partagés pour montrer leur propre traduction (comme `AIFailureText`).
public enum PrivacyFailureText {
    /// Repli sur l'inclinaison : l'image et le micro ne sont pas coupés.
    public static let fallbackToTilt = "La vie privée n'a pas pu couper l'image ni le micro de la caméra : l'objectif est seulement détourné."
    /// Sortie : la caméra est restée en vie privée après deux essais. La vie privée reste active.
    public static let exitFailed = "La vie privée n'a pas pu être levée : la caméra est restée en mode vie privée."
    /// Sortie : ni l'état de la caméra ni l'inclinaison de sa nacelle ne se lisent, le réveil n'est pas confirmé. La vie
    /// privée reste active.
    public static let exitUnreadable = "La vie privée n'a pas pu être levée : l'état de la caméra ne se lit pas."
    /// Sortie : obsbot-ai est d'avant la vie privée V2 et ne sait pas réveiller la caméra. La vie privée reste active.
    public static let exitNeedsUpdate = "La vie privée n'a pas pu être levée : obsbot-ai n'est pas à jour."
}

/// Les messages `uvcFailed` de l'exposition automatique (spec § 6.11). ptzd les envoie tels quels ; les apps les
/// reconnaissent par ces textes partagés pour montrer leur propre traduction (comme `AIFailureText`).
public enum ExposureFailureText {
    /// Pas d'`obsbot-ai` : sans le SDK, l'exposition ne se règle pas.
    public static let noSDK = "L'exposition automatique demande le SDK OBSBOT."
    /// `obsbot-ai` est d'avant l'exposition automatique et attend sa recompilation.
    public static let needsUpdate = "L'exposition automatique n'est pas disponible : obsbot-ai n'est pas à jour."
    /// Activation : le réglage actuel de la caméra n'a pas pu être lu, donc rien n'a été changé.
    public static let readFailed = "L'exposition automatique n'a pas été activée : le réglage de la caméra ne se lit pas."
    /// Activation : la caméra a refusé le passage en automatique.
    public static let activateFailed = "L'exposition automatique n'a pas pu être activée."
    /// Désactivation : la caméra est restée en exposition automatique.
    public static let deactivateFailed = "L'exposition automatique n'a pas pu être désactivée : la caméra est restée en automatique."
}

/// État complet publié par ptzd.
public struct StateSnapshot: Equatable, Sendable {
    public var camera: CameraPresence
    public var control: ControlState
    public var privacy: Bool
    /// Mode de la vie privée en cours ; nil hors vie privée, et chez un ptzd d'avant la vie privée V2 (spec § 6.5 bis).
    public var privacyMode: PrivacyMode?
    /// En mode `tilt`, pourquoi le mode natif ne tient pas ; nil pendant qu'il est en cours, et hors du mode `tilt`.
    public var privacyReason: PrivacyReason?
    /// Degrés, ou nil si inconnus.
    public var pan: Double?
    /// Degrés, ou nil si inconnus.
    public var tilt: Double?
    /// De 0 à 100, ou nil si inconnu.
    public var zoom: Int?
    public var moving: Bool
    public var aiTracking: AITracking
    /// Un ptzd d'avant la parole n'envoie pas ce champ : l'app le lit `unavailable`.
    public var talkback: TalkbackAvailability
    /// Exposition automatique voulue ; nil chez un ptzd d'avant ce champ (spec § 6.11).
    public var autoExposure: AutoExposure?

    public init(
        camera: CameraPresence,
        control: ControlState,
        privacy: Bool,
        pan: Double?,
        tilt: Double?,
        zoom: Int?,
        moving: Bool,
        aiTracking: AITracking = .unknown,
        talkback: TalkbackAvailability = .unavailable,
        privacyMode: PrivacyMode? = nil,
        privacyReason: PrivacyReason? = nil,
        autoExposure: AutoExposure? = nil
    ) {
        self.camera = camera
        self.control = control
        self.privacy = privacy
        self.pan = pan
        self.tilt = tilt
        self.zoom = zoom
        self.moving = moving
        self.aiTracking = aiTracking
        self.talkback = talkback
        self.privacyMode = privacyMode
        self.privacyReason = privacyReason
        self.autoExposure = autoExposure
    }
}

/// Message de ptzd vers l'app.
public enum ServerMessage: Equatable, Sendable {
    case state(StateSnapshot)
    case error(code: ErrorCode, message: String)
    /// Défi envoyé à l'ouverture d'une connexion qui doit s'authentifier.
    case challenge(nonce: Data)
    /// Connexion authentifiée ; l'état suit aussitôt.
    case authenticated
    /// Appairage ouvert : ce que `ptzd pair` met dans le QR code.
    case pairingOpened(PairingInvitation)
    /// L'appareil vient d'être enregistré ; `lanKey` est son secret du canal chiffré du réseau local
    /// (spec accès local § 14), remis sur le réseau local à la connexion qui a fourni la preuve.
    case paired(deviceID: String, lanKey: Data)
    /// Réponse de go2rtc à l'offre `id`.
    case webrtcAnswer(id: Int, sdp: String)
    /// go2rtc injoignable ou en erreur pour l'offre `id`.
    case webrtcError(id: Int, message: String)
    /// État d'administration, aux connexions qui l'ont demandé par `adminWatch`.
    case adminState(AdminState)
}

/// Un appairage ouvert par ptzd : identifiant, secret, échéance, et où joindre le Mac.
public struct PairingInvitation: Codable, Equatable, Sendable {
    public var pairingID: String
    /// 32 octets aléatoires ; clé TLS de l'appairage et clé de la preuve.
    public var secret: Data
    public var expiresAt: Date
    /// Adresses IPv4 du Mac sur le réseau local.
    public var hosts: [String]
    public var port: Int

    public init(pairingID: String, secret: Data, expiresAt: Date, hosts: [String], port: Int) {
        self.pairingID = pairingID
        self.secret = secret
        self.expiresAt = expiresAt
        self.hosts = hosts
        self.port = port
    }

    private enum CodingKeys: String, CodingKey {
        case pairingID, secret, expiresAt, hosts, port
    }

    /// `expiresAt` s'écrit en secondes depuis 1970 (spec découverte et QR § 6).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pairingID: try c.decode(String.self, forKey: .pairingID),
            secret: try c.decode(Data.self, forKey: .secret),
            expiresAt: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .expiresAt)),
            hosts: try c.decode([String].self, forKey: .hosts),
            port: try c.decode(Int.self, forKey: .port)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pairingID, forKey: .pairingID)
        try c.encode(secret, forKey: .secret)
        try c.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAt)
        try c.encode(hosts, forKey: .hosts)
        try c.encode(port, forKey: .port)
    }
}
