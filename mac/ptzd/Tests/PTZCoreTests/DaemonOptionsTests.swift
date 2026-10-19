import Foundation
import Testing
@testable import PTZCore

@Suite("Options du service (--parent, --ai, --sdk)")
struct DaemonOptionsTests {
    @Test("--ai : l'utilitaire est gardé chaud ; sans --ai (ligne de commande), il s'arrête après son délai d'inactivité")
    func keepsAIWarm() throws {
        #expect(try DaemonOptions.parse(["--ai", "/app/Helpers/obsbot-ai"]).keepsAIWarm)
        #expect(try !DaemonOptions.parse(["--parent", "4242"]).keepsAIWarm)
        #expect(!DaemonOptions().keepsAIWarm)
    }

    @Test("Sans option : fonctionnement en ligne de commande inchangé")
    func absent() throws {
        let options = try DaemonOptions.parse([])
        #expect(options == DaemonOptions())
        #expect(options.aiEnvironment.isEmpty)
        let config = PTZConfig(listenAddress: "127.0.0.1")
        let base = URL(fileURLWithPath: "/support")
        #expect(options.aiURL(config: config, relativeTo: base).path == "/support/bin/obsbot-ai")
    }

    @Test("Les trois options, dans n'importe quel ordre")
    func valid() throws {
        let options = try DaemonOptions.parse(["--sdk", "/sdk", "--parent", "4242", "--ai", "/app/Helpers/obsbot-ai"])
        #expect(options == DaemonOptions(parent: 4242, aiPath: "/app/Helpers/obsbot-ai", sdkDirectory: "/sdk"))
        #expect(options.aiEnvironment == ["DYLD_LIBRARY_PATH": "/sdk"])
        let config = PTZConfig(listenAddress: "127.0.0.1", aiPath: "/ailleurs/obsbot-ai")
        #expect(options.aiURL(config: config, relativeTo: URL(fileURLWithPath: "/support")).path == "/app/Helpers/obsbot-ai")
    }

    @Test("Option inconnue, valeur manquante, mal formée ou en double : refusées")
    func invalid() {
        #expect(throws: DaemonOptions.ParseError.unknownOption("--verbose")) { try DaemonOptions.parse(["--verbose"]) }
        #expect(throws: DaemonOptions.ParseError.unknownOption("devicez")) { try DaemonOptions.parse(["devicez"]) }
        #expect(throws: DaemonOptions.ParseError.missingValue("--parent")) { try DaemonOptions.parse(["--parent"]) }
        #expect(throws: DaemonOptions.ParseError.invalidValue(option: "--parent", value: "abc")) {
            try DaemonOptions.parse(["--parent", "abc"])
        }
        #expect(throws: DaemonOptions.ParseError.invalidValue(option: "--parent", value: "0")) {
            try DaemonOptions.parse(["--parent", "0"])
        }
        #expect(throws: DaemonOptions.ParseError.invalidValue(option: "--parent", value: "-3")) {
            try DaemonOptions.parse(["--parent", "-3"])
        }
        #expect(throws: DaemonOptions.ParseError.invalidValue(option: "--ai", value: "bin/obsbot-ai")) {
            try DaemonOptions.parse(["--ai", "bin/obsbot-ai"])
        }
        #expect(throws: DaemonOptions.ParseError.invalidValue(option: "--sdk", value: "")) {
            try DaemonOptions.parse(["--sdk", ""])
        }
        #expect(throws: DaemonOptions.ParseError.duplicate("--ai")) {
            try DaemonOptions.parse(["--ai", "/a", "--ai", "/b"])
        }
    }

    @Test("Usage et code de sortie 64")
    func usage() {
        #expect(DaemonOptions.usageStatus == 64)
        #expect(DaemonOptions.usage.hasPrefix("usage : ptzd [--parent <pid>]"))
        #expect("\(DaemonOptions.ParseError.missingValue("--sdk"))" == "valeur manquante après --sdk")
    }
}
