import Foundation

/// Échec d'une compilation d'obsbot-ai.
public enum ToolchainError: Error, Equatable, Sendable {
    /// `xcode-select -p` échoue : les outils de développement d'Apple ne sont pas installés.
    case unavailable
    /// clang++ a échoué (ou dépassé son délai) ; sa sortie, pour le journal.
    case compileFailed(output: String)
}

/// Les outils de développement d'Apple (spec distribution § 6.1), derrière un protocole pour les tests.
/// Bloquant (processus lancés et attendus) : à appeler hors du fil principal.
public protocol Toolchain: Sendable {
    /// `xcode-select -p` réussit.
    func isAvailable() -> Bool
    /// `clang++ -std=c++17 -O2 -arch arm64 -I <include> -L <bibliothèque> -ldev -o <sortie> <source>`. Le binaire n'a pas de
    /// chemin de recherche intégré : ptzd lui donne `DYLD_LIBRARY_PATH`. L'éditeur de liens le signe en local.
    func compile(source: URL, includeDirectory: URL, libraryDirectory: URL, output: URL) throws(ToolchainError)
    /// Lance `xcode-select --install` sans l'attendre : l'utilisateur accepte lui-même dans la fenêtre d'Apple.
    func requestInstall()
}

/// Les vrais outils : `xcode-select` et `xcrun clang++`.
public struct SystemToolchain: Toolchain {
    public let xcodeSelect: URL
    public let xcrun: URL
    /// Délai maximal d'une compilation ; au-delà, clang++ est arrêté et la compilation échoue.
    public let timeout: TimeInterval

    public init(xcodeSelect: URL, xcrun: URL, timeout: TimeInterval) {
        self.xcodeSelect = xcodeSelect
        self.xcrun = xcrun
        self.timeout = timeout
    }

    /// Les outils du système, à leur place habituelle.
    public static func system() -> SystemToolchain {
        SystemToolchain(
            xcodeSelect: URL(fileURLWithPath: "/usr/bin/xcode-select"),
            xcrun: URL(fileURLWithPath: "/usr/bin/xcrun"),
            timeout: 300
        )
    }

    public func isAvailable() -> Bool {
        let result = ChildProcess.run(xcodeSelect, arguments: ["-p"], timeout: 10)
        return result?.exited == true && result?.status == 0
    }

    public func compile(source: URL, includeDirectory: URL, libraryDirectory: URL, output: URL) throws(ToolchainError) {
        // Sans outils, xcrun ouvrirait de lui-même la fenêtre d'installation d'Apple : la vérification passe avant.
        guard isAvailable() else { throw .unavailable }
        let arguments = [
            "clang++", "-std=c++17", "-O2", "-arch", "arm64",
            "-I", includeDirectory.path,
            "-L", libraryDirectory.path, "-ldev",
            "-o", output.path, source.path,
        ]
        guard let result = ChildProcess.run(xcrun, arguments: arguments, timeout: timeout, captureOutput: true) else {
            throw .compileFailed(output: "clang++ n'a pas pu être lancé.")
        }
        guard result.exited, result.status == 0 else {
            let reason = result.timedOut ? "clang++ n'a pas fini dans le délai imparti.\n" : ""
            throw .compileFailed(output: reason + result.output)
        }
    }

    public func requestInstall() {
        let process = Process()
        process.executableURL = xcodeSelect
        process.arguments = ["--install"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        DispatchQueue.global().async {
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
        }
    }
}

/// Un processus lancé et attendu, avec un délai : SIGTERM au-delà, puis SIGKILL deux secondes plus tard (et, si même cela
/// ne le libère pas, deux secondes encore avant de rendre la main : jamais d'attente sans limite). Il est
/// lancé dans son propre groupe de processus, et les signaux visent tout le groupe : clang++ lance lui-même
/// `clang -cc1` et `ld`, qui ne survivent pas à un délai dépassé.
/// L'entrée standard est vide ; la sortie et les erreurs sont jetées, ou recueillies dans un fichier temporaire.
enum ChildProcess {
    struct Result {
        /// Sorti normalement (pas tué par un signal).
        var exited: Bool
        var status: Int32
        var timedOut: Bool
        /// Sortie et erreurs mêlées, si demandées.
        var output: String
    }

    /// Délai laissé au groupe pour sortir après SIGTERM, avant SIGKILL.
    static let terminationGrace: TimeInterval = 2

    /// nil si le processus n'a pas pu être lancé.
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        captureOutput: Bool = false
    ) -> Result? {
        let outputPath = captureOutput
            ? FileManager.default.temporaryDirectory.appending(path: "ptzbot-sortie-\(UUID().uuidString)").path
            : "/dev/null"
        defer {
            if captureOutput {
                try? FileManager.default.removeItem(atPath: outputPath)
            }
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, outputPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Son propre groupe (pgid = pid) ; les descripteurs de l'app ne passent pas au fils.
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp) == 0 else { return nil }

        // L'attente se fait dans un fil à part, pour pouvoir la borner.
        let done = DispatchSemaphore(value: 0)
        let waited = WaitStatus()
        let child = pid
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0, errno == EINTR {}
            waited.set(status)
            done.signal()
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // C'est le groupe que nous venons de créer : clang++ et ses enfants.
            Darwin.kill(-pid, SIGTERM)
            if done.wait(timeout: .now() + terminationGrace) == .timedOut {
                Darwin.kill(-pid, SIGKILL)
                // Jamais d'attente sans limite : un enfant impossible à tuer (attente du noyau) ne doit pas bloquer
                // l'appelant pour toujours. Le fil d'attente le récoltera s'il finit un jour.
                _ = done.wait(timeout: .now() + terminationGrace)
            }
        }
        // Les restes du groupe (un enfant qui ignorerait SIGTERM) ne survivent pas au délai.
        if timedOut {
            Darwin.kill(-pid, SIGKILL)
        }
        let status = waited.value
        let exitedNormally = (status & 0x7f) == 0
        let output = captureOutput
            ? (FileManager.default.contents(atPath: outputPath).map { String(decoding: $0, as: UTF8.self) } ?? "")
            : ""
        return Result(
            exited: exitedNormally && !timedOut,
            status: exitedNormally ? (status >> 8) & 0xff : status & 0x7f,
            timedOut: timedOut,
            output: output
        )
    }
}

/// Le statut rendu par `waitpid`, transmis du fil d'attente.
private final class WaitStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32 = 0

    var value: Int32 {
        lock.withLock { status }
    }

    func set(_ value: Int32) {
        lock.withLock { status = value }
    }
}
