import Foundation
import NacelleProtocol
import Testing
@testable import PTZBotKit

@MainActor
@Suite("Panneau", .french)
struct PanelModelTests {
    let transport = FakeAdminTransport()
    let scheduler = FakeScheduler()
    let model: PanelModel
    let device = AdminDevice(deviceID: "00112233445566778899aabbccddeeff", name: "iPhone", pairedAt: Date(timeIntervalSince1970: 1_791_300_000), blockedUntil: nil)

    init() {
        model = PanelModel(config: PTZDConfig(port: 1985, isFallback: false), transport: transport, scheduler: scheduler)
    }

    private func receive(_ message: ServerMessage) throws {
        transport.emit(.message(try NacelleCodec.encode(message)))
    }

    private var sent: [ClientMessage] {
        transport.sent.compactMap { try? NacelleCodec.decodeClient($0) }
    }

    /// Connexion de confiance établie, état et état d'administration reçus.
    private func connect(devices: [AdminDevice] = []) throws {
        model.start()
        transport.emit(.opened)
        try receive(.authenticated)
        try receive(.state(StateSnapshot(camera: .connected, control: .idle, privacy: false, pan: 0, tilt: 0, zoom: 0, moving: false, aiTracking: .unknown)))
        try receive(.adminState(AdminState(devices: devices, clients: [], pairing: nil)))
    }

    @Test("Connexion à 127.0.0.1 sur le port de config.json ; authentifiée : actif, état d'administration demandé")
    func connects() throws {
        #expect(model.service == .connecting)
        try connect(devices: [device])
        #expect(transport.opened == [URL(string: "ws://127.0.0.1:1985")!])
        #expect(model.service == .active)
        #expect(sent.first == .adminWatch)
        #expect(model.state?.camera == .connected)
        #expect(model.admin?.devices == [device])
    }

    @Test("iPhone connectés : la connexion de confiance du Mac n'est pas un client")
    func iPhoneClients() throws {
        try connect()
        #expect(model.iPhoneClients.isEmpty)
        let since = Date(timeIntervalSince1970: 1_791_301_000)
        let mac = AdminClient(id: 1, deviceID: nil, name: nil, route: .mac, address: "127.0.0.1", since: since)
        let phone = AdminClient(id: 2, deviceID: device.deviceID, name: "iPhone", route: .localNetwork, address: "192.0.2.89", since: since)
        let remote = AdminClient(id: 3, deviceID: device.deviceID, name: "iPhone", route: .tailscale, address: "100.64.0.1", since: since)
        try receive(.adminState(AdminState(devices: [device], clients: [mac, phone, remote], pairing: nil)))
        #expect(model.iPhoneClients.map(\.id) == [2, 3])
        #expect(Labels.iPhoneSection(count: model.iPhoneClients.count) == "iPhone connectés · 2")
        transport.emit(.closed)
        #expect(model.iPhoneClients.isEmpty)
    }

    @Test("config.json relu : la reconnexion suivante prend le nouveau port")
    func reloadConfig() throws {
        try connect()
        model.reloadConfig(PTZDConfig(port: 19870, isFallback: false))
        #expect(!model.config.isFallback)
        transport.emit(.closed)
        scheduler.advance(by: PanelModel.retryDelay)
        #expect(transport.opened.last == URL(string: "ws://127.0.0.1:19870")!)
    }

    @Test("ptzd ne répond pas : état effacé, nouvel essai toutes les 2 s")
    func reconnects() throws {
        try connect()
        transport.emit(.closed)
        #expect(model.service == .unreachable)
        #expect(model.state == nil)
        #expect(model.admin == nil)
        scheduler.advance(by: PanelModel.retryDelay - 0.1)
        #expect(transport.opened.count == 1)
        scheduler.advance(by: 0.1)
        #expect(transport.opened.count == 2)
        transport.emit(.closed)
        scheduler.advance(by: PanelModel.retryDelay)
        #expect(transport.opened.count == 3)
    }

