import Foundation
import Testing
@testable import PTZBotKit

/// Les pastilles du panneau (spec B3 § 6.1) : l'état normal de chaque service est une pastille verte, sans ligne ; toute
/// autre situation a sa ligne d'état.
@Suite("Pastilles des services", .french)
struct ServiceIndicatorTests {
    @Test("ptzd : actif et connecté, pastille verte sans ligne ; sinon la ligne, la raison d'un échec en rouge")
    func ptzd() {
        #expect(Labels.ptzdIndicator(.running, connection: .active, legacy: false) == .normal)
        #expect(Labels.ptzdIndicator(.running, connection: .unreachable, legacy: false) == ServiceIndicator(tone: .attention, line: "Ne répond pas"))
        #expect(Labels.ptzdIndicator(.running, connection: .connecting, legacy: false) == ServiceIndicator(tone: .neutral, line: "Démarrage…"))
        #expect(Labels.ptzdIndicator(.stopped, connection: .unreachable, legacy: false) == ServiceIndicator(tone: .neutral, line: "Arrêté"))
        #expect(Labels.ptzdIndicator(.restarting(count: 2), connection: .unreachable, legacy: false)
            == ServiceIndicator(tone: .attention, line: "Relancé après un arrêt inattendu (2)"))
        #expect(Labels.ptzdIndicator(.failed(reason: "raison"), connection: .unreachable, legacy: false) == ServiceIndicator(tone: .failure, line: "raison"))
        #expect(Labels.ptzdIndicator(.stopped, connection: .active, legacy: true) == ServiceIndicator(tone: .attention, line: "Ancienne installation"))
    }

    @Test("Talkback : prêt ou en lecture, pastille verte ; éteint, gris ; à autoriser ou arrêté, orange")
    func talkback() {
        #expect(Labels.talkbackIndicator(.ready) == .normal)
        #expect(Labels.talkbackIndicator(.playing) == .normal)
        #expect(Labels.talkbackIndicator(.disabled) == ServiceIndicator(tone: .neutral, line: "Désactivé"))
        #expect(Labels.talkbackIndicator(.requiresApproval) == ServiceIndicator(tone: .attention, line: "Autorisation requise"))
        #expect(Labels.talkbackIndicator(.notRunning).tone == .attention)
    }

    @Test("SDK OBSBOT : prêt, pastille verte ; sinon son état court")
    func sdk() {
        #expect(Labels.sdkIndicator(.ready) == .normal)
        #expect(Labels.sdkIndicator(nil) == ServiceIndicator(tone: .neutral, line: "Vérification…"))
        #expect(Labels.sdkIndicator(.absent) == ServiceIndicator(tone: .attention, line: "Absent"))
    }

    @Test("go2rtc : actif sans alerte, pastille verte sans ligne ; fichier personnalisé : pastille verte et sa ligne")
    func go2rtcNormal() {
        #expect(Labels.go2rtcIndicator(.running, isEnabled: true, usesCustomFile: false, health: Go2RTCHealth()) == .normal)
        #expect(Labels.go2rtcIndicator(.running, isEnabled: true, usesCustomFile: true, health: Go2RTCHealth())
            == ServiceIndicator(tone: .normal, line: "Fichier de configuration personnalisé"))
    }

    @Test("go2rtc : éteint, démarrage, relance, et chaque panne de la spec avec sa ligne")
    func go2rtcStates() {
        func line(_ state: Go2RTCSupervisor.State, enabled: Bool = true, health: Go2RTCHealth = Go2RTCHealth()) -> ServiceIndicator {
            Labels.go2rtcIndicator(state, isEnabled: enabled, usesCustomFile: false, health: health)
        }
        #expect(line(.stopped, enabled: false) == ServiceIndicator(tone: .neutral, line: "Désactivé"))
        #expect(line(.starting) == ServiceIndicator(tone: .neutral, line: "Démarrage…"))
        #expect(line(.restarting(count: 3)) == ServiceIndicator(tone: .attention, line: "Relancé après un arrêt inattendu (3)"))
        #expect(line(.failed(.blocked(.ffmpegMissing))) == ServiceIndicator(tone: .attention, line: "ffmpeg introuvable"))
        #expect(line(.failed(.blocked(.portBusy(8554))))
            == ServiceIndicator(tone: .attention, line: "Port 8554 déjà utilisé : un autre go2rtc tourne-t-il ?"))
        #expect(line(.failed(.blocked(.cameraMissing))) == ServiceIndicator(tone: .attention, line: "Caméra OBSBOT absente"))
        #expect(line(.failed(.crashLoop)) == ServiceIndicator(tone: .failure, line: "go2rtc s'arrête sans cesse : ouvrez le journal"))
        #expect(line(.failed(.missingBinary)).tone == .failure)
        #expect(line(.running, health: Go2RTCHealth(cameraMissing: true)) == ServiceIndicator(tone: .attention, line: "Caméra OBSBOT absente"))
        #expect(line(.running, health: Go2RTCHealth(accessDenied: true, cameraMissing: true))
            == ServiceIndicator(tone: .attention, line: "Accès à la caméra refusé"))
        #expect(line(.running, health: Go2RTCHealth(accessDenied: true, coreAudioStuck: true))
            == ServiceIndicator(tone: .attention, line: "coreaudiod ne répond pas : la caméra est bloquée"))
        // Captures ffmpeg bloquées, coreaudiod qui répond : orange, sans commande de réparation ; coreaudiod passe avant.
        #expect(line(.running, health: Go2RTCHealth(accessDenied: true, cameraMissing: true, capturesStuck: true))
            == ServiceIndicator(tone: .attention, line: "Des captures ffmpeg sont bloquées"))
        // Au-delà de quelques minutes : le texte renvoie au journal, sans rien promettre.
        #expect(line(.running, health: Go2RTCHealth(capturesStuck: true, capturesStuckLong: true))
            == ServiceIndicator(tone: .attention, line: "Des captures ffmpeg sont bloquées : ouvrez le journal"))
        #expect(line(.running, health: Go2RTCHealth(coreAudioStuck: true, capturesStuck: true))
            == ServiceIndicator(tone: .attention, line: "coreaudiod ne répond pas : la caméra est bloquée"))
    }

    @Test("Survol : aucun client, un client, plusieurs avec le détail par protocole ; sans lecture, rien")
    func help() {
        #expect(Labels.go2rtcHelp(nil) == nil)
        #expect(Labels.go2rtcHelp(Go2RTCStreamStatus(clients: Go2RTCClients(), hasActiveProducer: true)) == "Aucun client")
        #expect(Labels.go2rtcHelp(Go2RTCStreamStatus(clients: Go2RTCClients(byType: ["rtsp": 1]), hasActiveProducer: true)) == "1 client · RTSP ×1")
        let mixed = Go2RTCClients(byType: ["webrtc": 1, "rtsp": 2, "zz": 1, "": 1])
        #expect(Labels.go2rtcHelp(Go2RTCStreamStatus(clients: mixed, hasActiveProducer: true)) == "5 clients · RTSP ×2, WebRTC ×1, autre ×1, ZZ ×1")
    }

    @Test("Les textes de go2rtc en anglais")
    func english() {
        Localization.$languageOverride.withValue("en") {
            #expect(Labels.go2rtcBlock(.portBusy(8554)) == "Port 8554 already in use: is another go2rtc running?")
            #expect(Labels.coreAudioStuck == "coreaudiod is not responding: the camera is stuck")
            #expect(Labels.capturesStuck == "ffmpeg captures are stuck")
            #expect(Labels.capturesStuckLong == "ffmpeg captures are stuck: open the log")
            #expect(Labels.quitStopsCamera == "Quitting PTZBot also stops the HomeKit camera.")
            #expect(Labels.go2rtcHelp(Go2RTCStreamStatus(clients: Go2RTCClients(byType: ["rtsp": 2]), hasActiveProducer: true)) == "2 clients · RTSP ×2")
        }
    }
}
