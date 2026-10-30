import Foundation
import Testing
@testable import PTZBotKit

@Suite("go2rtc : réglages et yaml généré", .french)
struct Go2RTCConfigTests {
    /// Le modèle exact (spec B3 § 4) : le pipeline en service, paramétré par les réglages par défaut.
    static let expected = [
        "# Écrit par PTZBot (Réglages › Caméra) : ne pas modifier, PTZBot le réécrit.",
        "# Written by PTZBot (Settings › Camera): do not edit, PTZBot rewrites it.",
        "api:",
        "  listen: \"127.0.0.1:1984\"",
        "rtsp:",
        "  listen: \":8554\"",
        "  username: \"ptzbot\"",
        "  password: \"mot-de-passe-de-test\"",
        "webrtc:",
        "  listen: \":8555\"",
        "ffmpeg:",
        "  bin: \"/opt/homebrew/bin/ffmpeg\"",
        "log:",
        "  level: info",
        "preload:",
        "  obsbot:",
        "streams:",
        "  obsbot:",
        "    - >-",
        "      exec:/opt/homebrew/bin/ffmpeg -hide_banner -fflags nobuffer -flags low_delay",
        "      -thread_queue_size 1024",
        "      -f avfoundation -framerate 30 -video_size 1920x1080 -pixel_format nv12 -probesize 32M",
        "      -i \"OBSBOT Tiny 2 StreamCamera\"",
        "      -c:v h264_videotoolbox -realtime 1 -g 30 -bf 0 -level 4.0",
        "      -color_range mpeg -r 30",
        "      -b:v 4M -maxrate 6M -bufsize 2M",
        "      -bsf:v dump_extra=freq=keyframe",
        "      -an",
        "      -rtsp_transport tcp -f rtsp {output}#timeout=30s#killsignal=15",
        "    - >-",
        "      exec:/opt/homebrew/bin/ffmpeg -hide_banner -fflags nobuffer -flags low_delay",
        "      -thread_queue_size 2048",
        "      -f avfoundation -i \":OBSBOT Tiny2 Microphone\"",
        "      -af aresample=async=1000:first_pts=0",
        "      -c:a aac -ar 48000 -ac 2 -b:a 128k",
        "      -vn",
        "      -rtsp_transport tcp -f rtsp {output}#timeout=30s#killsignal=15",
        "    - ffmpeg:obsbot#audio=opus",
    ].joined(separator: "\n") + "\n"

    private func yaml(_ settings: Go2RTCSettings = Go2RTCFixtures.settings(), camera: String = Go2RTCFixtures.camera,
                      microphone: String = Go2RTCFixtures.microphone) throws -> String {
        try Go2RTCConfig.yaml(settings: settings, ffmpeg: Go2RTCFixtures.ffmpeg, camera: camera, microphone: microphone)
    }

    @Test("Modèle exact : les réglages par défaut donnent le pipeline en service")
    func exactModel() throws {
        #expect(try yaml() == Self.expected)
    }

