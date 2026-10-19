import Foundation

/// Garde `obsbot-ai serve` lancé pendant qu'un client pilote : le SDK n'est chargé qu'une fois, et un ordre
/// part en quelques millisecondes au lieu de 4 s. L'utilitaire s'arrête après `idleDelay` sans activité.
///
/// Protocole : un ordre par ligne (`on`, `off`, `privacy on`, `privacy off` ou `privacy status`) sur l'entrée de
/// l'utilitaire. Sur sa sortie, les lignes préfixées par `obsbot-ai: ` sont des réponses (`ready` une fois le SDK prêt,
/// puis `ok`, `ok <état> [<inclinaison>]` pour `privacy status`, ou `err <code> [<inclinaison>]` par ordre) ; toute
/// autre ligne est du bruit du SDK, ajouté au fichier de sortie. L'utilitaire se termine quand son entrée se ferme, ce
/// qui arrive aussi si ptzd meurt.
///
/// Un seul ordre à la fois : un ordre donné pendant un autre est refusé (`launchFailed`). `AIOrderQueue` les met à la
/// file. `err 3` (« ordre inconnu ») vient d'un utilitaire plus ancien que ptzd : `unknownOrder`, et l'utilitaire est
/// arrêté, pour que le suivant parte du programme recompilé (spec § 6.5 bis). Une **lecture** de l'état ratée
/// (`err 2` de `privacy status`) n'arrête pas l'utilitaire : elle ne rend pas la session douteuse, et une session neuve
/// coûterait 4 s.
@MainActor
public final class ResidentAIRunner: AIRunner {
    /// Identité d'une extrémité de tuyau (fstat), pour vérifier en test qu'aucune ne fuit.
    struct PipeIdentity: Hashable {
        let device: Int32
        let inode: UInt64
    }

    /// Un utilitaire lancé. Son état n'est touché que depuis la file principale ; les autres fils ne
    /// font que lire le tuyau de sortie. Quand plus personne ne le retient, son entrée se ferme et
    /// l'utilitaire se termine.
    private final class Helper: @unchecked Sendable {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        var log: FileHandle?
        var ready = false
        var buffer = Data()
        /// La sortie est fermée (fin de fichier lue).
        var outputEnded = false
        var exitStatus: Int32?
        /// Vraie sortie (`exit`), par opposition à un signal : alors `exitStatus` est le numéro du signal.
        var exitedNormally = false
        var retired = false
        /// A répondu « ok » à au moins un ordre.
        var served = false
        /// Arrêté par nous : sa fin n'est pas un incident.
        var stoppedOnPurpose = false

        deinit {
            try? input.fileHandleForWriting.close()
        }
    }

    private static let prefix = "obsbot-ai: "
    /// Attente de la fin de la sortie après la mort de l'utilitaire (un petit-fils pourrait garder le tuyau).
    private static let outputGrace: TimeInterval = 0.5
    /// Délai entre l'arrêt demandé et SIGKILL, renvoyé au plus `killAttempts` fois.
    private static let killDelay: TimeInterval = 3
    private static let killAttempts = 3
    /// Après un utilitaire mort sans avoir servi, ou expiré, `prewarm` ne relance rien pendant ce temps.
    static let backoff: TimeInterval = 60
    /// L'échéance d'inactivité n'est repoussée qu'après cet intervalle (les messages arrivent à 10 Hz).
    private static let rearmInterval: TimeInterval = 1

    private let executableURL: URL
    private let outputURL: URL?
    /// Variables ajoutées à l'environnement hérité (`DYLD_LIBRARY_PATH` du SDK, spec ptzd dans l'app § 5.4).
    private let environment: [String: String]
    private let scheduler: any Scheduler
    private let idleDelay: TimeInterval
    private let readyTimeout: TimeInterval
    private let orderTimeout: TimeInterval
    /// Les ordres de la vie privée native rendent la main tout de suite (0 ms mesuré le 19/10 : la caméra bascule
    /// ensuite d'elle-même) ; même délai qu'un changement de suivi par défaut (spec § 6.5 bis).
    private let privacyOrderTimeout: TimeInterval
    private let log: LogSink

