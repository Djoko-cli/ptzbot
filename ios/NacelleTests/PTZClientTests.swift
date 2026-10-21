import CryptoKit
import Foundation
import NacelleProtocol
import Network
import Testing
@testable import Nacelle

@MainActor
@Suite("Client ptzd")
struct PTZClientTests {
    let transports = FakeTransports()
    let browser = FakeBrowser()
    let keys = FakeKeyStore()
    let scheduler = FakeScheduler()
    let record = PairingRecord(defaults: UserDefaults(suiteName: "ptzclient-\(UUID().uuidString)")!)
    let client: PTZClient
    let url = URL(string: "ws://mac.exemple.ts.net:1985")!
    /// Le champ porte le nom Tailscale : la connexion part en WebSocket simple vers `url`.
    let settings = ConnectionSettings(host: "mac.exemple.ts.net")
    let service = NWEndpoint.service(name: "PTZBot sur Mac", type: "_nacelle._tcp", domain: "local.", interface: nil)
    /// QR code de `ptzd pair`.
    let link = PairingLink(pairingID: "1a2b3c4d", secret: Data(repeating: 5, count: 32), hosts: ["192.0.2.30", "192.0.2.31"], port: 1985)
    let nonce = Data(repeating: 7, count: 32)
    let lanKey = Data(repeating: 9, count: 32)

    init() {
        let transports = transports
        client = PTZClient(
            makeTransport: { _ in transports.make() },
            browser: browser,
            keys: keys,
            pairingRecord: record,
            scheduler: scheduler
        )
        keys.key = SoftwareDeviceKey(key: P256.Signing.PrivateKey())
        keys.storedLANKey = lanKey
    }

    private var tailscale: FakeTransport {
        transports.to(.url(url))!
    }

    private func decoded(_ transport: FakeTransport) -> [ClientMessage] {
        transport.sent.compactMap { try? NacelleCodec.decodeClient($0) }
    }

    private func emit(_ message: ServerMessage, on transport: FakeTransport) throws {
        transport.emit(.message(try NacelleCodec.encode(message)))
    }

    /// Identité TLS et secret du QR code.
    private var pairingCredentials: LANCredentials {
        LANCredentials(identity: "pair-1a2b3c4d", key: link.secret)
    }

    /// La connexion vers une adresse du QR code.
    private func qr(_ host: String) -> FakeTransport? {
        transports.to(.tls(.url(URL(string: "ws://\(host):1985")!), pairingCredentials))
    }

    /// Ouverture, défi, signature, authentification, par Tailscale.
    private func connect() throws {
        client.start(settings: settings)
        tailscale.emit(.opened)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
    }