    @Test("Entrées exec en `- >-`, jamais `- >` ; repliées, chacune tient sur une ligne et finit par killsignal=15")
    func foldedBlocks() throws {
        let text = try yaml()
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.filter { $0 == "    - >-" }.count == 2)
        #expect(!lines.contains("    - >"))
        let entries = foldedEntries(text)
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry.hasPrefix("exec:/opt/homebrew/bin/ffmpeg "))
            #expect(entry.hasSuffix("{output}#timeout=30s#killsignal=15"))
            #expect(!entry.contains("\n"))
        }
    }

    @Test("Empreinte d'une source exec: : le MD5, en hexadécimal minuscule, de la source jusqu'au premier # (go2rtc 1.9.14, internal/exec)")
    func fingerprint() {
        let source = #"exec:/opt/test/ffmpeg -f avfoundation -i "Caméra test" -f rtsp {output}"#
        #expect(Go2RTCConfig.fingerprint(ofSource: source) == "26888bab0748af45801d1790b51df185")
        #expect(Go2RTCConfig.fingerprint(ofSource: source + "#timeout=30s#killsignal=15") == "26888bab0748af45801d1790b51df185")
        #expect(Go2RTCConfig.fingerprint(ofSource: source + " -an") != "26888bab0748af45801d1790b51df185")
    }

    @Test("Les empreintes du yaml généré : une par entrée exec:, celle de l'entrée repliée telle que go2rtc la lit")
    func captureFingerprints() throws {
        let prints = try Go2RTCConfig.captureFingerprints(settings: Go2RTCFixtures.settings(), ffmpeg: Go2RTCFixtures.ffmpeg,
                                                          camera: Go2RTCFixtures.camera, microphone: Go2RTCFixtures.microphone)
        #expect(prints == foldedEntries(try yaml()).map { Go2RTCConfig.fingerprint(ofSource: $0) })
        #expect(prints.count == 2)
        #expect(Set(prints).count == 2)
        #expect(prints.allSatisfy { $0.count == 32 && $0.allSatisfy { "0123456789abcdef".contains($0) } })
        // Une autre caméra, une autre empreinte vidéo ; le micro ne change pas.
        let other = try Go2RTCConfig.captureFingerprints(settings: Go2RTCFixtures.settings(), ffmpeg: Go2RTCFixtures.ffmpeg,
                                                         camera: "Caméra test", microphone: Go2RTCFixtures.microphone)
        #expect(other[0] != prints[0])
        #expect(other[1] == prints[1])
    }

    @Test("go2rtc découpe les commandes comme prévu : chaque nom d'appareil est un seul argument")
    func quoteSplitArguments() throws {
        let entries = foldedEntries(try yaml())
        let video = try #require(quoteSplit(String(entries[0].split(separator: "#")[0])))
        let audio = try #require(quoteSplit(String(entries[1].split(separator: "#")[0])))
        #expect(video.first == "exec:/opt/homebrew/bin/ffmpeg")
        #expect(video[try #require(video.firstIndex(of: "-i")) + 1] == "OBSBOT Tiny 2 StreamCamera")
        #expect(audio[try #require(audio.firstIndex(of: "-i")) + 1] == ":OBSBOT Tiny2 Microphone")
        #expect(video.last == "{output}")
    }

    @Test("Paramètres : 720p à 25 i/s, 3 Mb/s (plafond 4500k, tampon 1500k), autres ports")
    func parameters() throws {
        var settings = Go2RTCFixtures.settings()
        settings.resolution = Go2RTCSettings.Resolution(width: 1280, height: 720)
        settings.framerate = 25
        settings.bitrate = 3
        settings.rtspPort = 9554
        settings.webrtcPort = 9555
        let text = try yaml(settings)
        #expect(text.contains("-f avfoundation -framerate 25 -video_size 1280x720 -pixel_format nv12"))
        #expect(text.contains("-c:v h264_videotoolbox -realtime 1 -g 25 -bf 0 -level 4.0"))
        #expect(text.contains("-color_range mpeg -r 25"))
        #expect(text.contains("-b:v 3M -maxrate 4500k -bufsize 1500k"))
        #expect(text.contains("  listen: \":9554\""))
        #expect(text.contains("  listen: \":9555\""))
        #expect(text.contains("  listen: \"127.0.0.1:1984\""))
    }

    @Test("Échappements : guillemets dans les noms, \" et \\ dans le mot de passe")
    func escaping() throws {
        var settings = Go2RTCFixtures.settings()
        settings.password = #"a"b\c"#
        let text = try yaml(settings, camera: #"Caméra "A""#, microphone: "Micro d'Anne")
        #expect(text.contains(#"  password: "a\"b\\c""#))
        #expect(text.contains(#"-i 'Caméra "A"'"#))
        #expect(text.contains(#"-i ":Micro d'Anne""#))
        let entries = foldedEntries(text)
        let video = try #require(quoteSplit(String(entries[0].split(separator: "#")[0])))
        let audio = try #require(quoteSplit(String(entries[1].split(separator: "#")[0])))
        #expect(video[try #require(video.firstIndex(of: "-i")) + 1] == #"Caméra "A""#)
        #expect(audio[try #require(audio.firstIndex(of: "-i")) + 1] == ":Micro d'Anne")
    }

    @Test("Refus : # ou les deux guillemets dans un nom, nom vide, saut de ligne, identifiants vides, ports invalides ou en conflit")
    func refusals() {
        let settings = Go2RTCFixtures.settings()
        #expect(throws: Go2RTCConfigError.unsupportedName("Cam #2")) { try yaml(camera: "Cam #2") }
        #expect(throws: Go2RTCConfigError.unsupportedName(#"Cam "l'autre""#)) { try yaml(camera: #"Cam "l'autre""#) }
        #expect(throws: Go2RTCConfigError.unsupportedName("")) { try yaml(camera: "") }
        #expect(throws: Go2RTCConfigError.unsupportedName("Cam\n2")) { try yaml(camera: "Cam\n2") }
        var empty = settings
        empty.password = ""
        #expect(throws: Go2RTCConfigError.missingCredential) { try yaml(empty) }
        var newline = settings
        newline.username = "pt\nzbot"
        #expect(throws: Go2RTCConfigError.unsupportedCredential) { try yaml(newline) }
        var low = settings
        low.rtspPort = 554
        #expect(throws: Go2RTCConfigError.invalidPort(554)) { try yaml(low) }
        var same = settings
        same.webrtcPort = 1984
        #expect(throws: Go2RTCConfigError.portConflict) { try yaml(same) }
    }

    @Test("Débits : 4 Mb/s donne 4M, 6M, 2M ; 5 Mb/s donne 5M, 7500k, 2500k")
    func rates() {
        var settings = Go2RTCSettings()
        #expect([settings.videoBitrate, settings.videoMaxrate, settings.videoBuffer] == ["4M", "6M", "2M"])
        settings.bitrate = 5
        #expect([settings.videoBitrate, settings.videoMaxrate, settings.videoBuffer] == ["5M", "7500k", "2500k"])
    }

    @MainActor
    @Test("Préférences : sans le mot de passe ; une clé absente reprend sa valeur par défaut")
    func preferences() throws {
        let store = FakeSettings()
        var settings = Go2RTCFixtures.settings()
        settings.cameraName = Go2RTCFixtures.camera
        settings.framerate = 25
        settings.save(to: store)
        let saved = try #require(store.strings[Go2RTCSettings.preferencesKey])
        #expect(!saved.contains(Go2RTCFixtures.password))
        var expected = settings
        expected.password = ""
        #expect(Go2RTCSettings.load(from: store) == expected)
        store.strings[Go2RTCSettings.preferencesKey] = #"{"framerate":15}"#
        var partial = Go2RTCSettings()
        partial.framerate = 15
        #expect(Go2RTCSettings.load(from: store) == partial)
        store.strings[Go2RTCSettings.preferencesKey] = "illisible"
        #expect(Go2RTCSettings.load(from: store) == Go2RTCSettings())
    }

    @Test("Mot de passe neuf : 20 lettres et chiffres, différent à chaque tirage")
    func randomPassword() {
        let first = Go2RTCSettings.randomPassword()
        #expect(first.count == 20)
        #expect(first.allSatisfy { $0.isLetter || $0.isNumber })
        #expect(first != Go2RTCSettings.randomPassword())
    }

    @Test("Écriture : mode 600 dès la création ; identique, pas réécrite et mode rétabli ; aucun fichier temporaire laissé")
    func writeFile() throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "sous-dossier/go2rtc.yaml")
        #expect(try Go2RTCConfigFile.write("un\n", to: url))
        #expect(try Go2RTCFixtures.permissions(url) == 0o600)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try !Go2RTCConfigFile.write("un\n", to: url))
        #expect(try Go2RTCFixtures.permissions(url) == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int == inode)
        #expect(try Go2RTCConfigFile.write("deux\n", to: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "deux\n")
        #expect(try Go2RTCFixtures.permissions(url) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["go2rtc.yaml"])
    }

    @Test("Messages d'erreur en français et en anglais")
    func messages() {
        let errors: [Go2RTCConfigError] = [.unsupportedName("x"), .missingCredential, .unsupportedCredential, .invalidPort(1), .portConflict]
        for error in errors {
            let french = Localization.$languageOverride.withValue("fr") { error.localizedDescription }
            let english = Localization.$languageOverride.withValue("en") { error.localizedDescription }
            #expect(french != english, "\(error)")
        }
        #expect(Go2RTCConfigError.invalidPort(80).localizedDescription == "Port 80 invalide : choisissez un port entre 1024 et 65535.")
    }
}