    /// L'utilitaire en service.
    private var helper: Helper?
    /// Un utilitaire qu'on a arrêté et dont on attend la fin avant d'en relancer un (jamais deux ensemble).
    private var stopping: Helper?
    /// Un lancement est demandé alors que `stopping` n'a pas fini.
    private var wanted = false
    /// Réponse de l'utilitaire à un ordre : `ok`, avec les mots qui suivent (l'état et l'inclinaison lus pour
    /// `privacy status`), ou l'échec, avec les mots qui suivent le code (l'inclinaison d'une lecture ratée).
    private enum Reply {
        case ok([Substring])
        case failed(AIResult, [Substring])
    }

    /// Ordre en attente que l'utilitaire soit prêt, puis en cours.
    private var order: (order: AIOrder, completion: @MainActor @Sendable (Reply) -> Void, sent: Bool)?
    /// Du lancement à « ready » : le SDK met environ 4 s, 10 s de recherche de la caméra au pire.
    private var startTimer: (any Cancellable)?
    /// De l'écriture de l'ordre à sa réponse.
    private var orderTimer: (any Cancellable)?
    private var idleTimer: (any Cancellable)?
    private var lastIdleRearm: TimeInterval?
    private var noPrewarmUntil: TimeInterval?
    /// Extrémités de tuyau de tous les utilitaires lancés (tests).
    private(set) var recordedPipes: [PipeIdentity] = []

    public init(
        executableURL: URL,
        outputURL: URL? = nil,
        environment: [String: String] = [:],
        scheduler: any Scheduler,
        idleDelay: TimeInterval = 600,
        readyTimeout: TimeInterval = 25,
        orderTimeout: TimeInterval = 5,
        privacyOrderTimeout: TimeInterval = 5,
        log: @escaping LogSink = { _ in }
    ) {
        self.executableURL = executableURL
        self.outputURL = outputURL
        self.environment = environment
        self.scheduler = scheduler
        self.idleDelay = idleDelay
        self.readyTimeout = readyTimeout
        self.orderTimeout = orderTimeout
        self.privacyOrderTimeout = privacyOrderTimeout
        self.log = log
    }

    /// Un utilitaire tourne (tests).
    var hasHelper: Bool {
        helper != nil
    }

    /// Ni utilitaire en service ni utilitaire en cours d'arrêt (tests).
    var isIdle: Bool {
        helper == nil && stopping == nil
    }

    /// Lance l'utilitaire s'il ne tourne pas, sans ordre. Sans effet pendant 60 s après un utilitaire
    /// mort ou expiré sans avoir servi : seul un ordre le relance alors.
    public func prewarm() {
        if let until = noPrewarmUntil, scheduler.now < until {
            return
        }
        restartIdleTimer()
        ensureHelper()
    }

