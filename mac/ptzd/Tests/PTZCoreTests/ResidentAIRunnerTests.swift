import Foundation
import NacelleProtocol
import Testing
@testable import PTZCore

/// `obsbot-ai serve` simulé par un script `/bin/sh` : jamais le vrai utilitaire.
@MainActor
private final class FakeServe {
    let directory = FileManager.default.temporaryDirectory.appending(path: "serve-\(UUID().uuidString)")
    var executableURL: URL { directory.appending(path: "obsbot-ai") }
    var logURL: URL { directory.appending(path: "obsbot-ai.log") }

    /// `body` suit un préambule qui note le numéro du processus dans `starts`, une ligne par lancement.
    init(_ body: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            dir=$(dirname "$0")
            echo $$ >> "$dir/starts"
            \(body)
            """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }

    func lines(_ name: String) -> [String] {
        let text = (try? String(contentsOf: directory.appending(path: name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    var starts: [String] { lines("starts") }
    var orders: [String] { lines("orders") }

    func isAlive(_ pid: String) -> Bool {
        kill(pid_t(pid) ?? 0, 0) == 0
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Résultat d'un ordre dont on ne veut pas attendre la fin tout de suite.
@MainActor
private final class Outcome {
    var value: AIResult?
}

/// Résultat d'une lecture de l'état réel.
@MainActor
private final class ReadingOutcome {
    var value: PrivacyReading?
}

/// Réponse « ok » à chaque ordre, après un démarrage de 0,2 s qui laisse passer du bruit sur les deux sorties.
private let answering = """
    echo "bruit du SDK"
    echo "bruit d'erreur" >&2
    sleep 0.2
    echo "obsbot-ai: ready"
    while read order; do
        echo "$order" >> "$dir/orders"
        echo "obsbot-ai: ok"
    done
    echo fin >> "$dir/exits"
    """

@MainActor
@Suite("Utilitaire obsbot-ai résident", .serialized, .timeLimit(.minutes(1)))
struct ResidentAIRunnerTests {
    private func runner(
        _ serve: FakeServe,
        scheduler: any Scheduler,
        environment: [String: String] = [:],
        idleDelay: TimeInterval = 600,
        readyTimeout: TimeInterval = 25,
        orderTimeout: TimeInterval = 5
    ) -> ResidentAIRunner {
        ResidentAIRunner(
            executableURL: serve.executableURL,
            outputURL: serve.logURL,
            environment: environment,
            scheduler: scheduler,
            idleDelay: idleDelay,
            readyTimeout: readyTimeout,
            orderTimeout: orderTimeout
        )
    }

    /// Donne un ordre et attend son résultat 10 s au plus (nil si le runner ne répond jamais).
    private func order(_ runner: ResidentAIRunner, on: Bool = true) async -> AIResult? {
        let outcome = Outcome()
        runner.run(on: on) { outcome.value = $0 }
        _ = await eventually { outcome.value != nil }
        return outcome.value
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while !condition() {
            guard ContinuousClock.now - start < .seconds(10) else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Arrête l'utilitaire et attend sa fin, pour ne laisser ni processus ni dossier.
    private func cleanUp(_ runner: ResidentAIRunner, _ serve: FakeServe) async {
        runner.shutdown()
        _ = await eventually { serve.starts.allSatisfy { !serve.isAlive($0) } }
        serve.remove()
    }

    @Test("Démarrage à froid : l'ordre attend « ready », reçoit « ok » ; le bruit du SDK va au fichier de sortie")
    func coldStart() async throws {
        let serve = try FakeServe(answering)
        let runner = runner(serve, scheduler: DispatchScheduler())
        #expect(await order(runner, on: true) == .success)
        #expect(serve.starts.count == 1)
        #expect(serve.orders == ["on"])
        let log = try String(contentsOf: serve.logURL, encoding: .utf8)
        #expect(log.contains("bruit du SDK\n"))
        #expect(log.contains("bruit d'erreur\n"))
        #expect(!log.contains("obsbot-ai:"))
        await cleanUp(runner, serve)
    }

    @Test("Deuxième ordre : même processus, sans relance")
    func secondOrder() async throws {
        let serve = try FakeServe(answering)
        let runner = runner(serve, scheduler: DispatchScheduler())
        #expect(await order(runner, on: true) == .success)
        #expect(await order(runner, on: false) == .success)
        #expect(serve.starts.count == 1)
        #expect(serve.orders == ["on", "off"])
        await cleanUp(runner, serve)
    }

    @Test("err 2 : erreur du SDK, puis l'utilitaire est arrêté ; l'ordre suivant tourne dans un processus neuf")
    func sdkError() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: ready"
            while read order; do echo "obsbot-ai: err 2"; done
            """)
        let runner = runner(serve, scheduler: DispatchScheduler())
        #expect(await order(runner) == .sdkError)
        #expect(await order(runner) == .sdkError)
        #expect(serve.starts.count == 2)
        #expect(Set(serve.starts).count == 2)
        await cleanUp(runner, serve)
    }

    @Test("err 3 : ordre inconnu (utilitaire plus ancien que ptzd), même arrêt, processus neuf ensuite")
    func badOrder() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: ready"
            while read order; do echo "obsbot-ai: err 3"; done
            """)
        let runner = runner(serve, scheduler: DispatchScheduler())
        #expect(await order(runner) == .unknownOrder)
        #expect(await order(runner) == .unknownOrder)
        #expect(serve.starts.count == 2)
        await cleanUp(runner, serve)
    }

    @Test("err 1 avant « ready » puis sortie 1 : caméra introuvable")
    func cameraNotFound() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: err 1"
            exit 1
            """)
        let runner = runner(serve, scheduler: DispatchScheduler())
        #expect(await order(runner) == .cameraNotFound)
        await cleanUp(runner, serve)
    }

    @Test("Tué par un signal (SIGHUP, numéro 1) : sortie inattendue, pas « caméra introuvable »")
    func killedBySignal() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: ready"
            read order
            kill -HUP $$
            """)
        let runner = runner(serve, scheduler: DispatchScheduler())
        #expect(await order(runner) == .unexpectedExit(1))
        await cleanUp(runner, serve)
    }

    @Test("Sortie de l'utilitaire en plein ordre : sortie inattendue, et l'ordre suivant le relance")
    func exitsMidOrder() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: ready"
            read order
            exit 5
            """)
        let runner = runner(serve, scheduler: DispatchScheduler())
        #expect(await order(runner) == .unexpectedExit(5))
        #expect(await order(runner) == .unexpectedExit(5))
        #expect(serve.starts.count == 2)
        await cleanUp(runner, serve)
    }

    /// Premier lancement : lit l'ordre, le note, ne répond jamais ; les suivants répondent.
    private static let silentThenAnswering = """
        echo "obsbot-ai: ready"
        if [ "$(wc -l < "$dir/starts")" -ge 2 ]; then
            while read order; do echo "obsbot-ai: ok"; done
        else
            read order
            echo "$order" >> "$dir/orders"
            exec sleep 30
        fi
        """

    @Test("Pas de réponse 5 s après l'écriture de l'ordre : .timeout, processus arrêté, l'ordre suivant relance")
    func orderTimeout() async throws {
        let serve = try FakeServe(Self.silentThenAnswering)
        let scheduler = FakeScheduler()
        let runner = runner(serve, scheduler: scheduler)
        let outcome = Outcome()
        runner.run(on: true) { outcome.value = $0 }
        #expect(await eventually { serve.orders.count == 1 })
        let first = try #require(serve.starts.first)
        scheduler.advance(by: 4.9)
        #expect(outcome.value == nil)
        scheduler.advance(by: 0.2)
        #expect(outcome.value == .timeout)
        #expect(await eventually { !serve.isAlive(first) })
        // Le suivant n'a pas à attendre l'arrêt complet du premier.
        #expect(await order(runner) == .success)
        #expect(serve.starts.count == 2)
        await cleanUp(runner, serve)
    }

    @Test("Pas de « ready » en 25 s : .timeout (le délai de 5 s ne court qu'une fois l'ordre écrit), processus arrêté")
    func readyTimeout() async throws {
        let serve = try FakeServe("exec sleep 30")
        let scheduler = FakeScheduler()
        let runner = runner(serve, scheduler: scheduler)
        let outcome = Outcome()
        runner.run(on: true) { outcome.value = $0 }
        #expect(await eventually { serve.starts.count == 1 })
        let first = try #require(serve.starts.first)
        scheduler.advance(by: 24)
        #expect(outcome.value == nil)
        scheduler.advance(by: 2)
        #expect(outcome.value == .timeout)
        #expect(await eventually { !serve.isAlive(first) })
        await cleanUp(runner, serve)
    }

    @Test("Le rappel d'un délai dépassé donne un nouvel ordre : un utilitaire neuf le traite")
    func completionRunsAgainOnTimeout() async throws {
        let serve = try FakeServe(Self.silentThenAnswering)
        let scheduler = FakeScheduler()
        let runner = runner(serve, scheduler: scheduler)
        let second = Outcome()
        runner.run(on: true) { result in
            #expect(result == .timeout)
            runner.run(on: false) { second.value = $0 }
        }
        #expect(await eventually { serve.orders.count == 1 })
        scheduler.advance(by: 6)
        #expect(await eventually { second.value != nil })
        #expect(second.value == .success)
        #expect(serve.starts.count == 2)
        await cleanUp(runner, serve)
    }

    @Test("Le rappel d'un err 2 donne un nouvel ordre : il part sur un utilitaire neuf")
    func completionRunsAgainAfterError() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: ready"
            if [ "$(wc -l < "$dir/starts")" -ge 2 ]; then
                while read order; do echo "obsbot-ai: ok"; done
            else
                read order
                echo "obsbot-ai: err 2"
                read eof
            fi
            """)
        let runner = runner(serve, scheduler: DispatchScheduler())
        let second = Outcome()
        runner.run(on: true) { result in
            #expect(result == .sdkError)
            runner.run(on: true) { second.value = $0 }
        }
        #expect(await eventually { second.value != nil })
        #expect(second.value == .success)
        #expect(serve.starts.count == 2)
        await cleanUp(runner, serve)
    }

    @Test("Ordre en cours : un second ordre est refusé, le premier aboutit")
    func overlap() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: ready"
            while read order; do sleep 0.3; echo "obsbot-ai: ok"; done
            """)
        let runner = runner(serve, scheduler: DispatchScheduler())
        let first = Outcome()
        runner.run(on: true) { first.value = $0 }
        #expect(await order(runner, on: false) == .launchFailed("ordre précédent encore en cours"))
        #expect(await eventually { first.value != nil })
        #expect(first.value == .success)
        #expect(serve.starts.count == 1)
        await cleanUp(runner, serve)
    }

    @Test("prewarm lance l'utilitaire sans ordre ; l'ordre suivant ne relance rien")
    func prewarm() async throws {
        let serve = try FakeServe(answering)
        let runner = runner(serve, scheduler: DispatchScheduler())
        runner.prewarm()
        #expect(await eventually { serve.starts.count == 1 })
        runner.prewarm()
        #expect(serve.orders.isEmpty)
        #expect(await order(runner) == .success)
        #expect(serve.starts.count == 1)
        await cleanUp(runner, serve)
    }

    @Test("Après le délai d'inactivité : l'entrée se ferme, l'utilitaire sort, l'ordre suivant le relance")
    func idleThenRestart() async throws {
        let serve = try FakeServe(answering)
        let scheduler = FakeScheduler()
        let runner = runner(serve, scheduler: scheduler, idleDelay: 600)
        #expect(await order(runner) == .success)
        let first = try #require(serve.starts.first)
        scheduler.advance(by: 599)
        #expect(serve.isAlive(first))
        scheduler.advance(by: 2)
        #expect(await eventually { !serve.isAlive(first) })
        #expect(serve.lines("exits") == ["fin"])
        #expect(await order(runner) == .success)
        #expect(serve.starts.count == 2)
        await cleanUp(runner, serve)
    }

    @Test("Ordre donné pendant l'arrêt pour inactivité : il attend la fin de l'ancien utilitaire, puis aboutit")
    func orderWhileStopping() async throws {
        let serve = try FakeServe(answering)
        let scheduler = FakeScheduler()
        let runner = runner(serve, scheduler: scheduler, idleDelay: 600)
        #expect(await order(runner) == .success)
        scheduler.advance(by: 601)
        #expect(await order(runner) == .success)
        #expect(serve.starts.count == 2)
        #expect(serve.lines("exits") == ["fin"])
        await cleanUp(runner, serve)
    }

    @Test("Un utilitaire encore occupé n'est pas arrêté pour inactivité pendant un ordre")
    func idleWaitsForOrder() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: ready"
            while read order; do sleep 0.3; echo "obsbot-ai: ok"; done
            """)
        let scheduler = FakeScheduler()
        let runner = runner(serve, scheduler: scheduler, idleDelay: 600, readyTimeout: 3000, orderTimeout: 3000)
        let outcome = Outcome()
        runner.run(on: true) { outcome.value = $0 }
        scheduler.advance(by: 601)
        #expect(await eventually { outcome.value != nil })
        #expect(outcome.value == .success)
        #expect(serve.starts.count == 1)
        await cleanUp(runner, serve)
    }

    @Test("Le runner libéré ferme l'entrée : l'utilitaire se termine")
    func deallocationStopsHelper() async throws {
        let serve = try FakeServe(answering)
        var runner: ResidentAIRunner? = runner(serve, scheduler: FakeScheduler())
        runner?.prewarm()
        #expect(await eventually { serve.starts.count == 1 })
        let pid = try #require(serve.starts.first)
        runner = nil
        #expect(await eventually { !serve.isAlive(pid) })
        serve.remove()
    }

    @Test("Utilitaire mort sans avoir servi (err 1) : aucun prewarm pendant 60 s, puis il relance")
    func backoffAfterDeath() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: err 1"
            exit 1
            """)
        let scheduler = FakeScheduler()
        let runner = runner(serve, scheduler: scheduler)
        runner.prewarm()
        #expect(await eventually { serve.starts.count == 1 && runner.isIdle })
        for _ in 0..<5 {
            runner.prewarm()
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(serve.starts.count == 1)
        scheduler.advance(by: 59)
        runner.prewarm()
        try await Task.sleep(for: .milliseconds(150))
        #expect(serve.starts.count == 1)
        scheduler.advance(by: 2)
        runner.prewarm()
        #expect(await eventually { serve.starts.count == 2 })
        await cleanUp(runner, serve)
    }

    @Test("Pendant l'attente après un échec, un ordre démarre quand même un utilitaire et reçoit son résultat")
    func orderDuringBackoff() async throws {
        let serve = try FakeServe("""
            if [ "$(wc -l < "$dir/starts")" -lt 2 ]; then
                echo "obsbot-ai: err 1"
                exit 1
            fi
            echo "obsbot-ai: ready"
            while read order; do echo "obsbot-ai: ok"; done
            """)
        let runner = runner(serve, scheduler: FakeScheduler())
        runner.prewarm()
        #expect(await eventually { serve.starts.count == 1 && runner.isIdle })
        #expect(await order(runner) == .success)
        #expect(serve.starts.count == 2)
        await cleanUp(runner, serve)
    }

    @Test("reset : l'utilitaire s'arrête, l'ordre suivant tourne dans un processus neuf")
    func resetRestarts() async throws {
        let serve = try FakeServe(answering)
        let runner = runner(serve, scheduler: DispatchScheduler())
        #expect(await order(runner) == .success)
        runner.reset()
        #expect(await order(runner) == .success)
        #expect(serve.starts.count == 2)
        #expect(Set(serve.starts).count == 2)
        await cleanUp(runner, serve)
    }

    @Test("reset pendant un ordre : l'ordre échoue, le suivant aboutit")
    func resetFailsPendingOrder() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: ready"
            if [ "$(wc -l < "$dir/starts")" -ge 2 ]; then
                while read order; do echo "obsbot-ai: ok"; done
            else
                read order
                echo "$order" >> "$dir/orders"
                read eof
            fi
            """)
        let runner = runner(serve, scheduler: FakeScheduler())
        let first = Outcome()
        runner.run(on: true) { first.value = $0 }
        #expect(await eventually { serve.orders.count == 1 })
        runner.reset()
        guard case .launchFailed = first.value else {
            Issue.record("launchFailed attendu")
            return
        }
        #expect(await order(runner) == .success)
        await cleanUp(runner, serve)
    }

    @Test("Bruit du SDK sans fin de ligne devant une réponse : la réponse passe, le bruit va au journal")
    func noiseGluedToReplies() async throws {
        let serve = try FakeServe("""
            printf 'bruit1'
            echo "obsbot-ai: ready"
            while read order; do
                printf 'bruit2' >&2
                printf 'bruit3'
                echo "obsbot-ai: ok"
            done
            """)
        let runner = runner(serve, scheduler: DispatchScheduler())
        #expect(await order(runner) == .success)
        #expect(await order(runner) == .success)
        #expect(serve.starts.count == 1)
        let log = try String(contentsOf: serve.logURL, encoding: .utf8)
        #expect(log.contains("bruit1\n"))
        #expect(log.contains("bruit3\n"))
        #expect(log.contains("bruit2"))
        #expect(!log.contains("obsbot-ai:"))
        await cleanUp(runner, serve)
    }

    @Test("Aucune extrémité de tuyau ne fuit après des cycles de lancement, d'arrêt et de délai dépassé")
    func noPipeLeak() async throws {
        let serve = try FakeServe(answering)
        let silent = try FakeServe("""
            echo "obsbot-ai: ready"
            read order
            echo "$order" >> "$dir/orders"
            exec sleep 30
            """)
        let scheduler = FakeScheduler()
        let normal = runner(serve, scheduler: DispatchScheduler())
        let stuck = runner(silent, scheduler: scheduler)
        for _ in 0..<10 {
            #expect(await order(normal) == .success)
            normal.reset()
            #expect(await eventually { normal.isIdle })
        }
        for cycle in 1...10 {
            let outcome = Outcome()
            stuck.run(on: true) { outcome.value = $0 }
            // L'ordre doit être écrit pour que le délai de 5 s coure.
            #expect(await eventually { silent.orders.count == cycle })
            scheduler.advance(by: 30)
            #expect(outcome.value == .timeout)
            #expect(await eventually { stuck.isIdle })
        }
        await cleanUp(normal, serve)
        await cleanUp(stuck, silent)
        // Le système réutilise les numéros d'inode d'un tuyau fermé : la suite est donc sérialisée, pour
        // qu'aucun autre test n'en ouvre pendant le balayage.
        let recorded = Set(normal.recordedPipes).union(stuck.recordedPipes)
        // 20 utilitaires, 2 tuyaux chacun, 2 extrémités par tuyau.
        #expect(normal.recordedPipes.count + stuck.recordedPipes.count == 80)
        var leaked = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? [] {
            guard let descriptor = Int32(name) else { continue }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { continue }
            if recorded.contains(.init(device: info.st_dev, inode: info.st_ino)) {
                leaked += 1
            }
        }
        #expect(leaked == 0)
    }

    @Test("environment s'ajoute à l'environnement hérité : le SDK est donné à l'utilitaire (DYLD_LIBRARY_PATH en service)")
    func environment() async throws {
        // /bin/sh est protégé par SIP : dyld y retire les variables DYLD_*. La transmission est donc
        // vérifiée par une variable ordinaire ; DYLD_LIBRARY_PATH suit le même chemin.
        let serve = try FakeServe("""
            printf '%s|%s' "$PTZD_ESSAI" "${HOME:+hérité}" > "$dir/env"
            echo "obsbot-ai: ready"
            while read order; do echo "obsbot-ai: ok"; done
            """)
        let runner = runner(serve, scheduler: DispatchScheduler(), environment: ["DYLD_LIBRARY_PATH": "/sdk/dossier", "PTZD_ESSAI": "transmis"])
        #expect(await order(runner) == .success)
        #expect(try String(contentsOf: serve.directory.appending(path: "env"), encoding: .utf8) == "transmis|hérité")
        await cleanUp(runner, serve)
    }

    @Test("Les échecs donnent les motifs de l'app : caméra introuvable, erreur du SDK, délai, sortie inattendue, lancement")
    func failureMotives() async throws {
        func motive(_ result: AIResult?) -> String {
            guard let result else { return "?" }
            let message = AIFailureText.message(motive: result.userDescription)
            return AIFailureText.motive(in: message) ?? "?"
        }
        // Caméra introuvable : err 1 puis sortie 1.
        let missing = try FakeServe("echo \"obsbot-ai: err 1\"; exit 1")
        let missingRunner = runner(missing, scheduler: DispatchScheduler())
        #expect(motive(await order(missingRunner)) == AIFailureText.cameraNotFound)
        await cleanUp(missingRunner, missing)
        // Erreur du SDK : err 2.
        let failing = try FakeServe("""
            echo "obsbot-ai: ready"
            while read order; do echo "obsbot-ai: err 2"; done
            """)
        let failingRunner = runner(failing, scheduler: DispatchScheduler())
        #expect(motive(await order(failingRunner)) == AIFailureText.sdkError)
        await cleanUp(failingRunner, failing)
        // Sortie inattendue : le code de sortie suit le préfixe.
        let dying = try FakeServe("exit 5")
        let dyingRunner = runner(dying, scheduler: DispatchScheduler())
        #expect(motive(await order(dyingRunner)) == AIFailureText.unexpectedExitPrefix + "5")
        await cleanUp(dyingRunner, dying)
        // Délai dépassé : jamais de « ready ».
        let silent = try FakeServe("exec sleep 30")
        let silentRunner = runner(silent, scheduler: DispatchScheduler(), readyTimeout: 0.3)
        #expect(motive(await order(silentRunner)) == AIFailureText.timeout)
        await cleanUp(silentRunner, silent)
        // Lancement impossible : exécutable absent.
        let absent = ResidentAIRunner(executableURL: URL(fileURLWithPath: "/nonexistent/obsbot-ai"), scheduler: DispatchScheduler())
        #expect(motive(await order(absent)) == AIFailureText.launchFailed)
    }

    @Test("Exécutable absent : launchFailed")
    func launchFailure() async {
        let runner = ResidentAIRunner(
            executableURL: URL(fileURLWithPath: "/nonexistent/obsbot-ai"),
            scheduler: DispatchScheduler()
        )
        guard case .launchFailed? = await order(runner) else {
            Issue.record("launchFailed attendu")
            return
        }
    }

    // MARK: - Vie privée native (spec § 6.5 bis)

    @Test("Vie privée native : « privacy on » puis « privacy off » sont écrits tels quels sur l'entrée de l'utilitaire")
    func privacyOrders() async throws {
        let serve = try FakeServe(answering)
        let runner = runner(serve, scheduler: DispatchScheduler())
        let first = Outcome()
        runner.runPrivacy(on: true) { first.value = $0 }
        _ = await eventually { first.value != nil }
        #expect(first.value == .success)
        let second = Outcome()
        runner.runPrivacy(on: false) { second.value = $0 }
        _ = await eventually { second.value != nil }
        #expect(second.value == .success)
        #expect(await order(runner, on: false) == .success)
        #expect(serve.orders == ["privacy on", "privacy off", "off"])
        #expect(serve.starts.count == 1)
        await cleanUp(runner, serve)
    }

    @Test("Vie privée native : err 2 donne l'erreur du SDK, comme un ordre de suivi")
    func privacySDKError() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: ready"
            while read order; do echo "obsbot-ai: err 2"; done
            """)
        let runner = runner(serve, scheduler: DispatchScheduler())
        let outcome = Outcome()
        runner.runPrivacy(on: true) { outcome.value = $0 }
        _ = await eventually { outcome.value != nil }
        #expect(outcome.value == .sdkError)
        await cleanUp(runner, serve)
    }

    @Test("Un ordre de vie privée a 5 s pour répondre, comme un ordre de suivi (il rend la main en 0 ms, mesuré)")
    func privacyOrderTimeout() async throws {
        let serve = try FakeServe(Self.silentThenAnswering)
        let scheduler = FakeScheduler()
        let runner = runner(serve, scheduler: scheduler)
        let outcome = Outcome()
        runner.runPrivacy(on: true) { outcome.value = $0 }
        #expect(await eventually { serve.orders.count == 1 })
        scheduler.advance(by: 4.9)
        #expect(outcome.value == nil)
        scheduler.advance(by: 0.2)
        #expect(outcome.value == .timeout)
        await cleanUp(runner, serve)
    }

    @Test("privacy status : l'état et l'inclinaison (second témoin) se lisent tels quels, sur le même processus")
    func privacyStatus() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: ready"
            for reply in "privacy 84.9" "run 69.8" "run"; do
                read order
                echo "$order" >> "$dir/orders"
                echo "obsbot-ai: ok $reply"
            done
            while read order; do echo "obsbot-ai: ok"; done
            """)
        let runner = runner(serve, scheduler: DispatchScheduler())
        var readings: [PrivacyReading] = []
        for _ in 0..<3 {
            let outcome = ReadingOutcome()
            runner.readPrivacy { outcome.value = $0 }
            _ = await eventually { outcome.value != nil }
            readings.append(outcome.value ?? .failed(.timeout))
        }
        #expect(readings == [.state(.privacy, pitch: 84.9), .state(.run, pitch: 69.8), .state(.run, pitch: nil)])
        #expect(serve.orders == ["privacy status", "privacy status", "privacy status"])
        #expect(serve.starts.count == 1)
        await cleanUp(runner, serve)
    }

    @Test("privacy status : un mot inconnu (sleep compris) est un échec, jamais un état deviné ; err 3 : ordre inconnu")
    func privacyStatusUnreadable() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: ready"
            read order
            echo "obsbot-ai: ok flou"
            read order
            echo "obsbot-ai: ok sleep 12.0"
            read order
            echo "obsbot-ai: err 3"
            """)
        let runner = runner(serve, scheduler: DispatchScheduler())
        let first = ReadingOutcome()
        runner.readPrivacy { first.value = $0 }
        _ = await eventually { first.value != nil }
        #expect(first.value == .failed(.sdkError, pitch: nil))
        let second = ReadingOutcome()
        runner.readPrivacy { second.value = $0 }
        _ = await eventually { second.value != nil }
        #expect(second.value == .failed(.sdkError, pitch: 12))
        let third = ReadingOutcome()
        runner.readPrivacy { third.value = $0 }
        _ = await eventually { third.value != nil }
        #expect(third.value == .failed(.unknownOrder, pitch: nil))
        await cleanUp(runner, serve)
    }

    @Test("D : une lecture ratée (err 2, avec l'inclinaison) n'arrête pas l'utilitaire ; l'ordre suivant part sur la même session")
    func failedReadKeepsSession() async throws {
        let serve = try FakeServe("""
            echo "obsbot-ai: ready"
            read order
            echo "$order" >> "$dir/orders"
            echo "obsbot-ai: err 2 84.9"
            read order
            echo "$order" >> "$dir/orders"
            echo "obsbot-ai: err 2"
            while read order; do
                echo "$order" >> "$dir/orders"
                echo "obsbot-ai: ok"
            done
            """)
        let runner = runner(serve, scheduler: DispatchScheduler())
        let first = ReadingOutcome()
        runner.readPrivacy { first.value = $0 }
        _ = await eventually { first.value != nil }
        #expect(first.value == .failed(.sdkError, pitch: 84.9))
        let second = ReadingOutcome()
        runner.readPrivacy { second.value = $0 }
        _ = await eventually { second.value != nil }
        #expect(second.value == .failed(.sdkError, pitch: nil))
        #expect(await order(runner, on: false) == .success)
        #expect(serve.orders == ["privacy status", "privacy status", "off"])
        #expect(serve.starts.count == 1)
        await cleanUp(runner, serve)
    }

    @Test("privacy status a 5 s pour répondre, comme un ordre de suivi")
    func privacyStatusTimeout() async throws {
        let serve = try FakeServe(Self.silentThenAnswering)
        let scheduler = FakeScheduler()
        let runner = runner(serve, scheduler: scheduler)
        let outcome = ReadingOutcome()
        runner.readPrivacy { outcome.value = $0 }
        #expect(await eventually { serve.orders.count == 1 })
        scheduler.advance(by: 4.9)
        #expect(outcome.value == nil)
        scheduler.advance(by: 0.2)
        #expect(outcome.value == .failed(.timeout))
        await cleanUp(runner, serve)
    }

    @Test("L'utilitaire installé permet la vie privée native ; absent, non")
    func supportsNativePrivacy() throws {
        let serve = try FakeServe(answering)
        let present = runner(serve, scheduler: DispatchScheduler())
        #expect(present.supportsNativePrivacy)
        serve.remove()
        #expect(!present.supportsNativePrivacy)
        let absent = ResidentAIRunner(executableURL: URL(fileURLWithPath: "/nonexistent/obsbot-ai"), scheduler: DispatchScheduler())
        #expect(!absent.supportsNativePrivacy)
    }
}
