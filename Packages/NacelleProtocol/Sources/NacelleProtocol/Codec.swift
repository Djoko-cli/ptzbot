import Foundation

public enum NacelleProtocolError: Error, Equatable {
    case unknownType(String)
}

/// Encodage JSON des messages : un objet par trame WebSocket texte, avec un champ `type`.
public enum NacelleCodec {
    public static func encode(_ message: ClientMessage) throws -> String {
        try string(from: message)
    }

    public static func encode(_ message: ServerMessage) throws -> String {
        try string(from: message)
    }

    public static func decodeClient(_ text: String) throws -> ClientMessage {
        try JSONDecoder().decode(ClientMessage.self, from: Data(text.utf8))
    }

    public static func decodeServer(_ text: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8))
    }

    private static func string(from value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

extension ClientMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, pan, tilt, value, on, pairingID, publicKey, name, proof, deviceID, signature, id, sdp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "takeControl":
            self = .takeControl
        case "move":
            self = .move(
                pan: Self.unit(try container.decode(Double.self, forKey: .pan)),
                tilt: Self.unit(try container.decode(Double.self, forKey: .tilt))
            )
        case "zoom":
            self = .zoom(value: min(max(try container.decode(Int.self, forKey: .value), 0), 100))
        case "privacy":
            self = .privacy(on: try container.decode(Bool.self, forKey: .on))
        case "pair":
            self = .pair(
                pairingID: try container.decode(String.self, forKey: .pairingID),
                publicKey: try container.decode(Data.self, forKey: .publicKey),
                name: try container.decode(String.self, forKey: .name),
                proof: try container.decode(Data.self, forKey: .proof)
            )
        case "openPairing":
            self = .openPairing
        case "auth":
            self = .auth(
                deviceID: try container.decode(String.self, forKey: .deviceID),
                signature: try container.decode(Data.self, forKey: .signature)
            )
        case "webrtcOffer":
            self = .webrtcOffer(id: try container.decode(Int.self, forKey: .id), sdp: try container.decode(String.self, forKey: .sdp))
        case "aiTracking":
            self = .aiTracking(on: try container.decode(Bool.self, forKey: .on))
        case "adminWatch":
            self = .adminWatch
        case "revoke":
            self = .revoke(deviceID: try container.decode(String.self, forKey: .deviceID))
        case "kick":
            self = .kick(deviceID: try container.decode(String.self, forKey: .deviceID))
        case "unblock":
            self = .unblock(deviceID: try container.decode(String.self, forKey: .deviceID))
        case "closePairing":
            self = .closePairing
        case "forgetMe":
            self = .forgetMe
        case "aiUpdated":
            self = .aiUpdated
        case "autoExposure":
            self = .autoExposure(on: try container.decode(Bool.self, forKey: .on))
        default:
            throw NacelleProtocolError.unknownType(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .takeControl:
            try container.encode("takeControl", forKey: .type)
        case let .move(pan, tilt):
            try container.encode("move", forKey: .type)
            try container.encode(pan, forKey: .pan)
            try container.encode(tilt, forKey: .tilt)
        case let .zoom(value):
            try container.encode("zoom", forKey: .type)
            try container.encode(value, forKey: .value)
        case let .privacy(on):
            try container.encode("privacy", forKey: .type)
            try container.encode(on, forKey: .on)
        case let .pair(pairingID, publicKey, name, proof):
            try container.encode("pair", forKey: .type)
            try container.encode(pairingID, forKey: .pairingID)
            try container.encode(publicKey, forKey: .publicKey)
            try container.encode(name, forKey: .name)
            try container.encode(proof, forKey: .proof)
        case .openPairing:
            try container.encode("openPairing", forKey: .type)
        case let .auth(deviceID, signature):
            try container.encode("auth", forKey: .type)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(signature, forKey: .signature)
        case let .webrtcOffer(id, sdp):
            try container.encode("webrtcOffer", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(sdp, forKey: .sdp)
        case let .aiTracking(on):
            try container.encode("aiTracking", forKey: .type)
            try container.encode(on, forKey: .on)
        case .adminWatch:
            try container.encode("adminWatch", forKey: .type)
        case let .revoke(deviceID):
            try container.encode("revoke", forKey: .type)
            try container.encode(deviceID, forKey: .deviceID)
        case let .kick(deviceID):
            try container.encode("kick", forKey: .type)
            try container.encode(deviceID, forKey: .deviceID)
        case let .unblock(deviceID):
            try container.encode("unblock", forKey: .type)
            try container.encode(deviceID, forKey: .deviceID)
        case .closePairing:
            try container.encode("closePairing", forKey: .type)
        case .forgetMe:
            try container.encode("forgetMe", forKey: .type)
        case .aiUpdated:
            try container.encode("aiUpdated", forKey: .type)
        case let .autoExposure(on):
            try container.encode("autoExposure", forKey: .type)
            try container.encode(on, forKey: .on)
        }
    }

    private static func unit(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }
}

