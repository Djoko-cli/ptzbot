import Foundation
import Testing
@testable import GardienCore

@Suite("Options du gardien")
struct GardienOptionsTests {
    @Test("--parent et --arret dans n'importe quel ordre, puis -- et le programme avec ses arguments")
    func valid() throws {
        let options = try GardienOptions.parse(["--parent", "4242", "--arret", "10", "--", "/app/Helpers/go2rtc", "-config", "/support/go2rtc.yaml"])
        #expect(options == GardienOptions(parent: 4242, stopDelay: 10, program: "/app/Helpers/go2rtc", arguments: ["-config", "/support/go2rtc.yaml"]))
        let reordered = try GardienOptions.parse(["--arret", "0.5", "--parent", "7", "--", "/bin/sleep"])
        #expect(reordered == GardienOptions(parent: 7, stopDelay: 0.5, program: "/bin/sleep", arguments: []))
    }

    @Test("Après --, tout est au programme, même ce qui ressemble à une option")
    func passThrough() throws {
        let options = try GardienOptions.parse(["--parent", "1", "--arret", "1", "--", "/bin/echo", "--parent", "--", "-config"])
        #expect(options.arguments == ["--parent", "--", "-config"])
    }

    @Test("Refus : option inconnue, valeur manquante ou mal formée, option en double ou manquante, programme manquant ou relatif")
    func invalid() {
        #expect(throws: GardienOptions.ParseError.unknownOption("--verbose")) { try GardienOptions.parse(["--verbose"]) }
        #expect(throws: GardienOptions.ParseError.missingValue("--parent")) { try GardienOptions.parse(["--parent"]) }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--parent", value: "abc")) {
            try GardienOptions.parse(["--parent", "abc", "--arret", "1", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--parent", value: "0")) {
            try GardienOptions.parse(["--parent", "0", "--arret", "1", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--arret", value: "-1")) {
            try GardienOptions.parse(["--parent", "1", "--arret", "-1", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--arret", value: "nan")) {
            try GardienOptions.parse(["--parent", "1", "--arret", "nan", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--arret", value: "301")) {
            try GardienOptions.parse(["--parent", "1", "--arret", "301", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.duplicate("--parent")) {
            try GardienOptions.parse(["--parent", "1", "--parent", "2", "--arret", "1", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.missingOption("--arret")) { try GardienOptions.parse(["--parent", "1", "--", "/bin/sleep"]) }
        #expect(throws: GardienOptions.ParseError.missingOption("--parent")) { try GardienOptions.parse(["--arret", "1", "--", "/bin/sleep"]) }
        #expect(throws: GardienOptions.ParseError.missingProgram) { try GardienOptions.parse(["--parent", "1", "--arret", "1", "--"]) }
        #expect(throws: GardienOptions.ParseError.missingProgram) { try GardienOptions.parse(["--parent", "1", "--arret", "1"]) }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--", value: "go2rtc")) {
            try GardienOptions.parse(["--parent", "1", "--arret", "1", "--", "go2rtc"])
        }
    }
}

@Suite("Options du ménage")
struct SweepOptionsTests {
    static let first = "0123456789abcdef0123456789abcdef"
    static let second = "fedcba9876543210fedcba9876543210"

    @Test("Sans --rtsp : pas de ménage ; les délais du ménage par défaut : 60 s, 180 s, 1 s")
    func defaults() throws {
        let options = try GardienOptions.parse(["--parent", "1", "--arret", "1", "--", "/bin/sleep"])
        #expect(options.rtspPort == nil)
        #expect(options.captures.isEmpty)
        #expect(options.sweepTiming == SweepTiming(period: 60, minimumAge: 180, signalInterval: 1))
        #expect(SweepTiming.standard == options.sweepTiming)
    }

    @Test("--rtsp une fois, --capture répétable (doublons ignorés), --delais-menage pour les tests, avant --")
    func valid() throws {
        let options = try GardienOptions.parse([
            "--rtsp", "18554", "--parent", "7", "--capture", Self.first, "--arret", "10", "--capture", Self.second,
            "--capture", Self.first, "--delais-menage", "0.5,2,0.25", "--", "/bin/sleep", "--rtsp", "1",
        ])
        #expect(options.rtspPort == 18554)
        #expect(options.captures == [Self.first, Self.second])
        #expect(options.sweepTiming == SweepTiming(period: 0.5, minimumAge: 2, signalInterval: 0.25))
        #expect(options.arguments == ["--rtsp", "1"])
        let portOnly = try GardienOptions.parse(["--parent", "7", "--arret", "10", "--rtsp", "1024", "--", "/bin/sleep"])
        #expect(portOnly.rtspPort == 1024)
        #expect(portOnly.captures.isEmpty)
    }

    @Test("Refus : port hors de 1…65535 ou en double, empreinte qui n'est pas un MD5 en minuscules, --capture sans --rtsp, délais mal formés")
    func invalid() {
        let tail = ["--parent", "1", "--arret", "1", "--", "/bin/sleep"]
        for port in ["0", "65536", "-1", "abc", "8554.5", ""] {
            #expect(throws: GardienOptions.ParseError.invalidValue(option: "--rtsp", value: port)) {
                try GardienOptions.parse(["--rtsp", port] + tail)
            }
        }
        #expect(throws: GardienOptions.ParseError.duplicate("--rtsp")) {
            try GardienOptions.parse(["--rtsp", "18554", "--rtsp", "18555"] + tail)
        }
        #expect(throws: GardienOptions.ParseError.duplicate("--rtsp")) {
            try GardienOptions.parse(["--rtsp", "18554", "--rtsp", "18554"] + tail)
        }
        for print in ["", "0123", Self.first.uppercased(), Self.first + "0", String(Self.first.dropLast()) + "g", "rtsp://127.0.0.1:1/x"] {
            #expect(throws: GardienOptions.ParseError.invalidValue(option: "--capture", value: print)) {
                try GardienOptions.parse(["--rtsp", "18554", "--capture", print] + tail)
            }
        }
        #expect(throws: GardienOptions.ParseError.missingOption("--rtsp")) {
            try GardienOptions.parse(["--capture", Self.first] + tail)
        }
        #expect(throws: GardienOptions.ParseError.missingValue("--capture")) { try GardienOptions.parse(["--capture"]) }
        #expect(throws: GardienOptions.ParseError.missingValue("--rtsp")) { try GardienOptions.parse(["--rtsp"]) }
        for timing in ["1,2", "1,2,3,4", "0,2,1", "1,-2,1", "1,2,nan", "a,b,c", "1,2,3601", ""] {
            #expect(throws: GardienOptions.ParseError.invalidValue(option: "--delais-menage", value: timing)) {
                try GardienOptions.parse(["--delais-menage", timing] + tail)
            }
        }
        #expect(throws: GardienOptions.ParseError.duplicate("--delais-menage")) {
            try GardienOptions.parse(["--delais-menage", "1,2,3", "--delais-menage", "1,2,3"] + tail)
        }
    }
}

@Suite("Fin du programme")
struct ChildEndTests {
    @Test("Statut de waitpid : sortie normale avec son code, ou signal (core écrit ou non)")
    func decode() {
        #expect(ChildEnd(waitStatus: 0) == .exited(0))
        #expect(ChildEnd(waitStatus: 7 << 8) == .exited(7))
        #expect(ChildEnd(waitStatus: SIGTERM) == .signaled(SIGTERM))
        #expect(ChildEnd(waitStatus: SIGKILL) == .signaled(SIGKILL))
        #expect(ChildEnd(waitStatus: SIGSEGV | 0x80) == .signaled(SIGSEGV))
    }
}