    /// Connexion authentifiée par le réseau local (TLS, service Bonjour) ; renvoie ce transport.
    private func connectLocal() throws -> FakeTransport {
        client.start(settings: settings)
        browser.find(service)
        let local = try #require(transports.local)
        local.emit(.opened)
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.authenticated, on: local)
        try #require(client.link == .connected)
        return local
    }

    /// Messages envoyés après l'authentification.
    private func commands(_ transport: FakeTransport) -> [ClientMessage] {
        decoded(transport).filter { if case .auth = $0 { false } else { true } }
    }

    // MARK: - Authentification

    @Test("Défi : réponse signée, vérifiable par ptzd")
    func answersChallenge() throws {
        client.start(settings: settings)
        tailscale.emit(.opened)
        #expect(client.link == .connecting)
        try emit(.challenge(nonce: nonce), on: tailscale)
        guard case let .auth(deviceID, signature) = decoded(tailscale).first else {
            Issue.record("auth attendu")
            return
        }
        let key = try #require(keys.key)
        #expect(deviceID == key.deviceID)
        #expect(NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: key.publicKeyX963))
    }

    @Test("Authentifié : connecté, prise en main envoyée, appairage retenu")
    func takeControlAfterAuth() throws {
        try connect()
        #expect(client.link == .connected)
        #expect(commands(tailscale) == [.takeControl])
        #expect(client.isPaired)
        #expect(record.isPaired)
    }

    @Test("Sans clé : « non appairé » sans rien ouvrir, plus de reconnexion")
    func noKey() throws {
        keys.key = nil
        client.start(settings: settings)
        #expect(client.authIssue == .unpaired)
        #expect(client.link == .idle)
        #expect(!browser.isRunning)
        scheduler.advance(by: 30)
        #expect(transports.all.isEmpty)
    }

    @Test("ptzd ne connaît pas l'iPhone : « non appairé », appairage oublié")
    func unpairedByServer() throws {
        record.isPaired = true
        try connect()
        client.stop()
        client.start(settings: settings)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .unpaired, message: "x"), on: tailscale)
        #expect(client.authIssue == .unpaired)
        #expect(!client.isPaired)
        #expect(!record.isPaired)
        #expect(client.link == .idle)
    }

    @Test("Signature refusée : « refusé », plus de reconnexion")
    func rejected() throws {
        client.start(settings: settings)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .authFailed, message: "x"), on: tailscale)
        #expect(client.authIssue == .rejected)
        tailscale.emit(.closed)
        scheduler.advance(by: 30)
        #expect(transports.all.count == 1)
    }

    // MARK: - Appairage par QR code

    @Test("QR code : chaque adresse du QR et Bonjour, en TLS avec le secret du QR ; pas l'adresse du champ")
    func pairingCandidates() throws {
        keys.key = nil
        keys.storedLANKey = nil
        client.start(settings: settings)
        client.pair(with: link)
        #expect(qr("192.0.2.30") != nil)
        #expect(qr("192.0.2.31") != nil)
        #expect(transports.to(.url(url)) == nil)
        #expect(browser.isRunning)
        browser.find(service)
        #expect(transports.local?.opened == [.tls(service, pairingCredentials)])
        #expect(transports.all.count == 3)
    }

    @Test("QR code : clé créée, preuve sur le défi ; paired : secret rangé, adresse retenue, auth sur le même défi")
    func pairing() throws {
        keys.key = nil
        keys.storedLANKey = nil
        var learned: [String] = []
        client.onAddressLearned = { learned.append("\($0):\($1)") }
        client.start(settings: settings)
        #expect(!client.isPairing)
        client.pair(with: link)
        #expect(client.isPairing)
        let first = try #require(qr("192.0.2.30"))
        first.remoteAddress = "192.0.2.30"
        first.emit(.opened)
        try emit(.challenge(nonce: nonce), on: first)
        let key = try #require(keys.key)
        let proof = NacelleAuth.pairingProof(secret: link.secret, nonce: nonce, publicKeyX963: key.publicKeyX963)
        #expect(decoded(first) == [.pair(pairingID: "1a2b3c4d", publicKey: key.publicKeyX963, name: "iPhone", proof: proof)])
        let newKey = Data(repeating: 3, count: 32)
        try emit(.paired(deviceID: key.deviceID, lanKey: newKey), on: first)
        #expect(keys.storedLANKey == newKey)
        #expect(client.isPaired)
        #expect(!client.isPairing)
        #expect(learned == ["192.0.2.30:1985"])
        guard case let .auth(deviceID, signature) = decoded(first).last else {
            Issue.record("auth attendu après paired")
            return
        }
        #expect(NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: key.publicKeyX963))
        try emit(.authenticated, on: first)
        #expect(client.link == .connected)
        #expect(client.authIssue == nil)
        // Le QR ne sert qu'une fois : la connexion suivante revient au champ et à Bonjour.
        client.stop()
        let before = transports.all.count
        client.start(settings: settings)
        #expect(transports.all.count == before + 1)
        #expect(transports.last?.opened == [.url(url)])
    }

    @Test("QR code, deux connexions au défi : une seule envoie la preuve, l'autre s'authentifie après paired ; adresse du QR retenue")
    func pairingWithTwoPaths() throws {
        keys.key = nil
        var learned: [String] = []
        client.onAddressLearned = { learned.append("\($0):\($1)") }
        client.start(settings: settings)
        client.pair(with: link)
        browser.find(service)
        let local = try #require(transports.local)
        let first = try #require(qr("192.0.2.30"))
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.challenge(nonce: nonce), on: first)
        #expect(decoded(local).count == 1)
        #expect(decoded(first).isEmpty)
        let key = try #require(keys.key)
        // Un « paired » d'une connexion qui n'a pas envoyé la preuve ne compte pas.
        try emit(.paired(deviceID: key.deviceID, lanKey: lanKey), on: first)
        #expect(decoded(first).isEmpty)
        try emit(.paired(deviceID: key.deviceID, lanKey: lanKey), on: local)
        #expect(decoded(local).contains { if case .auth = $0 { true } else { false } })
        #expect(decoded(first).contains { if case .auth = $0 { true } else { false } })
        // Service Bonjour sans adresse résolue : la première adresse du QR est retenue.
        #expect(learned == ["192.0.2.30:1985"])
    }

    @Test("QR code refusé par ptzd : « QR code refusé », plus de reconnexion, QR oublié", arguments: [ErrorCode.badCode, .pairingClosed, .notLocal])
    func pairingRefused(_ code: ErrorCode) throws {
        keys.key = nil
        client.start(settings: settings)
        client.pair(with: link)
        let first = try #require(qr("192.0.2.30"))
        try emit(.challenge(nonce: nonce), on: first)
        try emit(.error(code: code, message: "x"), on: first)
        #expect(client.authIssue == .badCode)
        #expect(!client.isPairing)
        #expect(client.link == .idle)
        #expect(first.closeCount >= 1)
        let opened = transports.all.count
        scheduler.advance(by: 30)
        #expect(transports.all.count == opened)
        client.stop()
        client.start(settings: settings)
        #expect(transports.last?.opened == [.url(url)])
    }

    @Test("QR refusé sur un iPhone déjà appairé : simple avis, pas d'arrêt, reconnexion normale")
    func pairingRefusedWhenPaired() throws {
        try connect()
        var refused = 0
        client.onPairingRefused = { refused += 1 }
        client.pair(with: link)
        let first = try #require(qr("192.0.2.30"))
        try emit(.challenge(nonce: nonce), on: first)
        try emit(.error(code: .pairingClosed, message: "x"), on: first)
        #expect(refused == 1)
        #expect(client.authIssue == nil)
        #expect(!client.isPairing)
        #expect(client.link == .connecting)
        #expect(transports.last?.opened == [.url(url)])
    }

    @Test("Expulsé à l'authentification, par Tailscale ou par le réseau local : « expulsé », plus de reconnexion")
    func blockedAtAuthentication() throws {
        try connect()
        #expect(client.isPaired == true)
        client.stop()
        client.start(settings: settings)
        browser.find(service)
        let local = try #require(transports.local)
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.error(code: .blocked, message: "Expulsé par le Mac jusqu'à 20:14."), on: local)
        #expect(client.authIssue == .blocked)
        #expect(client.link == .idle)
        let opened = transports.all.count
        scheduler.advance(by: 30)
        #expect(transports.all.count == opened)
        #expect(client.isPaired == true)
    }

    @Test("Expulsé pendant la session : arrêt tout de suite, sans tentative refusée d'avance")
    func blockedDuringSession() throws {
        try connect()
        try emit(.error(code: .blocked, message: "Expulsé par le Mac jusqu'à 20:14."), on: tailscale)
        #expect(client.authIssue == .blocked)
        #expect(client.link == .idle)
        #expect(client.state == nil)
        let opened = transports.all.count
        scheduler.advance(by: 30)
        #expect(transports.all.count == opened)
    }

    @Test("Retiré par le Mac pendant la session locale (TLS, unpaired reçu) : clé supprimée, « non appairé », plus de reconnexion")
    func unpairedDuringSession() throws {
        let local = try connectLocal()
        #expect(client.isPaired)
        try emit(.error(code: .unpaired, message: "Appareil retiré depuis le Mac."), on: local)
        #expect(keys.key == nil)
        #expect(keys.storedLANKey == nil)
        #expect(!client.isPaired)
        #expect(client.authIssue == .unpaired)
        #expect(client.link == .idle)
        #expect(client.state == nil)
        let opened = transports.all.count
        scheduler.advance(by: 30)
        #expect(transports.all.count == opened)
    }

    @Test("unpaired reçu par Tailscale (WebSocket simple, Mac non authentifié) : clés gardées, « non appairé », plus de reconnexion")
    func unpairedOverTailscaleKeepsKeys() throws {
        try connect()
        #expect(client.isPaired)
        try emit(.error(code: .unpaired, message: "Appareil retiré depuis le Mac."), on: tailscale)
        #expect(keys.key != nil)
        #expect(keys.storedLANKey != nil)
        #expect(!client.isPaired)
        #expect(!record.isPaired)
        #expect(client.authIssue == .unpaired)
        #expect(client.link == .idle)
        #expect(client.state == nil)
        let opened = transports.all.count
        scheduler.advance(by: 30)
        #expect(transports.all.count == opened)
    }

    @Test("unpaired reçu pendant un oubli en attente : l'oubli s'achève, minuterie annulée")
    func unpairedDuringPendingForget() throws {
        try connect()
        client.forgetPairing()
        try emit(.error(code: .unpaired, message: "Appareil retiré depuis le Mac."), on: tailscale)
        #expect(keys.key == nil)
        #expect(!client.isPaired)
        #expect(client.authIssue == .unpaired)
        scheduler.advance(by: PTZClient.forgetTimeout * 2)
        #expect(client.authIssue == .unpaired)
        #expect(client.link == .idle)
    }

    @Test("Suivi IA : l'ordre part sur la connexion active")
    func aiTrackingOrder() throws {
        try connect()
        client.setAITracking(true)
        client.setAITracking(false)
        #expect(commands(tailscale).suffix(2) == [.aiTracking(on: true), .aiTracking(on: false)])
    }

    @Test("Exposition auto : l'ordre part sur la connexion active")
    func autoExposureOrder() throws {
        try connect()
        client.setAutoExposure(true)
        client.setAutoExposure(false)
        #expect(commands(tailscale).suffix(2) == [.autoExposure(on: true), .autoExposure(on: false)])
    }

    @Test("Aucun Mac ne répond avec le QR (secret refusé en TLS, Mac injoignable) : « QR code refusé », sans reconnexion")
    func pairingUnanswered() throws {
        keys.key = nil
        client.start(settings: settings)
        client.pair(with: link)
        try #require(qr("192.0.2.30")).emit(.closed)
        try #require(qr("192.0.2.31")).emit(.closed)
        #expect(client.link == .connecting)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.authIssue == .badCode)
        #expect(client.link == .idle)
        let opened = transports.all.count
        scheduler.advance(by: 30)
        #expect(transports.all.count == opened)
    }

    @Test("Oublier l'appairage sans connexion : clé et secret supprimés tout de suite, rien envoyé")
    func forget() throws {
        client.start(settings: settings)
        tailscale.emit(.opened)
        client.forgetPairing()
        #expect(keys.key == nil)
        #expect(keys.storedLANKey == nil)
        #expect(!client.isPaired)
        #expect(client.authIssue == .unpaired)
        #expect(!decoded(tailscale).contains(.forgetMe))
    }

    @Test("Oublier l'appairage connecté : forgetMe d'abord, puis l'oubli local à la fermeture de la connexion")
    func forgetWhenConnected() throws {
        try connect()
        client.forgetPairing()
        #expect(commands(tailscale).suffix(1) == [.forgetMe])
        // Rien n'est encore oublié : on attend que le Mac coupe.
        #expect(keys.key != nil)
        #expect(client.isPaired)
        tailscale.emit(.closed)
        #expect(keys.key == nil)
        #expect(keys.storedLANKey == nil)
        #expect(!client.isPaired)
        #expect(client.authIssue == .unpaired)
        // La minuterie du délai ne refait rien.
        scheduler.advance(by: PTZClient.forgetTimeout * 2)
        #expect(client.authIssue == .unpaired)
        #expect(commands(tailscale).filter { $0 == .forgetMe }.count == 1)
    }

    @Test("Oublier l'appairage connecté, ptzd ancien (badMessage) : oubli local tout de suite")
    func forgetWithOlderPTZD() throws {
        try connect()
        client.forgetPairing()
        #expect(keys.key != nil)
        try emit(.error(code: .badMessage, message: "Message illisible."), on: tailscale)
        #expect(keys.key == nil)
        #expect(!client.isPaired)
        #expect(client.authIssue == .unpaired)
    }

    @Test("Oubli en attente puis retour en arrière-plan : forgetMe déjà parti, l'oubli local s'achève tout de suite")
    func forgetFinishedByStop() throws {
        try connect()
        client.forgetPairing()
        #expect(keys.key != nil)
        client.stop()
        #expect(keys.key == nil)
        #expect(keys.storedLANKey == nil)
        #expect(!client.isPaired)
        #expect(client.authIssue == .unpaired)
        #expect(client.link == .idle)
        let opened = transports.all.count
        scheduler.advance(by: PTZClient.forgetTimeout * 2)
        #expect(transports.all.count == opened)
        #expect(client.authIssue == .unpaired)
    }

    @Test("Oubli en attente puis nouveau start : l'oubli local s'achève, la connexion s'arrête sur « non appairé »")
    func forgetFinishedByStart() throws {
        try connect()
        client.forgetPairing()
        client.start(settings: settings)
        #expect(keys.key == nil)
        #expect(keys.storedLANKey == nil)
        #expect(!client.isPaired)
        #expect(client.authIssue == .unpaired)
        #expect(client.link == .idle)
    }

    @Test("Oublier l'appairage connecté, le Mac ne coupe pas : oubli local au bout de 2 s")
    func forgetWhenConnectedTimesOut() throws {
        try connect()
        client.forgetPairing()
        client.forgetPairing()
        #expect(commands(tailscale).filter { $0 == .forgetMe }.count == 1)
        scheduler.advance(by: PTZClient.forgetTimeout - 0.1)
        #expect(keys.key != nil)
        scheduler.advance(by: 0.2)
        #expect(keys.key == nil)
        #expect(!client.isPaired)
        #expect(client.authIssue == .unpaired)
    }

    // MARK: - Adresse du champ

    @Test("Adresse locale dans le champ : jointe en TLS avec le secret de l'iPhone, en plus de Bonjour")
    func localFallback() throws {
        client.start(settings: ConnectionSettings(host: "mac-mini.local"))
        let key = try #require(keys.key)
        let credentials = LANCredentials(identity: key.deviceID, key: lanKey)
        #expect(transports.all.map(\.opened) == [[.tls(.url(URL(string: "ws://mac-mini.local:1985")!), credentials)]])
        #expect(browser.isRunning)
    }

    @Test("Adresse locale sans secret du réseau local : rien à tenter, Mac injoignable")
    func localFallbackWithoutLANKey() {
        keys.storedLANKey = nil
        client.start(settings: ConnectionSettings(host: "mac-mini.local"))
        #expect(transports.all.isEmpty)
        #expect(!browser.isRunning)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.isUnreachable)
        #expect(client.link == .waitingToRetry)
    }

    @Test("Adresse retenue en cours de route : prise en compte à la tentative suivante, sans couper")
    func updateSettings() throws {
        client.start(settings: ConnectionSettings())
        #expect(transports.all.isEmpty)
        client.update(settings)
        #expect(client.link == .connecting)
        scheduler.advance(by: PTZClient.discoveryWindow)
        scheduler.advance(by: 1)
        #expect(transports.last?.opened == [.url(url)])
    }

    // MARK: - Choix du chemin

    @Test("Les deux chemins essayés ; le premier authentifié l'emporte, l'autre est fermé")
    func race() throws {
        client.start(settings: settings)
        #expect(browser.isRunning)
        browser.find(service)
        let local = try #require(transports.local)
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: local)
        #expect(client.link == .connected)
        #expect(commands(local) == [.takeControl])
        #expect(tailscale.closeCount >= 1)
        #expect(!browser.isRunning)
        // Une authentification tardive du perdant est ignorée.
        try emit(.authenticated, on: tailscale)
        #expect(commands(tailscale).isEmpty)
    }

    @Test("Bonjour ne trouve rien : Tailscale seul, sans message")
    func noLocalService() throws {
        client.start(settings: settings)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(!browser.isRunning)
        tailscale.emit(.opened)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        #expect(client.link == .connected)
        #expect(!client.isUnreachable)
    }

    @Test("Tailscale coupé à la maison : pas d'échec tant que Bonjour cherche")
    func tailscaleDownAtHome() throws {
        client.start(settings: settings)
        tailscale.emit(.closed)
        #expect(client.link == .connecting)
        #expect(!client.isUnreachable)
        browser.find(service)
        let local = try #require(transports.local)
        local.emit(.opened)
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.authenticated, on: local)
        #expect(client.link == .connected)
    }

    @Test("Un seul service local par tentative")
    func oneLocalCandidate() {
        client.start(settings: settings)
        browser.find(service)
        browser.find(.service(name: "PTZBot sur Mac", type: "_nacelle._tcp", domain: "local.", interface: nil))
        #expect(transports.all.count == 2)
    }

    @Test("Erreur « non appairé » d'un service local : seule sa connexion est fermée, Tailscale s'authentifie")
    func localErrorClosesOnlyLocal() throws {
        try connect()
        client.stop()
        client.start(settings: settings)
        browser.find(service)
        let local = try #require(transports.local)
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.error(code: .unpaired, message: "x"), on: local)
        #expect(local.closeCount >= 1)
        #expect(tailscale.closeCount == 0)
        #expect(client.isPaired)
        #expect(record.isPaired)
        #expect(client.link == .connecting)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        #expect(client.link == .connected)
        #expect(client.authIssue == nil)
        #expect(client.isPaired)
    }

    @Test("Erreur d'un service local seul : problème affiché, reconnexions espacées maintenues")
    func localErrorOnlyCandidate() throws {
        client.start(settings: settings)
        browser.find(service)
        let local = try #require(transports.local)
        tailscale.emit(.closed)
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.error(code: .unpaired, message: "x"), on: local)
        #expect(client.authIssue == nil)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.authIssue == .unpaired)
        #expect(client.link == .waitingToRetry)
        let before = transports.all.count
        scheduler.advance(by: 1)
        #expect(transports.all.count == before + 1)
        #expect(client.link == .connecting)
        #expect(client.authIssue == nil)
    }

    @Test("« authenticated » d'une connexion qui n'a pas envoyé auth : fermée, Tailscale peut encore gagner")
    func unsolicitedAuthenticated() throws {
        client.start(settings: settings)
        browser.find(service)
        let local = try #require(transports.local)
        try emit(.authenticated, on: local)
        #expect(local.closeCount >= 1)
        #expect(client.link == .connecting)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        #expect(client.link == .connected)
        #expect(tailscale.closeCount == 0)
        #expect(commands(local).isEmpty)
    }

    @Test("Service local muet : fermé après 10 s, la tentative échoue et une nouvelle est planifiée")
    func silentLocalService() throws {
        client.start(settings: settings)
        browser.find(service)
        let local = try #require(transports.local)
        tailscale.emit(.closed)
        local.emit(.opened)
        try emit(.challenge(nonce: nonce), on: local)
        scheduler.advance(by: PTZClient.authTimeout - 0.01)
        #expect(local.closeCount == 0)
        #expect(client.link == .connecting)
        scheduler.advance(by: 0.01)
        #expect(local.closeCount >= 1)
        #expect(client.link == .waitingToRetry)
        let before = transports.all.count
        scheduler.advance(by: 1)
        #expect(transports.all.count == before + 1)
    }

    @Test("Le délai d'authentification est annulé quand la connexion gagne")
    func deadlineCancelledOnSuccess() throws {
        try connect()
        scheduler.advance(by: PTZClient.authTimeout * 2)
        #expect(client.link == .connected)
        #expect(tailscale.closeCount == 0)
    }

    @Test("Sans secret du réseau local : pas de recherche Bonjour, Tailscale seul")
    func noLocalPathWithoutLANKey() throws {
        keys.storedLANKey = nil
        client.start(settings: settings)
        #expect(browser.startCount == 0)
        browser.find(service)
        #expect(transports.local == nil)
    }

    @Test("Avec un secret : le service local est joint en TLS, identité = deviceID")
    func localPathUsesTLSCredentials() throws {
        client.start(settings: settings)
        #expect(browser.isRunning)
        browser.find(service)
        let key = try #require(keys.key)
        #expect(transports.local?.opened == [.tls(service, LANCredentials(identity: key.deviceID, key: lanKey))])
    }

    @Test("Secret du réseau local non enregistré (trousseau) : l'appairage reste valable, auth sur la même connexion")
    func lanKeySaveFailure() throws {
        keys.key = nil
        keys.storedLANKey = nil
        keys.saveLANKeyError = CocoaError(.fileWriteUnknown)
        client.start(settings: settings)
        client.pair(with: link)
        let first = try #require(qr("192.0.2.30"))
        try emit(.challenge(nonce: nonce), on: first)
        try emit(.paired(deviceID: try #require(keys.key).deviceID, lanKey: lanKey), on: first)
        #expect(client.isPaired)
        #expect(keys.storedLANKey == nil)
        try emit(.authenticated, on: first)
        #expect(client.link == .connected)
    }

    @Test("Problème qui arrête les reconnexions : conservé quand l'app relance une tentative")
    func blockingIssueKept() throws {
        client.start(settings: settings)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .authFailed, message: "x"), on: tailscale)
        #expect(client.authIssue == .rejected)
        client.start(settings: settings)
        #expect(client.authIssue == .rejected)
    }

    // MARK: - Reconnexion

    @Test("Échec des deux chemins : Mac injoignable, nouvel essai après 1, 2, 4 puis 8 s")
    func retryBackoff() {
        client.start(settings: settings)
        tailscale.emit(.closed)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.isUnreachable)
        #expect(client.link == .waitingToRetry)
        for delay in [1.0, 2, 4, 8, 8] {
            let before = transports.all.count
            scheduler.advance(by: delay - 0.01)
            #expect(transports.all.count == before)
            scheduler.advance(by: 0.01)
            #expect(transports.all.count == before + 1)
            transports.last?.emit(.closed)
            scheduler.advance(by: PTZClient.discoveryWindow)
        }
    }

    @Test("Une connexion réussie efface « injoignable » et remet l'espacement à 1 s")
    func recovery() throws {
        client.start(settings: settings)
        tailscale.emit(.closed)
        scheduler.advance(by: PTZClient.discoveryWindow + 1)
        let second = try #require(transports.last)
        second.emit(.opened)
        try emit(.challenge(nonce: nonce), on: second)
        try emit(.authenticated, on: second)
        #expect(!client.isUnreachable)
        second.emit(.closed)
        #expect(!client.isUnreachable)
        #expect(client.link == .waitingToRetry)
        let before = transports.all.count
        scheduler.advance(by: 1)
        #expect(transports.all.count == before + 1)
    }

    @Test("Arrêt ou nouveau départ : « injoignable » est effacé jusqu'au prochain échec")
    func unreachableResetOnStopAndStart() {
        client.start(settings: settings)
        tailscale.emit(.closed)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.isUnreachable)
        client.stop()
        #expect(!client.isUnreachable)
        client.start(settings: settings)
        #expect(!client.isUnreachable)
        #expect(client.link == .connecting)
    }

    @Test("Coupure : le mouvement s'arrête et l'état est oublié")
    func closeStopsRepeating() throws {
        try connect()
        try emit(.state(StateSnapshot(camera: .connected, control: .ready, privacy: false, pan: 0, tilt: 0, zoom: 0, moving: true)), on: tailscale)
        client.setJoystick(JoystickVector(pan: 1, tilt: 0))
        tailscale.emit(.closed)
        let sentAtClose = tailscale.sent.count
        scheduler.advance(by: 0.5)
        #expect(tailscale.sent.count == sentAtClose)
        #expect(client.state == nil)
    }

    @Test("Arrière-plan : move 0,0 si on pilotait, fermeture, aucune reconnexion")
    func stop() throws {
        try connect()
        client.setJoystick(JoystickVector(pan: 1, tilt: 0))
        client.stop()
        #expect(commands(tailscale).last == .move(pan: 0, tilt: 0))
        #expect(tailscale.closeCount >= 1)
        #expect(client.link == .idle)
        #expect(!browser.isRunning)
        scheduler.advance(by: 30)
        #expect(transports.all.count == 1)
    }

    // MARK: - Commandes

    @Test("Joystick hors du centre : move tout de suite, puis 10 fois par seconde")
    func repeatsMove() throws {
        try connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        scheduler.advance(by: 0.35)
        #expect(commands(tailscale) == [.takeControl] + Array(repeating: .move(pan: 0.5, tilt: 0), count: 4))
    }

    @Test("Relâchement : move 0,0 une fois, puis plus rien")
    func releaseSendsStopOnce() throws {
        try connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        client.setJoystick(.zero)
        client.setJoystick(.zero)
        scheduler.advance(by: 1)
        #expect(commands(tailscale) == [.takeControl, .move(pan: 0.5, tilt: 0), .move(pan: 0, tilt: 0)])
    }

    @Test("Un changement de consigne est envoyé sans attendre le prochain tic")
    func newVectorImmediately() throws {
        try connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        client.setJoystick(JoystickVector(pan: 0, tilt: -1))
        #expect(commands(tailscale).last == .move(pan: 0, tilt: -1))
    }

    @Test("L'état reçu est publié ; une erreur est retenue")
    func receivesState() throws {
        try connect()
        let snapshot = StateSnapshot(camera: .connected, control: .ready, privacy: false, pan: 2, tilt: -1, zoom: 33, moving: false)
        try emit(.state(snapshot), on: tailscale)
        try emit(.error(code: .privacyActive, message: "x"), on: tailscale)
        tailscale.emit(.message("pas du json"))
        #expect(client.state == snapshot)
        #expect(client.lastError == .privacyActive)
    }

    @Test("Avant l'authentification, rien n'est envoyé")
    func noSendBeforeAuth() {
        client.start(settings: settings)
        tailscale.emit(.opened)
        client.setZoom(40)
        client.setPrivacy(true)
        #expect(tailscale.sent.isEmpty)
    }

    // MARK: - Vidéo relayée

    /// Laisse les tâches lancées sur le MainActor avancer jusqu'à leur prochaine attente.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    @Test("Négociation : offre envoyée avec un identifiant, réponse rendue")
    func negotiation() async throws {
        try connect()
        let pending = Task { try await client.negotiate(offer: "v=0 offre") }
        await settle()
        #expect(commands(tailscale).last == .webrtcOffer(id: 1, sdp: "v=0 offre"))
        try emit(.webrtcAnswer(id: 1, sdp: "v=0 réponse"), on: tailscale)
        #expect(try await pending.value == "v=0 réponse")
    }

    @Test("Négociation avant la connexion : l'offre part dès l'authentification")
    func negotiationWaitsForLink() async throws {
        client.start(settings: settings)
        let pending = Task { try await client.negotiate(offer: "v=0 offre") }
        await settle()
        #expect(tailscale.sent.isEmpty)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        await settle()
        #expect(commands(tailscale).last == .webrtcOffer(id: 1, sdp: "v=0 offre"))
        try emit(.webrtcAnswer(id: 1, sdp: "v=0 réponse"), on: tailscale)
        #expect(try await pending.value == "v=0 réponse")
    }

    @Test("webrtcError : erreur de relais ; connexion perdue : connectionLost")
    func negotiationFailures() async throws {
        try connect()
        let first = Task { try await client.negotiate(offer: "a") }
        await settle()
        try emit(.webrtcError(id: 1, message: "go2rtc ne répond pas."), on: tailscale)
        await #expect(throws: PTZClient.NegotiationError.relay("go2rtc ne répond pas.")) { try await first.value }

        let second = Task { try await client.negotiate(offer: "b") }
        await settle()
        tailscale.emit(.closed)
        await #expect(throws: PTZClient.NegotiationError.connectionLost) { try await second.value }
    }

    @Test("Sans connexion ni réponse : échec après 10 s")
    func negotiationTimeouts() async throws {
        client.start(settings: settings)
        let waiting = Task { try await client.negotiate(offer: "a") }
        await settle()
        scheduler.advance(by: PTZClient.negotiationTimeout)
        await #expect(throws: PTZClient.NegotiationError.notConnected) { try await waiting.value }
        // Le délai d'authentification (10 s) a aussi fermé la connexion muette : nouvelle tentative.
        scheduler.advance(by: 1)

        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        let silent = Task { try await client.negotiate(offer: "b") }
        await settle()
        scheduler.advance(by: PTZClient.negotiationTimeout)
        await #expect(throws: PTZClient.NegotiationError.timeout) { try await silent.value }
    }

    @Test("Zoom et vie privée")
    func zoomAndPrivacy() throws {
        try connect()
        client.setZoom(40)
        client.setPrivacy(true)
        #expect(commands(tailscale) == [.takeControl, .zoom(value: 40), .privacy(on: true)])
    }

    // MARK: - Voix (spec parler § 4 et § 6.2)

    @Test("Trame voix : envoyée en binaire sur la connexion retenue, fin d'envoi signalée")
    func sendsVoiceFrame() throws {
        try connect()
        let frame = Data(repeating: 3, count: VoiceFrame.byteCount)
        var completed = 0
        #expect(client.sendVoice(frame) { completed += 1 })
        #expect(tailscale.voiceSent == [frame])
        // Rien de la voix n'est passé par le canal texte.
        #expect(commands(tailscale) == [.takeControl])
        tailscale.completeVoice()
        #expect(completed == 1)
    }

    @Test("Trame voix par le réseau local (TLS) : même chemin")
    func sendsVoiceLocally() throws {
        let local = try connectLocal()
        #expect(client.sendVoice(Data(count: VoiceFrame.byteCount)) {})
        #expect(local.voiceSent.count == 1)
    }

    @Test("Hors connexion (avant l'authentification, après une coupure) : refusée, rien n'est envoyé")
    func voiceRefusedWithoutLink() throws {
        #expect(!client.sendVoice(Data(count: VoiceFrame.byteCount)) {})
        client.start(settings: settings)
        tailscale.emit(.opened)
        #expect(!client.sendVoice(Data(count: VoiceFrame.byteCount)) {})
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        #expect(client.sendVoice(Data(count: VoiceFrame.byteCount)) {})
        tailscale.emit(.closed)
        #expect(!client.sendVoice(Data(count: VoiceFrame.byteCount)) {})
        #expect(tailscale.voiceSent.count == 1)
    }

    @Test("Seule une trame de la taille exacte part")
    func voiceSizeChecked() throws {
        try connect()
        #expect(!client.sendVoice(Data(count: 639)) {})
        #expect(!client.sendVoice(Data()) {})
        #expect(tailscale.voiceSent.isEmpty)
    }
}
