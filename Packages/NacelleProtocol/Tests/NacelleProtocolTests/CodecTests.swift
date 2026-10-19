import Foundation
import Testing
@testable import NacelleProtocol

@Suite("Messages de l'app vers ptzd")
struct ClientMessageTests {
    @Test("Aller-retour de chaque message", arguments: [
        ClientMessage.takeControl,
        .move(pan: 0.5, tilt: -0.25),
        .zoom(value: 33),
        .privacy(on: true),
        .privacy(on: false),
        .pair(pairingID: "1a2b3c4d", publicKey: Data([4, 1, 2, 3]), name: "iPhone", proof: Data(repeating: 5, count: 32)),
        .openPairing,
        .auth(deviceID: "00112233445566778899aabbccddeeff", signature: Data([48, 69, 2, 1])),
        .webrtcOffer(id: 3, sdp: "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n"),
        .aiTracking(on: true),
        .aiTracking(on: false),
        .adminWatch,
        .revoke(deviceID: "00112233445566778899aabbccddeeff"),
        .kick(deviceID: "00112233445566778899aabbccddeeff"),
        .unblock(deviceID: "00112233445566778899aabbccddeeff"),
        .closePairing,
        .forgetMe,
    ])
    func roundTrip(_ message: ClientMessage) throws {
        let text = try NacelleCodec.encode(message)
        #expect(try NacelleCodec.decodeClient(text) == message)
    }

    @Test("pair : identifiant, clé publique et preuve en base64")
    func pairFormat() throws {
        let text = try NacelleCodec.encode(ClientMessage.pair(pairingID: "1a2b3c4d", publicKey: Data([1, 2, 3]), name: "iPhone", proof: Data([9])))
        #expect(text == #"{"name":"iPhone","pairingID":"1a2b3c4d","proof":"CQ==","publicKey":"AQID","type":"pair"}"#)
    }

    @Test("Administration : kick porte l'identifiant, adminWatch et closePairing leur seul type")
    func adminFormat() throws {
        #expect(try NacelleCodec.encode(ClientMessage.kick(deviceID: "1a2b")) == #"{"deviceID":"1a2b","type":"kick"}"#)
        #expect(try NacelleCodec.encode(ClientMessage.adminWatch) == #"{"type":"adminWatch"}"#)
        #expect(try NacelleCodec.encode(ClientMessage.closePairing) == #"{"type":"closePairing"}"#)
        #expect(try NacelleCodec.encode(ClientMessage.aiTracking(on: true)) == #"{"on":true,"type":"aiTracking"}"#)
    }

    @Test("forgetMe s'écrit avec son seul type")
    func forgetMeFormat() throws {
        #expect(try NacelleCodec.encode(ClientMessage.forgetMe) == #"{"type":"forgetMe"}"#)
        #expect(try NacelleCodec.decodeClient(#"{"type":"forgetMe"}"#) == .forgetMe)
    }

    @Test("takeControl s'écrit avec son seul type")
    func takeControlFormat() throws {
        #expect(try NacelleCodec.encode(ClientMessage.takeControl) == #"{"type":"takeControl"}"#)
    }

