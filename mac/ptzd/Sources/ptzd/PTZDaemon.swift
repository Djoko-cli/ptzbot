import Foundation
import os
import PTZAuth
import PTZCore
import PTZServer
import UVCCamera

@main
struct PTZDaemon {
    /// Dossier de travail (spec § 6.7). PTZD_SUPPORT_DIR le remplace pour les essais.
    static let supportDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["PTZD_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ObsbotNacelle")
    }()

    /// Journaux (spec § 6.7) ; sous PTZD_SUPPORT_DIR pendant les essais.
    static let logsDirectory: URL = {
        if ProcessInfo.processInfo.environment["PTZD_SUPPORT_DIR"] != nil {
            return supportDirectory.appending(path: "logs")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/obsbot-nacelle")
    }()
    /// Dossier de talkd (réglages et état), qui est le même que celui de ptzd en service ; TALKD_SUPPORT_DIR le
    /// remplace pour les essais, comme pour talkd (spec parler § 5).
    static let talkSupportDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["TALKD_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return supportDirectory
    }()
    static let logger = Logger(subsystem: "io.github.djoko-cli.obsbot-nacelle", category: "ptzd")

    /// Une ligne dans le journal système et sur la sortie standard (redirigée par launchd).
    nonisolated static func write(_ line: String) {
        logger.log("\(line, privacy: .public)")
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    @MainActor
    static func main() {
        let log: LogSink = { write($0) }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "uvc" {
            exit(UVCDebugCommand.run(Array(arguments.dropFirst()), log: log))
        }
        if let command = arguments.first, AuthCommand.names.contains(command) {
            let result = AuthCommand.run(arguments, authority: DeviceAuthority(directory: supportDirectory))
            print(result.output)
            exit(result.status)
        }

        // Mode service (la commande par défaut) : options données par PTZBot (spec ptzd dans l'app § 5.4).
        let options: DaemonOptions
        if arguments.first == "pair" {
            options = DaemonOptions()
        } else {
            do {
                options = try DaemonOptions.parse(arguments)
            } catch {
                FileHandle.standardError.write(Data("ptzd : \(error)\n\(DaemonOptions.usage)\n".utf8))
                exit(DaemonOptions.usageStatus)
            }
        }
        // PTZBot disparu, même tué par SIGKILL : ptzd s'arrête avec lui ; déjà disparu : tout de suite.
        // Un parent qui n'est pas le nôtre (PID déjà réattribué) compte comme disparu.
        if let parent = options.parent, getppid() != parent {
            log("PTZBot s'est arrêté : ptzd s'arrête.")
            exit(0)
        }
        let parentWatcher = options.parent.map { pid in
            ParentWatcher(pid: pid) {
                log("PTZBot s'est arrêté : ptzd s'arrête.")
                exit(0)
            }
        }
        parentWatcher?.start()

        // Un seul service par dossier de travail : un autre ptzd tient le verrou, celui-ci s'arrête.
        var serviceLock: ServiceLock?
        if arguments.first != "pair" {
            do {
                serviceLock = try ServiceLock.acquire(at: supportDirectory.appending(path: "ptzd.lock"))
            } catch .held {
                log("Un autre ptzd tourne déjà (verrou ptzd.lock) : ptzd s'arrête.")
                exit(DaemonOptions.busyStatus)
            } catch {
                log("Verrou ptzd.lock indisponible (\(error)) : ptzd continue sans.")
            }
        }

        let config: PTZConfig
        do {
            config = try PTZConfig.load(from: supportDirectory.appending(path: "config.json"))
        } catch {
            log("config.json absent ou invalide : \(error)")
            exit(78)
        }
        if arguments.first == "pair" {
            guard arguments.count == 1 else {
                print("usage : ptzd pair    affiche le QR code d'un appairage valable 5 min")
                exit(2)
            }
            Task {
                let result = await PairCommand.run(port: config.port)
                print(result.output)
                exit(result.status)
            }
            dispatchMain()
        }

        let scheduler = DispatchScheduler()
        let camera = UVCCamera(log: log)
        let controller = PTZController(
            camera: camera,
            scheduler: scheduler,
            ai: ResidentAIRunner(
                executableURL: options.aiURL(config: config, relativeTo: supportDirectory),
                outputURL: logsDirectory.appending(path: "obsbot-ai.log"),
                environment: options.aiEnvironment,
                scheduler: scheduler,
                // Lancé avec le SDK (`--ai`) : l'utilitaire reste chargé tant que ptzd tourne (spec § 6.9).
                keepWarm: options.keepsAIWarm,
                log: log
            ),
            store: JSONFileStateStore(url: supportDirectory.appending(path: "state.json"), log: { write($0) }),
            settings: config.motion,
            isObsbotCenterRunning: { ObsbotCenterDetector.isRunning() },
            log: log
        )
        camera.onPresenceChange = { controller.cameraPresenceChanged($0) }
        guard let relay = Go2rtcRelay(api: config.go2rtcAPI, stream: config.streamName) else {
            log("go2rtcAPI invalide : \(config.go2rtcAPI)")
            exit(78)
        }
        // 127.0.0.1 en plus de l'adresse Tailscale : le Mac ne peut pas se joindre
        // lui-même par Tailscale, et les diagnostics locaux en ont besoin.
        // La voix des iPhone part en UDP vers talkd, sur 127.0.0.1 ; le port est lu une fois, ici.
        let talkPort = TalkPort.load(from: talkSupportDirectory.appending(path: "talkd.json"))
        let voiceSink = UDPVoiceSink(port: UInt16(talkPort))
        let server = WebSocketServer(
            hosts: [config.listenAddress, "127.0.0.1"],
            port: UInt16(config.port),
            controller: controller,
            authority: DeviceAuthority(directory: supportDirectory),
            relay: relay,
            scheduler: scheduler,
            log: log,
            localNetwork: config.localNetwork,
            voiceSink: voiceSink
        )
        // « Talkback prêt » : relu dans talkd-state.json dès que le fichier change, et toutes les 5 s en secours ;
        // diffusé aux changements.
        let talkStateURL = talkSupportDirectory.appending(path: "talkd-state.json")
        let talkbackWatcher = TalkbackWatcher(
            scheduler: scheduler,
            read: { TalkbackProbe.availability(stateFileAt: talkStateURL) },
            onChange: { controller.setTalkback($0) },
            observer: DispatchFileChangeObserver(url: talkStateURL)
        )

        if options.parent != nil {
            // Lancé par PTZBot : un port de 127.0.0.1 déjà pris veut dire qu'un autre ptzd tourne encore.
            server.onAddressInUse = { host in
                guard host == "127.0.0.1" else { return }
                log("Le port \(config.port) est déjà pris : un autre ptzd tourne peut-être encore. ptzd s'arrête.")
                exit(DaemonOptions.busyStatus)
            }
        }

        // Sortie de veille du Mac : la caméra a pu être réveillée pendant ce temps (vie privée native, spec § 6.5 bis).
        let wakeWatcher = SystemWakeWatcher { controller.systemWoke() }

        log("ptzd démarre.")
        camera.startWatching()
        if !camera.isAttached {
            // Une caméra absente au démarrage, puis branchée, sort d'une mise sous tension (pas du mode natif de PTZBot).
            controller.cameraAbsentAtStartup()
        }
        server.start()
        talkbackWatcher.start()
        wakeWatcher.start()
        withExtendedLifetime((camera, controller, server, parentWatcher, serviceLock, voiceSink, talkbackWatcher, wakeWatcher)) {
            dispatchMain()
        }
    }
}