extension StateSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case camera, control, privacy, pan, tilt, zoom, moving, aiTracking, talkback, privacyMode, privacyReason, autoExposure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            camera: try container.decode(CameraPresence.self, forKey: .camera),
            control: try container.decode(ControlState.self, forKey: .control),
            privacy: try container.decode(Bool.self, forKey: .privacy),
            pan: try container.decodeIfPresent(Double.self, forKey: .pan),
            tilt: try container.decodeIfPresent(Double.self, forKey: .tilt),
            zoom: try container.decodeIfPresent(Int.self, forKey: .zoom),
            moving: try container.decode(Bool.self, forKey: .moving),
            // Un ptzd d'avant le suivi IA n'envoie pas ce champ.
            aiTracking: try container.decodeIfPresent(AITracking.self, forKey: .aiTracking) ?? .unknown,
            // Un ptzd d'avant la parole n'envoie pas ce champ, et un ptzd futur pourrait y ajouter une valeur : dans les
            // deux cas la parole est indisponible, et le reste de l'état reste lisible (iPhones déjà installés).
            talkback: (try? container.decodeIfPresent(TalkbackAvailability.self, forKey: .talkback)) ?? .unavailable,
            // Absent chez un ptzd d'avant la vie privée V2 ; une valeur inconnue (un futur ptzd) se lit aussi nil (spec § 6.5 bis).
            privacyMode: (try? container.decodeIfPresent(PrivacyMode.self, forKey: .privacyMode)),
            // De même pour la raison du mode `tilt` : absente ou inconnue, elle se lit nil.
            privacyReason: (try? container.decodeIfPresent(PrivacyReason.self, forKey: .privacyReason)),
            // Absent chez un ptzd d'avant l'exposition automatique, et nil aussi pour une valeur inconnue (spec § 6.11).
            autoExposure: (try? container.decodeIfPresent(AutoExposure.self, forKey: .autoExposure))
        )
    }

    /// Les valeurs inconnues sont écrites `null` (spec § 5), pas omises.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(camera, forKey: .camera)
        try container.encode(control, forKey: .control)
        try container.encode(privacy, forKey: .privacy)
        try container.encode(pan, forKey: .pan)
        try container.encode(tilt, forKey: .tilt)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(moving, forKey: .moving)
        try container.encode(aiTracking, forKey: .aiTracking)
        try container.encode(talkback, forKey: .talkback)
        // Omis (et non null) hors vie privée : un client ancien n'a rien de nouveau à ignorer.
        try container.encodeIfPresent(privacyMode, forKey: .privacyMode)
        try container.encodeIfPresent(privacyReason, forKey: .privacyReason)
        try container.encodeIfPresent(autoExposure, forKey: .autoExposure)
    }
}

extension ServerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, code, message, nonce, deviceID, id, sdp, lanKey, invitation, state
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "state":
            self = .state(try StateSnapshot(from: decoder))
        case "error":
            self = .error(
                code: try container.decode(ErrorCode.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        case "challenge":
            self = .challenge(nonce: try container.decode(Data.self, forKey: .nonce))
        case "authenticated":
            self = .authenticated
        case "pairingOpened":
            self = .pairingOpened(try container.decode(PairingInvitation.self, forKey: .invitation))
        case "paired":
            self = .paired(deviceID: try container.decode(String.self, forKey: .deviceID), lanKey: try container.decode(Data.self, forKey: .lanKey))
        case "webrtcAnswer":
            self = .webrtcAnswer(id: try container.decode(Int.self, forKey: .id), sdp: try container.decode(String.self, forKey: .sdp))
        case "webrtcError":
            self = .webrtcError(id: try container.decode(Int.self, forKey: .id), message: try container.decode(String.self, forKey: .message))
        case "adminState":
            self = .adminState(try container.decode(AdminState.self, forKey: .state))
        default:
            throw NacelleProtocolError.unknownType(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .state(snapshot):
            try container.encode("state", forKey: .type)
            try snapshot.encode(to: encoder)
        case let .error(code, message):
            try container.encode("error", forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        case let .challenge(nonce):
            try container.encode("challenge", forKey: .type)
            try container.encode(nonce, forKey: .nonce)
        case .authenticated:
            try container.encode("authenticated", forKey: .type)
        case let .pairingOpened(invitation):
            try container.encode("pairingOpened", forKey: .type)
            try container.encode(invitation, forKey: .invitation)
        case let .paired(deviceID, lanKey):
            try container.encode("paired", forKey: .type)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(lanKey, forKey: .lanKey)
        case let .webrtcAnswer(id, sdp):
            try container.encode("webrtcAnswer", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(sdp, forKey: .sdp)
        case let .webrtcError(id, message):
            try container.encode("webrtcError", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(message, forKey: .message)
        case let .adminState(state):
            try container.encode("adminState", forKey: .type)
            try container.encode(state, forKey: .state)
        }
    }
}