    @Test("move est borné à -1…1")
    func moveIsClamped() throws {
        let message = try NacelleCodec.decodeClient(#"{"type":"move","pan":3,"tilt":-7}"#)
        #expect(message == .move(pan: 1, tilt: -1))
    }

    @Test("zoom est borné à 0…100")
    func zoomIsClamped() throws {
        #expect(try NacelleCodec.decodeClient(#"{"type":"zoom","value":250}"#) == .zoom(value: 100))
        #expect(try NacelleCodec.decodeClient(#"{"type":"zoom","value":-5}"#) == .zoom(value: 0))
    }

    @Test("Un type inconnu est rejeté")
    func unknownTypeIsRejected() {
        #expect(throws: NacelleProtocolError.unknownType("dance")) {
            try NacelleCodec.decodeClient(#"{"type":"dance"}"#)
        }
    }

    @Test("Un message mal formé est rejeté")
    func malformedIsRejected() {
        #expect(throws: (any Error).self) { try NacelleCodec.decodeClient("pas du json") }
        #expect(throws: (any Error).self) { try NacelleCodec.decodeClient(#"{"type":"move","pan":0.5}"#) }
        #expect(throws: (any Error).self) { try NacelleCodec.decodeClient(#"{"type":"zoom","value":"fort"}"#) }
    }
}

@Suite("Messages de ptzd vers l'app")
struct ServerMessageTests {
    static let known = StateSnapshot(
        camera: .connected, control: .ready, privacy: false,
        pan: 2, tilt: -1, zoom: 33, moving: true
    )
    static let unknown = StateSnapshot(
        camera: .absent, control: .idle, privacy: true,
        pan: nil, tilt: nil, zoom: nil, moving: false
    )
    static let tracking = StateSnapshot(
        camera: .connected, control: .ready, privacy: false,
        pan: 0, tilt: 0, zoom: 0, moving: false, aiTracking: .on
    )
    static let admin = AdminState(
        devices: [
            AdminDevice(deviceID: "00112233445566778899aabbccddeeff", name: "iPhone", pairedAt: Date(timeIntervalSince1970: 1_791_300_000), blockedUntil: nil),
            AdminDevice(deviceID: "ffeeddccbbaa99887766554433221100", name: "iPad", pairedAt: Date(timeIntervalSince1970: 1_791_200_000), blockedUntil: Date(timeIntervalSince1970: 1_791_301_600)),
        ],
        clients: [
            AdminClient(id: 76, deviceID: "00112233445566778899aabbccddeeff", name: "iPhone", route: .localNetwork, address: "192.0.2.89", since: Date(timeIntervalSince1970: 1_791_301_000)),
            AdminClient(id: 2, deviceID: nil, name: nil, route: .mac, address: "127.0.0.1", since: Date(timeIntervalSince1970: 1_791_300_500)),
        ],
        pairing: AdminPairing(pairingID: "1a2b3c4d", expiresAt: Date(timeIntervalSince1970: 1_791_301_300))
    )

    @Test("Aller-retour de chaque message", arguments: [
        ServerMessage.state(known),
        .state(unknown),
        .error(code: .privacyActive, message: "Vie privée active : mouvement refusé."),
        .error(code: .unpaired, message: "Appareil inconnu."),
        .error(code: .notLocal, message: "Réseau local seulement."),
        .pairingOpened(PairingInvitation(
            pairingID: "1a2b3c4d", secret: Data(repeating: 1, count: 32),
            expiresAt: Date(timeIntervalSince1970: 1_791_300_000), hosts: ["192.0.2.30", "192.0.2.43"], port: 1985
        )),
        .challenge(nonce: Data(repeating: 7, count: 32)),
        .authenticated,
        .paired(deviceID: "00112233445566778899aabbccddeeff", lanKey: Data(repeating: 9, count: 32)),
        .webrtcAnswer(id: 3, sdp: "v=0\r\n"),
        .webrtcError(id: 3, message: "go2rtc ne répond pas."),
        .state(tracking),
        .state(StateSnapshot(camera: .connected, control: .ready, privacy: true, pan: 0, tilt: 0, zoom: 0, moving: false, talkback: .ready)),
        .error(code: .blocked, message: "Expulsé par le Mac jusqu'à 20:14."),
        .adminState(admin),
        .adminState(AdminState(devices: [], clients: [], pairing: nil)),
    ])
    func roundTrip(_ message: ServerMessage) throws {
        let text = try NacelleCodec.encode(message)
        #expect(try NacelleCodec.decodeServer(text) == message)
    }

    @Test("Les valeurs inconnues sont écrites null")
    func unknownValuesAreNull() throws {
        let text = try NacelleCodec.encode(ServerMessage.state(Self.unknown))
        #expect(text == #"{"aiTracking":"unknown","camera":"absent","control":"idle","moving":false,"pan":null,"privacy":true,"talkback":"unavailable","tilt":null,"type":"state","zoom":null}"#)
    }