    public func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        submit(.tracking(on: on)) { completion(Self.result(of: $0)) }
    }

    public func runPrivacy(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        submit(.privacy(on: on)) { completion(Self.result(of: $0)) }
    }

    /// `privacy status` : « ok run 69.8 » ou « ok privacy 84.9 » (l'inclinaison peut manquer), « err 2 84.9 » si l'état
    /// ne se lit pas. Un autre mot est un échec, jamais un état deviné ; l'inclinaison reste le second témoin.
    public func readPrivacy(completion: @escaping @MainActor @Sendable (PrivacyReading) -> Void) {
        submit(.privacyStatus) { [weak self] reply in
            switch reply {
            case let .ok(words):
                let pitch = words.dropFirst().first.flatMap { Double($0) }
                if let word = words.first, let state = CameraRunState(rawValue: String(word)) {
                    completion(.state(state, pitch: pitch))
                } else {
                    self?.log("obsbot-ai : état illisible (« \(words.joined(separator: " ")) »).")
                    completion(.failed(.sdkError, pitch: pitch))
                }
            case let .failed(result, words):
                completion(.failed(result, pitch: words.first.flatMap { Double($0) }))
            }
        }
    }

    private static func result(of reply: Reply) -> AIResult {
        switch reply {
        case .ok: .success
        case let .failed(result, _): result
        }
    }

    /// Sans l'utilitaire installé (pas de SDK), la vie privée native n'existe pas (spec § 6.5 bis).
    public var supportsNativePrivacy: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    private func submit(_ newOrder: AIOrder, completion: @escaping @MainActor @Sendable (Reply) -> Void) {
        guard order == nil else {
            completion(.failed(.launchFailed("ordre précédent encore en cours"), []))
            return
        }
        restartIdleTimer()
        order = (newOrder, completion, false)
        ensureHelper()
        if order != nil, !(helper?.ready ?? false), startTimer == nil {
            // Un ancien utilitaire finit de mourir : l'attente est bornée comme un démarrage.
            armStartTimer()
        }
        sendIfReady()
    }

    /// Arrête l'utilitaire ; le prochain `prewarm` ou ordre en lance un neuf (SDK à jour après un
    /// rebranchement de la caméra). Un ordre en cours échoue.
    public func reset() {
        noPrewarmUntil = nil
        stopHelper(terminate: false)
        fail(.launchFailed("utilitaire réinitialisé"))
    }

    /// Arrête l'utilitaire (fermeture de son entrée) ; un ordre en cours échoue.
    public func shutdown() {
        idleTimer?.cancel()
        idleTimer = nil
        stopHelper(terminate: false)
        fail(.launchFailed("ptzd s'arrête"))
    }

    // MARK: - Cycle de vie de l'utilitaire

    private func ensureHelper() {
        wanted = true
        if helper == nil && stopping == nil {
            start()
        }
    }

    private func start() {
        let helper = Helper()
        let process = helper.process
        process.executableURL = executableURL
        process.arguments = ["serve"]
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        helper.log = appendingHandle()
        process.standardInput = helper.input
        process.standardOutput = helper.output
        process.standardError = helper.log ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self, weak helper] finished in
            let status = finished.terminationStatus
            let exited = finished.terminationReason == .exit
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let helper else { return }
                    self.terminated(helper, status: status, exited: exited)
                }
            }
        }
        // Avant le lancement : Process referme lui-même ses copies des extrémités du fils.
        recordPipes(of: helper)
        do {
            try process.run()
        } catch {
            try? helper.log?.close()
            noPrewarmUntil = scheduler.now + Self.backoff
            fail(.launchFailed(error.localizedDescription))
            return
        }
        // Écrire dans un tuyau dont l'utilitaire est mort ne doit pas tuer ptzd (pas de SIGPIPE).
        _ = fcntl(helper.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Les extrémités du fils sont refermées ici (sans effet si Process l'a déjà fait).
        try? helper.input.fileHandleForReading.close()
        try? helper.output.fileHandleForWriting.close()
        self.helper = helper
        armStartTimer()
        read(helper)
    }

    private func recordPipes(of helper: Helper) {
        for handle in [
            helper.input.fileHandleForReading, helper.input.fileHandleForWriting,
            helper.output.fileHandleForReading, helper.output.fileHandleForWriting,
        ] {
            var info = stat()
            if fstat(handle.fileDescriptor, &info) == 0 {
                recordedPipes.append(PipeIdentity(device: info.st_dev, inode: info.st_ino))
            }
        }
    }

    /// Lit la sortie de l'utilitaire sur un fil à part et rend chaque morceau, dans l'ordre, à la file principale.
    private func read(_ helper: Helper) {
        let reading = helper.output.fileHandleForReading
        let descriptor = reading.fileDescriptor
        DispatchQueue.global(qos: .utility).async { [weak self, weak helper] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    let data = Data(buffer[0..<count])
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, let helper else { return }
                            self.received(data, from: helper)
                        }
                    }
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            try? reading.close()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let helper else { return }
                    self.outputClosed(helper)
                }
            }
        }
    }

    private func received(_ data: Data, from source: Helper) {
        source.buffer.append(data)
        while let newline = source.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: source.buffer[source.buffer.startIndex..<newline], as: UTF8.self)
            source.buffer.removeSubrange(source.buffer.startIndex...newline)
            handle(line: line, from: source)
        }
    }

    /// Une ligne de la sortie : le bruit du SDK (y compris celui qui précède une réponse, sans fin de ligne)
    /// va au fichier de sortie, la réponse est traitée.
    private func handle(line: String, from source: Helper) {
        var noise = line
        var reply: String?
        if let range = line.range(of: Self.prefix) {
            noise = String(line[..<range.lowerBound])
            reply = String(line[range.upperBound...])
        }
        if !noise.isEmpty {
            try? source.log?.write(contentsOf: Data((noise + "\n").utf8))
        }
        // Un utilitaire qu'on a arrêté n'a plus rien à dire sur l'ordre en cours.
        guard let reply, source === helper else { return }
        switch reply {
        case "ready":
            source.ready = true
            startTimer?.cancel()
            startTimer = nil
            sendIfReady()
        case "ok":
            source.served = true
            noPrewarmUntil = nil
            finish(.ok([]))
        case _ where reply.hasPrefix("ok "):
            // `privacy status` : l'état et l'inclinaison suivent « ok ».
            source.served = true
            noPrewarmUntil = nil
            finish(.ok(reply.dropFirst(3).split(separator: " ")))
        default:
            // « err <code> », suivi de l'inclinaison pour une lecture ratée.
            let words = reply.split(separator: " ")
            let code = words.count > 1 ? Int32(words[1]) ?? -1 : -1
            if code == 1 {
                // Caméra introuvable : l'utilitaire sort de lui-même.
                fail(.cameraNotFound)
            } else if code == 2, order?.order == .privacyStatus {
                // Lecture de l'état ratée : la session n'est pas douteuse, l'utilitaire reste (constat D).
                finish(.failed(.sdkError, Array(words.dropFirst(2))))
            } else {
                // Session du SDK douteuse, ou utilitaire plus ancien que l'ordre (code 3) : la prochaine fois, un
                // utilitaire neuf, lancé depuis le programme (peut-être recompilé entre-temps). L'arrêt vient avant
                // la réponse, pour qu'un ordre donné par le rappel parte sur le nouveau.
                stopHelper(terminate: false)
                switch code {
                case 2: fail(.sdkError)
                case 3: fail(.unknownOrder)
                default: fail(.unexpectedExit(code))
                }
            }
        }
    }

    private func sendIfReady() {
        guard let helper, helper.ready, let current = order, !current.sent else { return }
        order?.sent = true
        do {
            try helper.input.fileHandleForWriting.write(contentsOf: Data((current.order.line + "\n").utf8))
        } catch {
            log("obsbot-ai : écriture de l'ordre impossible (\(error)).")
            stopHelper(terminate: false)
            fail(.unexpectedExit(-1))
            return
        }
        orderTimer?.cancel()
        // Un ordre de la vie privée native a son propre délai ; la lecture de l'état (1 à 5 ms, plus la position, jusqu'à
        // 1 s mesuré) a celui d'un changement de suivi.
        let timeout: TimeInterval = if case .privacy = current.order { privacyOrderTimeout } else { orderTimeout }
        orderTimer = scheduler.schedule(after: timeout) { [weak self] in
            self?.expired(waitingFor: "réponse")
        }
    }

    private func armStartTimer() {
        startTimer?.cancel()
        startTimer = scheduler.schedule(after: readyTimeout) { [weak self] in
            self?.expired(waitingFor: "ready")
        }
    }

    /// Délai dépassé : l'utilitaire est arrêté d'abord, puis l'ordre échoue (le rappel peut en donner un autre).
    private func expired(waitingFor what: String) {
        log("obsbot-ai : pas de \(what) à temps.")
        noPrewarmUntil = scheduler.now + Self.backoff
        stopHelper(terminate: true)
        fail(.timeout)
    }

    private func outputClosed(_ closed: Helper) {
        if !closed.buffer.isEmpty {
            // Dernière ligne sans fin de ligne.
            let line = String(decoding: closed.buffer, as: UTF8.self)
            closed.buffer = Data()
            handle(line: line, from: closed)
        }
        closed.outputEnded = true
        if closed.exitStatus != nil {
            retire(closed)
        }
    }

    private func terminated(_ ended: Helper, status: Int32, exited: Bool) {
        ended.exitStatus = status
        ended.exitedNormally = exited
        if ended.outputEnded {
            retire(ended)
        } else {
            scheduler.schedule(after: Self.outputGrace) { [weak self, weak ended] in
                guard let self, let ended else { return }
                retire(ended)
            }
        }
    }

    /// L'utilitaire est mort et sa sortie est lue.
    private func retire(_ ended: Helper) {
        guard !ended.retired, let status = ended.exitStatus else { return }
        ended.retired = true
        try? ended.log?.close()
        ended.log = nil
        if ended === helper {
            helper = nil
            startTimer?.cancel()
            startTimer = nil
            if !ended.served {
                // Mort sans avoir rien fait : pas de relance à chaque message pendant une minute.
                noPrewarmUntil = scheduler.now + Self.backoff
            }
            // Le 1 n'est « caméra introuvable » que pour une vraie sortie : un SIGHUP vaut aussi 1.
            fail(ended.exitedNormally && status == 1 ? .cameraNotFound : .unexpectedExit(status))
        } else if ended === stopping {
            stopping = nil
            if wanted {
                start()
            }
        }
    }

    /// Ferme l'entrée : l'utilitaire libère le SDK et se termine. `terminate` y ajoute SIGTERM (utilitaire
    /// bloqué) ; SIGKILL s'il vit encore 3 s plus tard, renvoyé jusqu'à 3 fois.
    private func stopHelper(terminate: Bool) {
        idleTimer?.cancel()
        idleTimer = nil
        startTimer?.cancel()
        startTimer = nil
        wanted = false
        guard let stopped = helper else { return }
        helper = nil
        stopping = stopped
        stopped.stoppedOnPurpose = true
        try? stopped.input.fileHandleForWriting.close()
        if terminate && stopped.process.isRunning {
            stopped.process.terminate()
        }
        scheduleKill(of: stopped, attempt: 1)
        // Déjà mort (sa fin a été traitée avant l'arrêt) : rien à attendre.
        if stopped.exitStatus != nil && stopped.outputEnded {
            retire(stopped)
        }
    }

    private func scheduleKill(of stopped: Helper, attempt: Int) {
        scheduler.schedule(after: Self.killDelay) { [weak self, weak stopped] in
            guard let self, let stopped, stopped.process.isRunning else { return }
            log("obsbot-ai (pid \(stopped.process.processIdentifier)) tourne encore : SIGKILL \(attempt)/\(Self.killAttempts).")
            kill(stopped.process.processIdentifier, SIGKILL)
            if attempt < Self.killAttempts {
                scheduleKill(of: stopped, attempt: attempt + 1)
            }
        }
    }

    private func finish(_ reply: Reply) {
        guard let current = order else { return }
        order = nil
        orderTimer?.cancel()
        orderTimer = nil
        current.completion(reply)
    }

    private func fail(_ result: AIResult) {
        finish(.failed(result, []))
    }

    private func restartIdleTimer() {
        let now = scheduler.now
        if idleTimer != nil, let last = lastIdleRearm, now - last < Self.rearmInterval {
            return
        }
        lastIdleRearm = now
        idleTimer?.cancel()
        idleTimer = scheduler.schedule(after: idleDelay) { [weak self] in
            guard let self else { return }
            idleTimer = nil
            if order == nil {
                stopHelper(terminate: false)
            } else {
                restartIdleTimer()
            }
        }
    }

    private func appendingHandle() -> FileHandle? {
        guard let outputURL else { return nil }
        let manager = FileManager.default
        try? manager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: outputURL.path) {
            manager.createFile(atPath: outputURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: outputURL) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }
}