    @Test("Actions : chaque bouton envoie son message ; rien n'est envoyé hors connexion")
    func actions() throws {
        model.setPrivacy(true)
        #expect(transport.sent.isEmpty)
        try connect(devices: [device])
        model.setPrivacy(true)
        model.setAITracking(true)
        model.setAutoExposure(true)
        model.setAutoExposure(false)
        model.kick(device.deviceID)
        model.unblock(device.deviceID)
        model.revoke(device.deviceID)
        #expect(Array(sent.dropFirst()) == [
            .privacy(on: true), .aiTracking(on: true), .autoExposure(on: true), .autoExposure(on: false), .kick(deviceID: device.deviceID),
            .unblock(deviceID: device.deviceID), .revoke(deviceID: device.deviceID),
        ])
    }

    @Test("obsbot-ai recompilé : aiUpdated envoyé tout de suite, ou à la prochaine connexion ; le dernier refus reste affiché")
    func aiUpdated() throws {
        // Hors connexion : le message attend la connexion suivante.
        model.aiUpdated()
        #expect(transport.sent.isEmpty)
        try connect()
        #expect(sent == [.adminWatch, .aiUpdated])
        // Connecté : tout de suite, une seule fois par recompilation.
        try receive(.error(code: .badMessage, message: "x"))
        model.aiUpdated()
        #expect(sent == [.adminWatch, .aiUpdated, .aiUpdated])
        #expect(model.lastError == "ptzd a refusé ce message.")
        transport.emit(.closed)
        scheduler.advance(by: PanelModel.retryDelay)
        transport.emit(.opened)
        try receive(.authenticated)
        #expect(sent.filter { $0 == .aiUpdated }.count == 2)
    }

    @Test("Refus de ptzd : texte de l'app choisi d'après le code (pas celui de ptzd), effacé à l'action suivante")
    func errors() throws {
        try connect()
        try receive(.error(code: .badMessage, message: "Appareil inconnu."))
        #expect(model.lastError == "ptzd a refusé ce message.")
        model.setPrivacy(false)
        #expect(model.lastError == nil)
        try receive(.error(code: .uvcFailed, message: "Suivi IA non modifié (délai dépassé)."))
        #expect(model.lastError == "Suivi IA non modifié : délai dépassé.")
    }

    @Test("Appairage : invitation affichée en QR, puis appareil nouveau : « appairé », fenêtre fermée 3 s après")
    func pairingSucceeds() throws {
        try connect(devices: [device])
        model.openPairing()
        #expect(sent.last == .openPairing)
        let session = try #require(model.pairing)
        #expect(session.phase == .waiting)
        let invitation = PairingInvitation(pairingID: "1a2b3c4d", secret: Data(repeating: 5, count: 32), expiresAt: Date(timeIntervalSince1970: 1_791_301_300), hosts: ["192.168.0.10"], port: 1985)
        try receive(.pairingOpened(invitation))
        try receive(.adminState(AdminState(devices: [device], clients: [], pairing: AdminPairing(pairingID: "1a2b3c4d", expiresAt: invitation.expiresAt))))
        #expect(session.phase == .showing(invitation))
        #expect(session.link == PairingLink(invitation).url.absoluteString)
        let newDevice = AdminDevice(deviceID: "ffeeddccbbaa99887766554433221100", name: "iPhone de test", pairedAt: Date(), blockedUntil: nil)
        try receive(.adminState(AdminState(devices: [device, newDevice], clients: [], pairing: nil)))
        #expect(session.phase == .paired(name: "iPhone de test", shortID: "ffeeddcc"))
        scheduler.advance(by: PairingSession.closeDelay)
        #expect(model.pairing == nil)
        #expect(!sent.contains(.closePairing))
    }

    @Test("Appairage expiré (ou refusé) : « expiré » ; « Recommencer » relance un appairage")
    func pairingExpires() throws {
        try connect()
        model.openPairing()
        let invitation = PairingInvitation(pairingID: "1a2b3c4d", secret: Data(repeating: 5, count: 32), expiresAt: Date(), hosts: ["192.168.0.10"], port: 1985)
        try receive(.pairingOpened(invitation))
        try receive(.adminState(AdminState(devices: [], clients: [], pairing: nil)))
        #expect(model.pairing?.phase == .expired)
        model.openPairing()
        #expect(model.pairing?.phase == .waiting)
        #expect(sent.filter { $0 == .openPairing }.count == 2)
    }

    @Test("Fenêtre fermée pendant l'affichage du QR : closePairing envoyé, fenêtre oubliée")
    func closingWindow() throws {
        try connect()
        model.openPairing()
        try receive(.pairingOpened(PairingInvitation(pairingID: "1a2b3c4d", secret: Data(repeating: 5, count: 32), expiresAt: Date(), hosts: ["192.168.0.10"], port: 1985)))
        model.closePairing()
        #expect(sent.last == .closePairing)
        #expect(model.pairing == nil)
    }

    @Test("Invitation sans adresse locale : « aucune adresse »")
    func noAddress() throws {
        try connect()
        model.openPairing()
        try receive(.pairingOpened(PairingInvitation(pairingID: "1a2b3c4d", secret: Data(repeating: 5, count: 32), expiresAt: Date(), hosts: [], port: 1985)))
        #expect(model.pairing?.phase == .noAddress)
    }

    @Test("Fermer pendant l'attente de l'invitation : closePairing envoyé")
    func closingWhileWaiting() throws {
        try connect()
        model.openPairing()
        #expect(model.pairing?.phase == .waiting)
        model.closePairing()
        #expect(sent.last == .closePairing)
        #expect(model.pairing == nil)
    }

    @Test("Fermer avec invitation sans adresse : closePairing envoyé")
    func closingNoAddress() throws {
        try connect()
        model.openPairing()
        try receive(.pairingOpened(PairingInvitation(pairingID: "1a2b3c4d", secret: Data(repeating: 5, count: 32), expiresAt: Date(), hosts: [], port: 1985)))
        #expect(model.pairing?.phase == .noAddress)
        model.closePairing()
        #expect(sent.last == .closePairing)
        #expect(model.pairing == nil)
    }

    @Test("Reappairage d'un appareil connu avec pairedAt différent : « appairé »")
    func rePairingKnownDevice() throws {
        try connect(devices: [device])
        model.openPairing()
        let invitation = PairingInvitation(pairingID: "1a2b3c4d", secret: Data(repeating: 5, count: 32), expiresAt: Date(timeIntervalSince1970: 1_791_301_300), hosts: ["192.168.0.10"], port: 1985)
        try receive(.pairingOpened(invitation))
        let rePairedDevice = AdminDevice(deviceID: device.deviceID, name: device.name, pairedAt: Date(timeIntervalSince1970: 1_791_400_000), blockedUntil: nil)
        try receive(.adminState(AdminState(devices: [rePairedDevice], clients: [], pairing: nil)))
        #expect(model.pairing?.phase == .paired(name: device.name, shortID: String(device.deviceID.prefix(8))))
    }
}