    @Test("Un état sans aiTracking (ptzd d'avant le suivi IA) se lit « inconnu »")
    func legacyStateWithoutAITracking() throws {
        let text = #"{"camera":"connected","control":"ready","moving":false,"pan":0,"privacy":false,"tilt":0,"type":"state","zoom":0}"#
        guard case let .state(snapshot) = try NacelleCodec.decodeServer(text) else {
            Issue.record("state attendu")
            return
        }
        #expect(snapshot.aiTracking == .unknown)
    }

    @Test("Un état sans talkback (ptzd d'avant la parole) se lit « indisponible »")
    func legacyStateWithoutTalkback() throws {
        let text = #"{"aiTracking":"off","camera":"connected","control":"ready","moving":false,"pan":0,"privacy":false,"tilt":0,"type":"state","zoom":0}"#
        guard case let .state(snapshot) = try NacelleCodec.decodeServer(text) else {
            Issue.record("state attendu")
            return
        }
        #expect(snapshot.talkback == .unavailable)
    }

    @Test("Talkback prêt : écrit et relu")
    func talkbackReady() throws {
        var snapshot = Self.known
        snapshot.talkback = .ready
        let text = try NacelleCodec.encode(ServerMessage.state(snapshot))
        #expect(text.contains(#""talkback":"ready""#))
        #expect(try NacelleCodec.decodeServer(text) == .state(snapshot))
    }

