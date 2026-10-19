import Testing
@testable import PTZCore

@MainActor
@Suite("Prise en main")
struct ControlTakerTests {
    let runner = FakeAIRunner()
    let scheduler = FakeScheduler()
    let log = LogRecorder()

    private func makeTaker(centerRunning: Bool = false) -> ControlTaker {
        ControlTaker(runner: runner, scheduler: scheduler, isObsbotCenterRunning: { centerRunning }, log: log.sink)
    }

    @Test("take coupe le suivi (off) et passe à taking, puis ready ; le suivi est alors off")
    func success() {
        let taker = makeTaker()
        #expect(taker.tracking == .unknown)
        taker.take()
        #expect(taker.state == .taking)
        #expect(runner.orders == [false])
        runner.finish(.success)
        #expect(taker.state == .ready)
        #expect(taker.tracking == .off)
    }

    @Test("Ordre explicite on : taking, puis idle et suivi on ; off : ready et suivi off")
    func explicitOrders() {
        let taker = makeTaker()
        let results = ResultBox()
        taker.setTracking(on: true) { results.values.append($0) }
        #expect(taker.state == .taking)
        #expect(runner.orders == [true])
        runner.finish(.success)
        #expect(taker.tracking == .on)
        #expect(taker.state == .idle)
        taker.setTracking(on: false) { results.values.append($0) }
        runner.finish(.success)
        #expect(taker.tracking == .off)
        #expect(taker.state == .ready)
        #expect(results.values == [.success, .success])
    }

    @Test("Ordre explicite échoué : pas de nouvel essai, rien ne change, le résultat est rendu et journalisé")
    func explicitFailure() {
        let taker = makeTaker()
        let results = ResultBox()
        taker.setTracking(on: true) { results.values.append($0) }
        runner.finish(.sdkError)
        #expect(taker.tracking == .unknown)
        #expect(taker.state == .idle)
        scheduler.advance(by: ControlTaker.retryDelay)
        #expect(runner.runCount == 1)
        #expect(results.values == [.sdkError])
        #expect(log.lines == ["obsbot-ai on a échoué : sdkError"])
    }

    @Test("Ordre explicite pendant une coupure : refusé sans rien lancer")
    func explicitDuringTake() {
        let taker = makeTaker()
        let results = ResultBox()
        taker.take()
        taker.setTracking(on: true) { results.values.append($0) }
        #expect(runner.runCount == 1)
        #expect(results.values == [.launchFailed("suivi IA déjà en cours de changement")])
    }

    @Test("forget : le suivi redevient inconnu")
    func forget() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.success)
        taker.forget()
        #expect(taker.tracking == .unknown)
    }

    @Test("Une demande pendant l'exécution n'en lance pas une seconde")
    func coalesces() {
        let taker = makeTaker()
        taker.take()
        taker.take()
        #expect(runner.runCount == 1)
    }

    @Test("Deux échecs : un nouvel essai après 3 s, puis failed, avec une ligne de journal chacun")
    func failure() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.timeout)
        #expect(taker.state == .taking)
        #expect(runner.runCount == 1)
        scheduler.advance(by: ControlTaker.retryDelay)
        #expect(runner.runCount == 2)
        runner.finish(.timeout)
        #expect(taker.state == .failed)
        #expect(log.lines.count == 2)
        scheduler.advance(by: 10)
        #expect(runner.runCount == 2)
    }

    @Test("Un échec suivi d'un succès donne ready")
    func retrySucceeds() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.unexpectedExit(6))
        scheduler.advance(by: ControlTaker.retryDelay)
        runner.finish(.success)
        #expect(taker.state == .ready)
        #expect(runner.runCount == 2)
    }

    @Test("Pendant l'attente du nouvel essai, une demande n'en lance pas d'autre")
    func coalescesDuringRetry() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.cameraNotFound)
        taker.take()
        scheduler.advance(by: ControlTaker.retryDelay)
        #expect(runner.runCount == 2)
    }

    @Test("Une nouvelle prise en main relance l'utilitaire")
    func retake() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.success)
        taker.take()
        #expect(runner.runCount == 2)
        #expect(taker.state == .taking)
    }

    @Test("OBSBOT Center ouvert : avertissement journalisé")
    func obsbotCenterWarning() {
        makeTaker(centerRunning: true).take()
        #expect(log.lines.first?.contains("OBSBOT Center") == true)
    }

    @Test("Coupure demandée pendant setTracking(on: true) réussie est lancée après")
    func cutPendingDuringExplicitOn() {
        let taker = makeTaker()
        let results = ResultBox()
        taker.setTracking(on: true) { results.values.append($0) }
        #expect(runner.orders == [true])
        taker.take()
        #expect(runner.runCount == 1)
        #expect(runner.orders == [true])
        runner.finish(.success)
        #expect(runner.orders == [true, false])
        #expect(runner.runCount == 2)
        runner.finish(.success)
        #expect(taker.tracking == .off)
        #expect(results.values == [.success])
    }

    @Test("Coupure demandée pendant setTracking(on: false) réussie n'est pas lancée")
    func noCutPendingAfterSuccessfulOff() {
        let taker = makeTaker()
        let results = ResultBox()
        taker.setTracking(on: false) { results.values.append($0) }
        #expect(runner.orders == [false])
        taker.take()
        #expect(runner.runCount == 1)
        #expect(runner.orders == [false])
        runner.finish(.success)
        #expect(runner.orders == [false])
        #expect(taker.tracking == .off)
        #expect(results.values == [.success])
    }

    @Test("reset pendant une coupure : abandonnée sans nouvel essai, état idle, le suivi garde son dernier état connu")
    func resetDuringCut() {
        let taker = makeTaker()
        taker.take()
        #expect(taker.state == .taking)
        taker.reset()
        #expect(runner.resets == 1)
        #expect(taker.state == .idle)
        #expect(taker.tracking == .unknown)
        scheduler.advance(by: 60)
        #expect(runner.runCount == 1)
        // Une nouvelle coupure repart normalement.
        taker.take()
        runner.finish(.success)
        #expect(taker.state == .ready)
    }

    @Test("reset pendant un nouvel essai en attente : l'essai n'a pas lieu")
    func resetCancelsRetry() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.sdkError)
        taker.reset()
        scheduler.advance(by: ControlTaker.retryDelay)
        #expect(runner.runCount == 1)
        #expect(taker.state == .idle)
    }

    @Test("reset pendant un ordre explicite : l'échec est rendu au demandeur, l'état a été remis")
    func resetDuringExplicitOrder() {
        let taker = makeTaker()
        let results = ResultBox()
        taker.setTracking(on: true) { results.values.append($0) }
        taker.reset()
        #expect(results.values == [.launchFailed("utilitaire réinitialisé")])
        #expect(taker.state == .idle)
        #expect(taker.tracking == .unknown)
    }
}

/// Résultats reçus par les rappels (tests).
@MainActor
final class ResultBox {
    var values: [AIResult] = []
}
