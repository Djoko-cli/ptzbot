import NacelleProtocol
import Testing
@testable import Nacelle

@Suite("Bandeau d'état")
struct StatusBannerTests {
    private func state(
        camera: CameraPresence = .connected,
        control: ControlState = .ready,
        privacy: Bool = false
    ) -> StateSnapshot {
        StateSnapshot(camera: camera, control: control, privacy: privacy, pan: 0, tilt: 0, zoom: 0, moving: false)
    }

    private func text(unreachable: Bool = false, connecting: Bool = false, _ state: StateSnapshot? = nil) -> String? {
        StatusBanner.text(for: BannerInputs(macUnreachable: unreachable, connecting: connecting, state: state))
    }

    @Test("Appairage : texte selon le problème, juste après « Mac injoignable »")
    func pairingTexts() {
        func text(_ issue: PTZClient.AuthIssue, unreachable: Bool = false) -> String? {
            StatusBanner.text(for: BannerInputs(macUnreachable: unreachable, authIssue: issue, connecting: true, state: state(camera: .absent)))
        }
        #expect(text(.unpaired) == "iPhone non appairé : scannez le QR code affiché sur le Mac")
        #expect(text(.badCode) == "QR code refusé : relancez l'appairage sur le Mac")
        #expect(text(.rejected) == "Accès refusé par le Mac")
        #expect(text(.blocked) == "Expulsé par le Mac : réessayez plus tard")
        #expect(text(.unpaired, unreachable: true) == "Mac injoignable : Tailscale est-il actif ?")
    }

    @Test("Chaque condition a son texte")
    func texts() {
        #expect(text(unreachable: true) == "Mac injoignable : Tailscale est-il actif ?")
        #expect(text(state(camera: .absent)) == "Caméra débranchée")
        #expect(text(state(privacy: true)) == "Vie privée")
        #expect(text(state(control: .failed)) == "Suivi IA non coupé : les mouvements peuvent être contrés")
        // Un ordre de suivi IA en cours n'a pas de bandeau : le bouton du suivi IA l'indique.
        #expect(text(state(control: .taking)) == nil)
        #expect(text(connecting: true) == "Connexion…")
        #expect(text(state()) == nil)
    }

    @Test("Vie privée : « image et micro coupés » seulement en mode natif ; sinon la raison de ptzd ; sans mode (ptzd ancien), le texte d'avant")
    func privacyModeTexts() {
        func privacyState(_ mode: PrivacyMode?, _ reason: PrivacyReason? = nil) -> StateSnapshot {
            StateSnapshot(camera: .connected, control: .ready, privacy: true, pan: 0, tilt: 0, zoom: 0, moving: false,
                          privacyMode: mode, privacyReason: reason)
        }
        #expect(text(privacyState(nil)) == "Vie privée")
        #expect(text(privacyState(.native)) == "Vie privée : image et micro coupés")
        // Mode natif en cours, pas encore constaté.
        #expect(text(privacyState(.tilt)) == "Vie privée : objectif détourné")
        // Objectif pas encore vu détourné (rebranchement, démarrage) : ni « détourné », ni « coupés ».
        #expect(text(privacyState(.tilt, .pending)) == "Vie privée : protection en cours")
        #expect(text(privacyState(.tilt, .noSDK)) == "Vie privée : objectif seulement détourné. Sans le SDK OBSBOT sur le Mac, l'image et le micro ne sont pas coupés.")
        #expect(text(privacyState(.tilt, .updating)) == "Vie privée : objectif seulement détourné, en attendant la mise à jour du SDK OBSBOT sur le Mac.")
        // Repli avec le SDK présent : jamais « Sans le SDK » (relecture, M6).
        #expect(text(privacyState(.tilt, .failed)) == "Vie privée : objectif seulement détourné, l'image et le micro n'ont pas pu être coupés.")
        // Le mode n'a d'effet qu'en vie privée.
        var off = privacyState(.tilt, .failed)
        off.privacy = false
        #expect(text(off) == nil)
        // La caméra débranchée passe avant.
        var absent = privacyState(.tilt)
        absent.camera = .absent
        #expect(text(absent) == "Caméra débranchée")
    }

    @Test("VoiceOver : l'indication du bouton de vie privée suit son état (relecture, M7)")
    func privacyHint() {
        #expect(ControlScreen.privacyHint(on: false) == "Détourne l'objectif et, avec le SDK OBSBOT sur le Mac, coupe l'image et le micro de la caméra")
        #expect(ControlScreen.privacyHint(on: true) == "Ramène la caméra à sa position d'avant la vie privée")
    }

    @Test("Priorité : injoignable, débranchée, vie privée, suivi IA, connexion")
    func priority() {
        let everything = state(camera: .absent, control: .taking, privacy: true)
        #expect(text(unreachable: true, connecting: true, everything) == "Mac injoignable : Tailscale est-il actif ?")
        #expect(text(connecting: true, everything) == "Caméra débranchée")
        #expect(text(connecting: true, state(control: .failed, privacy: true)) == "Vie privée")
        #expect(text(connecting: true, state(control: .failed)) == "Suivi IA non coupé : les mouvements peuvent être contrés")
        #expect(text(connecting: true, state(control: .taking)) == "Connexion…")
    }
}
