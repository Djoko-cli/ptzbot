import Foundation
import NacelleProtocol
import Testing
@testable import PTZBotKit

/// Les textes de PTZBotKit en français et en anglais (spec distribution § 7).
@Suite("Textes bilingues", .french)
struct LocalizationTests {
    /// Le texte dans une langue donnée.
    private func inLanguage<T>(_ language: String, _ body: () -> T) -> T {
        Localization.$languageOverride.withValue(language, operation: body)
    }

    /// Le catalogue source, lu dans les sources du paquet.
    private func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/PTZBotKit/Resources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(object?["sourceLanguage"] as? String == "fr")
        return try #require(object?["strings"] as? [String: Any])
    }

    @Test("Catalogue : chaque clé a sa traduction anglaise, non vide et marquée traduite")
    func everyKeyTranslated() throws {
        let strings = try catalog()
        #expect(strings.count > 100)
        for (key, value) in strings {
            let entry = value as? [String: Any]
            let english = (entry?["localizations"] as? [String: Any])?["en"] as? [String: Any]
            let unit = english?["stringUnit"] as? [String: Any]
            #expect(unit?["state"] as? String == "translated", "\(key)")
            #expect((unit?["value"] as? String)?.isEmpty == false, "\(key)")
        }
    }

    @Test("Catalogue compilé : chaque clé se lit en anglais dans en.lproj et en français dans fr.lproj")
    func compiledCatalog() throws {
        let strings = try catalog()
        let english = Localization.bundle(for: "en")
        let french = Localization.bundle(for: "fr")
        #expect(english.bundlePath.hasSuffix("en.lproj"))
        #expect(french.bundlePath.hasSuffix("fr.lproj"))
        for (key, value) in strings {
            let localizations = (value as? [String: Any])?["localizations"] as? [String: Any]
            let expected = ((localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            #expect(english.localizedString(forKey: key, value: "∅", table: nil) == expected, "\(key)")
            #expect(french.localizedString(forKey: key, value: "∅", table: nil) == key, "\(key)")
        }
    }

    @Test("Langue : le français si l'utilisateur le préfère, l'anglais pour toute autre langue")
    func preferredLanguage() {
        #expect(Localization.preferredLanguage(["fr-FR"]) == "fr")
        #expect(Localization.preferredLanguage(["fr-CA", "en"]) == "fr")
        #expect(Localization.preferredLanguage(["de-DE", "fr-FR"]) == "fr")
        #expect(Localization.preferredLanguage(["de-DE"]) == "en")
        #expect(Localization.preferredLanguage(["en-GB", "fr-FR"]) == "en")
        #expect(Localization.preferredLanguage([]) == "en")
        // Le repli sur l'anglais est explicite : aucune langue connue, ou l'anglais en premier.
        #expect(Localization.preferredLanguage(["es-ES"]) == "en")
        #expect(Localization.preferredLanguage(["en-US", "fr-FR"]) == "en")
        #expect(Localization.preferredLanguage(["es-ES", "de-DE"]) == "en")
        #expect(Localization.preferredLanguage(["zh-Hans-CN", "fr"]) == "fr")
    }

    @Test("Erreurs de ptzd : chaque code a un texte en français et en anglais, différents")
    func everyErrorCode() {
        #expect(ErrorCode.allCases.count == 11)
        for code in ErrorCode.allCases {
            let french = inLanguage("fr") { ErrorTexts.text(for: code, message: "message de ptzd") }
            let english = inLanguage("en") { ErrorTexts.text(for: code, message: "message de ptzd") }
            #expect(!french.isEmpty, "\(code)")
            #expect(!english.isEmpty, "\(code)")
            #expect(french != english, "\(code)")
            #expect(french != "message de ptzd", "le texte de ptzd n'est jamais repris : \(code)")
        }
        #expect(inLanguage("fr") { ErrorTexts.text(for: .cameraAbsent, message: "") } == "Caméra débranchée.")
        #expect(inLanguage("en") { ErrorTexts.text(for: .cameraAbsent, message: "") } == "Camera unplugged.")
        #expect(inLanguage("en") { ErrorTexts.text(for: .pairingClosed, message: "") } == "QR code expired or already used: start pairing again on the Mac.")
    }

    @Test("uvcFailed du suivi IA : le motif connu de ptzd est traduit ; sinon le refus de la caméra")
    func aiMotives() {
        let cases: [(String, String, String)] = [
            ("Suivi IA non modifié (caméra introuvable).", "Suivi IA non modifié : caméra introuvable.", "AI tracking unchanged: camera not found."),
            ("Suivi IA non modifié (erreur du SDK OBSBOT).", "Suivi IA non modifié : erreur du SDK OBSBOT.", "AI tracking unchanged: OBSBOT SDK error."),
            ("Suivi IA non modifié (délai dépassé).", "Suivi IA non modifié : délai dépassé.", "AI tracking unchanged: timed out."),
            ("Suivi IA non modifié (l'utilitaire n'a pas pu être lancé).", "Suivi IA non modifié : obsbot-ai n'a pas pu être lancé.", "AI tracking unchanged: obsbot-ai could not be started."),
            ("Suivi IA non modifié (l'utilitaire s'est arrêté avec le code 134).", "Suivi IA non modifié : obsbot-ai s'est arrêté avec le code 134.", "AI tracking unchanged: obsbot-ai stopped with code 134."),
            ("Suivi IA non modifié (motif nouveau).", "Suivi IA non modifié.", "AI tracking unchanged."),
            ("La caméra a refusé la commande (timeout).", "La caméra a refusé la commande.", "The camera refused the command."),
        ]
        for (message, french, english) in cases {
            #expect(inLanguage("fr") { ErrorTexts.text(for: .uvcFailed, message: message) } == french)
            #expect(inLanguage("en") { ErrorTexts.text(for: .uvcFailed, message: message) } == english)
        }
    }

    @Test("Motifs du suivi IA : ceux que ptzd compose (AIFailureText, partagé), traduits ; jamais le texte de ptzd")
    func aiMotivesShared() {
        let motives = [AIFailureText.cameraNotFound, AIFailureText.sdkError, AIFailureText.timeout,
                       AIFailureText.launchFailed, AIFailureText.unexpectedExitPrefix + "7"]
        let french = motives.map { motive in inLanguage("fr") { ErrorTexts.text(for: .uvcFailed, message: AIFailureText.message(motive: motive)) } }
        #expect(french == [
            "Suivi IA non modifié : caméra introuvable.",
            "Suivi IA non modifié : erreur du SDK OBSBOT.",
            "Suivi IA non modifié : délai dépassé.",
            "Suivi IA non modifié : obsbot-ai n'a pas pu être lancé.",
            "Suivi IA non modifié : obsbot-ai s'est arrêté avec le code 7.",
        ])
        let english = motives.map { motive in inLanguage("en") { ErrorTexts.text(for: .uvcFailed, message: AIFailureText.message(motive: motive)) } }
        #expect(Set(english).count == motives.count)
        #expect(english.allSatisfy { $0.hasPrefix("AI tracking unchanged: ") })
    }

    @Test("Vie privée native : sous-titre, notes du mode tilt et messages d'échec de ptzd, en français et en anglais")
    func privacyTexts() {
        #expect(inLanguage("fr") { Labels.privacySubtitle } == "Coupe l'image et le micro de la caméra")
        #expect(inLanguage("en") { Labels.privacySubtitle } == "Turns off the camera's image and microphone")
        // Seul le mode tilt a une note ; natif, ptzd ancien et hors vie privée n'en ont pas.
        #expect(Labels.privacyNote(.native, needsSDK: false) == nil)
        #expect(Labels.privacyNote(nil, needsSDK: true) == nil)
        #expect(inLanguage("fr") { Labels.privacyNote(.tilt, needsSDK: true) } == "Sans le SDK OBSBOT, la vie privée détourne seulement l'objectif : l'image et le micro ne sont pas coupés.")
        #expect(inLanguage("en") { Labels.privacyNote(.tilt, needsSDK: true) } == "Without the OBSBOT SDK, privacy only turns the lens away: the image and microphone are not turned off.")
        // SDK installé mais mode natif échoué : la note du repli, pas « sans le SDK ».
        #expect(inLanguage("fr") { Labels.privacyNote(.tilt, needsSDK: false) } == PrivacyFailureText.fallbackToTilt)
        #expect(inLanguage("en") { Labels.privacyNote(.tilt, needsSDK: false) } == "Privacy could not turn off the camera's image or microphone: the lens is only turned away.")
        // Les deux messages que ptzd envoie en uvcFailed sont traduits ; jamais le texte de ptzd en anglais.
        #expect(inLanguage("fr") { ErrorTexts.text(for: .uvcFailed, message: PrivacyFailureText.fallbackToTilt) } == PrivacyFailureText.fallbackToTilt)
        #expect(inLanguage("en") { ErrorTexts.text(for: .uvcFailed, message: PrivacyFailureText.fallbackToTilt) } == "Privacy could not turn off the camera's image or microphone: the lens is only turned away.")
        #expect(inLanguage("fr") { ErrorTexts.text(for: .uvcFailed, message: PrivacyFailureText.exitFailed) } == PrivacyFailureText.exitFailed)
        #expect(inLanguage("en") { ErrorTexts.text(for: .uvcFailed, message: PrivacyFailureText.exitFailed) } == "Privacy could not be turned off: the camera did not respond.")
    }

    /// Les clés de `Localization.text("…")` dans les sources de PTZBotKit, chaque interpolation devenue `%lld`
    /// (pour `count`) ou `%@`.
    static func sourceKeys() throws -> Set<String> {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/PTZBotKit")
        var keys = Set<String>()
        for name in try FileManager.default.contentsOfDirectory(atPath: sources.path) where name.hasSuffix(".swift") {
            let text = Array(try String(contentsOf: sources.appending(path: name), encoding: .utf8))
            let marker = Array("Localization.text(\"")
            var index = 0
            while index + marker.count <= text.count {
                guard Array(text[index..<index + marker.count]) == marker else {
                    index += 1
                    continue
                }
                var position = index + marker.count
                var key = ""
                while text[position] != "\"" {
                    if text[position] == "\\", text[position + 1] == "(" {
                        // Interpolation : jusqu'à la parenthèse fermante, chaînes imbriquées comprises.
                        var depth = 1
                        var cursor = position + 2
                        var expression = ""
                        while depth > 0 {
                            let character = text[cursor]
                            if character == "\"" {
                                let end = text[(cursor + 1)...].firstIndex(of: "\"")!
                                expression += String(text[cursor...end])
                                cursor = end + 1
                                continue
                            }
                            if character == "(" { depth += 1 }
                            if character == ")" { depth -= 1 }
                            if depth > 0 { expression.append(character) }
                            cursor += 1
                        }
                        key += expression == "count" ? "%lld" : "%@"
                        position = cursor
                    } else if text[position] == "\\" {
                        key.append(text[position + 1] == "n" ? "\n" : text[position + 1])
                        position += 2
                    } else {
                        key.append(text[position])
                        position += 1
                    }
                }
                keys.insert(key)
                index = position + 1
            }
        }
        return keys
    }

    @Test("Chaque texte de PTZBotKit (Localization.text) est dans le catalogue, et le catalogue n'a pas de clé inutile")
    func everySourceKeyInCatalog() throws {
        let keys = try Self.sourceKeys()
        let catalogKeys = Set(try catalog().keys)
        #expect(keys.count > 100)
        #expect(keys.subtracting(catalogKeys).sorted() == [])
        #expect(catalogKeys.subtracting(keys).sorted() == [])
    }

    @Test("Libellés en anglais : états, sections, interpolations, raisons du superviseur, messages du SDK")
    func englishLabels() {
        inLanguage("en") {
            #expect(Labels.sdk(.ready) == "Ready")
            #expect(Labels.sdk(.incomplete) == "Incomplete")
            #expect(Labels.sdk(.toolsRequired(fallback: false)) == "Tools required")
            #expect(Labels.sdk(.compileFailed(fallback: false)) == "Compile failed")
            #expect(Labels.sdk(.sourceMissing) == "obsbot-ai not found")
            #expect(Labels.sdkDetail(.incomplete, toolsAvailable: false) == "Reinstall the SDK from its archive or folder: its headers are missing. Install Apple's developer tools first.")
            #expect(Labels.sdkDetail(.toolsRequired(fallback: true)) == "Apple's developer tools are needed to compile obsbot-ai. The previous obsbot-ai stays in use.")
            #expect(Labels.sdkDetail(.quarantined) == "The SDK does not load: reinstall it to remove the quarantine from its copy.")
            #expect(Labels.sdk(.recompiling) == "Recompiling…")
            #expect(Labels.sdkAction(.toolsRequired(fallback: false)) == "Install Developer Tools…")
            #expect(Labels.service(.restarting(count: 3), connection: .unreachable, legacy: false) == "Restarted after an unexpected stop (3)")
            #expect(Labels.iPhoneSection(count: 2) == "Connected iPhones · 2")
            #expect(Labels.cameraSection(.connected) == "Camera · plugged in")
            #expect(Labels.route(.mac) == "This Mac")
            #expect(Labels.sdkDetail(.compileFailed(fallback: true)) == "The previous obsbot-ai stays in use. Details are in the obsbot-ai-compilation.log log.")
            #expect(ServiceSupervisor.busyReason(port: 1985) == "Port 1985 is already in use: another ptzd may still be running")
            #expect(ServiceSupervisor.crashLoopReason == "ptzd keeps stopping: open the log")
            #expect(SDKRejection.noArm64(architectures: ["x86_64"]).message == "This SDK has no Apple silicon version (x86_64).")
            #expect(SDKInstallError.copyFailed("x").message == "The SDK could not be copied: x")
            #expect(LegacyMigrationError.stillLoaded.message == "The previous installation did not stop in time.")
            let candidate = SDKCandidate(
                path: URL(fileURLWithPath: "/x/libdev.dylib"),
                architectures: ["x86_64"],
                signer: "Developer ID Application: Exemple",
                team: "ABCDE12345",
                origin: SDKOrigin(url: "https://example.com/libdev.zip", date: nil, fromInsideArchive: true),
                signatureValid: true,
                appleAnchored: true
            )
            #expect(Labels.sdkChecks(candidate).map(\.title) == ["Architecture", "Signature", "Origin", "Quarantine"])
            #expect(Labels.sdkChecks(candidate).map(\.value) == [
                "Apple Silicon: ✗ (x86_64)",
                "Developer ID Application: Exemple (team ABCDE12345)",
                "https://example.com/libdev.zip (stated in the archive)",
                "no",
            ])
        }
    }

    @Test("Libellés : français et anglais diffèrent pour chaque texte du panneau qui se traduit")
    func everyLabelTranslated() {
        let labels: [() -> String] = [
            { Labels.service(.connecting) }, { Labels.service(.active) }, { Labels.service(.unreachable) },
            { Labels.route(.localNetwork) }, { Labels.route(.mac) },
            { Labels.service(.stopped, connection: .unreachable, legacy: true) },
            { Labels.service(.stopped, connection: .unreachable, legacy: false) },
            { Labels.sdk(nil) }, { Labels.sdk(.ready) }, { Labels.sdk(.absent) }, { Labels.sdk(.quarantined) },
            { Labels.sdk(.unloadable) }, { Labels.sdk(.sourceMissing) }, { Labels.sdk(.compileFailed(fallback: false)) },
            { Labels.sdk(.incomplete) }, { Labels.sdk(.toolsRequired(fallback: false)) },
            { Labels.sdkDetail(.incomplete) ?? "" }, { Labels.sdkDetail(.unloadable) ?? "" },
            { Labels.sdkDetail(.sourceMissing) ?? "" }, { Labels.sdkDetail(.absent, toolsAvailable: false) ?? "" },
            { Labels.sdkAction(.ready) ?? "" }, { Labels.sdkAction(.absent) ?? "" },
            { Labels.replaceLegacy }, { Labels.noIPhone }, { Labels.cameraSection(nil) },
            { Labels.aiNote(.unknown, needsSDK: false) ?? "" }, { Labels.sdkRequired }, { Labels.tailscaleMissing },
            { Labels.localNetworkDenied }, { Labels.migrationMessage }, { Labels.migrationReplace },
            { Labels.migrationLater }, { Labels.sdkExplanation }, { Labels.sdkConfirmation },
            { ServiceSupervisor.unkillableReason }, { ServiceSupervisor.configReason }, { ServiceSupervisor.usageReason },
            { SDKInstallError.toolsMissing.message }, { SDKInstallError.compileFailed.message }, { SDKRejection.headersMissing.message },
        ]
        for label in labels {
            let french = inLanguage("fr", label)
            let english = inLanguage("en", label)
            #expect(french != english, "\(french)")
        }
    }
}
