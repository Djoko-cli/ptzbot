import Testing
@testable import PTZCore

@MainActor
@Suite("Ordre de vie privée native")
struct NativePrivacyTests {
    let runner = FakeAIRunner()
    let scheduler = FakeScheduler()
    let log = LogRecorder()
    let gate = Gate()

    @MainActor
    final class Gate {
        var open = true
    }

    @MainActor
    final class Results {
        var values: [AIResult] = []
    }

    private func makeNative() -> NativePrivacy {
        let gate = gate
        return NativePrivacy(runner: runner, scheduler: scheduler, canRun: { gate.open }, log: log.sink)
    }

    @Test("Premier essai réussi : un seul ordre, résultat transmis")
    func firstAttemptSucceeds() {
        let native = makeNative()
        let results = Results()
        native.apply(on: true) { results.values.append($0) }
        #expect(native.isBusy)
        #expect(native.pendingOn == true)
        #expect(runner.privacyOrders == [true])
        runner.finishPrivacy(.success)
        #expect(results.values == [.success])
        #expect(!native.isBusy)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Échec puis second essai 3 s plus tard (dans les 10 s) : réussi")
    func secondAttemptAfterRetryDelay() {
        let native = makeNative()
        let results = Results()
        native.apply(on: false) { results.values.append($0) }
        runner.finishPrivacy(.timeout)
        #expect(results.values.isEmpty)
        #expect(native.isBusy)
        #expect(runner.privacyOrders == [false])
        scheduler.advance(by: NativePrivacy.retryDelay - 0.1)
        #expect(runner.privacyOrders == [false])
        scheduler.advance(by: 0.2)
        #expect(runner.privacyOrders == [false, false])
        #expect(NativePrivacy.retryDelay <= 10)
        runner.finishPrivacy(.success)
        #expect(results.values == [.success])
        #expect(log.lines.contains { $0.contains("nouvel essai") })
    }

    @Test("Deux échecs : l'échec du second est transmis, pas de troisième essai")
    func twoFailures() {
        let native = makeNative()
        let results = Results()
        native.apply(on: true) { results.values.append($0) }
        runner.finishPrivacy(.sdkError)
        scheduler.advance(by: NativePrivacy.retryDelay)
        runner.finishPrivacy(.cameraNotFound)
        #expect(results.values == [.cameraNotFound])
        #expect(!native.isBusy)
        scheduler.advance(by: 60)
        #expect(runner.privacyOrders == [true, true])
    }

    @Test("L'ordre attend que l'utilitaire soit libre, puis part à resume()")
    func waitsForGate() {
        gate.open = false
        let native = makeNative()
        let results = Results()
        native.apply(on: true) { results.values.append($0) }
        #expect(native.isBusy)
        #expect(runner.privacyOrders.isEmpty)
        native.resume()
        #expect(runner.privacyOrders.isEmpty)
        gate.open = true
        native.resume()
        #expect(runner.privacyOrders == [true])
        runner.finishPrivacy(.success)
        #expect(results.values == [.success])
    }

    @Test("Un ordre en cours : un autre ordre est ignoré")
    func busyIgnoresSecondOrder() {
        let native = makeNative()
        let results = Results()
        native.apply(on: true) { results.values.append($0) }
        native.apply(on: false) { results.values.append($0) }
        #expect(runner.privacyOrders == [true])
        runner.finishPrivacy(.success)
        #expect(results.values == [.success])
    }

    @Test("cancel : la réponse tardive et le second essai sont ignorés, sans rappel")
    func cancelIgnoresLateResults() {
        let native = makeNative()
        let results = Results()
        native.apply(on: true) { results.values.append($0) }
        runner.finishPrivacy(.timeout)
        native.cancel()
        scheduler.advance(by: 60)
        #expect(runner.privacyOrders == [true])
        #expect(!native.isBusy)

        native.apply(on: true) { results.values.append($0) }
        native.cancel()
        runner.finishPrivacy(.success)
        #expect(results.values.isEmpty)
    }

    @Test("isAvailable suit l'utilitaire")
    func availability() {
        let native = makeNative()
        #expect(!native.isAvailable)
        runner.nativePrivacyAvailable = true
        #expect(native.isAvailable)
    }
}
