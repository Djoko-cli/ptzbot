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

    @Test("Vie privée : le mode dit ce qui est coupé ; sans mode (ptzd ancien), le texte d'avant")
    func privacyModeTexts() {
        func privacyState(_ mode: PrivacyMode?) -> StateSnapshot {
            StateSnapshot(camera: .connected, control: .ready, privacy: true, pan: 0, tilt: 0, zoom: 0, moving: false, privacyMode: mode)
        }
        #expect(text(privacyState(nil)) == "Vie privée")
        #expect(text(privacyState(.native)) == "Vie privée : image et micro coupés")
        #expect(text(privacyState(.tilt)) == "Sans le SDK OBSBOT, la vie privée détourne seulement l'objectif : l'image et le micro ne sont pas coupés.")
        // Le mode n'a d'effet qu'en vie privée.
        var off = privacyState(.tilt)
        off.privacy = false
        #expect(text(off) == nil)
        // La caméra débranchée passe avant.
        var absent = privacyState(.tilt)
        absent.camera = .absent
        #expect(text(absent) == "Caméra débranchée")
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