    @Test("Une valeur de talkback inconnue (un futur ptzd) se lit « indisponible » : l'état reste lisible")
    func unknownTalkbackValue() throws {
        var snapshot = Self.known
        snapshot.talkback = .ready
        let text = try NacelleCodec.encode(ServerMessage.state(snapshot))
        let future = text.replacingOccurrences(of: #""talkback":"ready""#, with: #""talkback":"bientot""#)
        guard case let .state(decoded) = try NacelleCodec.decodeServer(future) else {
            Issue.record("state attendu")
            return
        }
        #expect(decoded.talkback == .unavailable)
        var expected = snapshot
        expected.talkback = .unavailable
        #expect(decoded == expected)
    }

    @Test("privacyMode : présent, écrit et relu (spec § 6.5 bis)", arguments: [PrivacyMode.native, PrivacyMode.tilt])
    func privacyModePresent(mode: PrivacyMode) throws {
        var snapshot = Self.known
        snapshot.privacy = true
        snapshot.privacyMode = mode
        let text = try NacelleCodec.encode(ServerMessage.state(snapshot))
        #expect(text.contains(#""privacyMode":"\#(mode.rawValue)""#))
        #expect(try NacelleCodec.decodeServer(text) == .state(snapshot))
    }

    @Test("privacyMode : absent (ptzd d'avant la vie privée V2), il n'est pas écrit et se lit nil")
    func privacyModeAbsent() throws {
        let text = #"{"aiTracking":"off","camera":"connected","control":"ready","moving":false,"pan":0,"privacy":true,"tilt":0,"type":"state","zoom":0}"#
        guard case let .state(snapshot) = try NacelleCodec.decodeServer(text) else {
            Issue.record("state attendu")
            return
        }
        #expect(snapshot.privacyMode == nil)
        // Sans mode, rien n'est écrit : un ancien client n'a pas à l'ignorer.
        #expect(try !NacelleCodec.encode(ServerMessage.state(snapshot)).contains("privacyMode"))
    }

    @Test("Une valeur de privacyMode inconnue (un futur ptzd) se lit nil : l'état reste lisible")
    func privacyModeUnknownValue() throws {
        var snapshot = Self.known
        snapshot.privacy = true
        snapshot.privacyMode = .native
        let text = try NacelleCodec.encode(ServerMessage.state(snapshot))
        let future = text.replacingOccurrences(of: #""privacyMode":"native""#, with: #""privacyMode":"flou""#)
        guard case let .state(decoded) = try NacelleCodec.decodeServer(future) else {
            Issue.record("state attendu")
            return
        }
        #expect(decoded.privacyMode == nil)
        var expected = snapshot
        expected.privacyMode = nil
        #expect(decoded == expected)
    }

    @Test("adminState : dates en secondes depuis 1970, absences écrites null, jamais de secret")
    func adminStateFormat() throws {
        let text = try NacelleCodec.encode(ServerMessage.adminState(AdminState(
            devices: [AdminDevice(deviceID: "1a2b", name: "iPhone", pairedAt: Date(timeIntervalSince1970: 1_791_300_000), blockedUntil: nil)],
            clients: [AdminClient(id: 2, deviceID: nil, name: nil, route: .mac, address: "127.0.0.1", since: Date(timeIntervalSince1970: 1_791_300_500))],
            pairing: nil
        )))
        #expect(text == #"{"state":{"clients":[{"address":"127.0.0.1","deviceID":null,"id":2,"name":null,"route":"mac","since":1791300500}],"devices":[{"blockedUntil":null,"deviceID":"1a2b","name":"iPhone","pairedAt":1791300000}],"pairing":null},"type":"adminState"}"#)
    }

    @Test("pairingOpened : échéance en secondes depuis 1970")
    func pairingOpenedFormat() throws {
        let invitation = PairingInvitation(pairingID: "1a2b3c4d", secret: Data([1]), expiresAt: Date(timeIntervalSince1970: 1_791_300_000), hosts: ["192.0.2.30"], port: 1985)
        let text = try NacelleCodec.encode(ServerMessage.pairingOpened(invitation))
        #expect(text.contains(#""expiresAt":1791300000"#))
    }

    @Test("authenticated s'écrit avec son seul type")
    func authenticatedFormat() throws {
        #expect(try NacelleCodec.encode(ServerMessage.authenticated) == #"{"type":"authenticated"}"#)
    }

    @Test("Un type inconnu est rejeté")
    func unknownTypeIsRejected() {
        #expect(throws: NacelleProtocolError.unknownType("hello")) {
            try NacelleCodec.decodeServer(#"{"type":"hello"}"#)
        }
    }
}

@Suite("Message d'échec du suivi IA")
struct AIFailureTextTests {
    @Test("Composé par ptzd, relu par l'app : le motif revient tel quel ; un autre message n'en a pas")
    func roundTrip() {
        for motive in [AIFailureText.cameraNotFound, AIFailureText.sdkError, AIFailureText.timeout,
                       AIFailureText.launchFailed, AIFailureText.unexpectedExitPrefix + "134", "motif nouveau"] {
            #expect(AIFailureText.motive(in: AIFailureText.message(motive: motive)) == motive)
        }
        #expect(AIFailureText.message(motive: "délai dépassé") == "Suivi IA non modifié (délai dépassé).")
        #expect(AIFailureText.motive(in: "La caméra a refusé la commande (x).") == nil)
        #expect(AIFailureText.motive(in: "Suivi IA non modifié (") == nil)
    }
}

@Suite("Trame voix")
struct VoiceFrameTests {
    @Test("Constantes : 640 octets = 320 échantillons de 16 bits = 20 ms à 16 kHz")
    func constants() {
        #expect(VoiceFrame.sampleRate == 16_000)
        #expect(VoiceFrame.bytesPerSample == 2)
        #expect(VoiceFrame.samplesPerFrame == 320)
        #expect(VoiceFrame.byteCount == 640)
        #expect(VoiceFrame.durationMilliseconds == 20)
        #expect(VoiceFrame.maxFramesPerSecond == 50)
        // Cohérence : durée × fréquence = échantillons ; échantillons × 2 = octets.
        #expect(VoiceFrame.sampleRate * VoiceFrame.durationMilliseconds / 1000 == VoiceFrame.samplesPerFrame)
        #expect(VoiceFrame.samplesPerFrame * VoiceFrame.bytesPerSample == VoiceFrame.byteCount)
    }

    @Test("Seule la taille exacte est valide")
    func validity() {
        #expect(VoiceFrame.isValid(Data(count: 640)))
        #expect(!VoiceFrame.isValid(Data(count: 639)))
        #expect(!VoiceFrame.isValid(Data(count: 641)))
        #expect(!VoiceFrame.isValid(Data()))
    }
}
