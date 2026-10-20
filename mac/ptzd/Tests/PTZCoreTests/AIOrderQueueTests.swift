import Testing
@testable import PTZCore

/// La file d'ordres de l'utilitaire (spec § 6.5 bis) : l'utilitaire simulé refuse, comme le vrai, un ordre donné pendant
/// un autre ; la file ne lui en donne jamais deux à la fois.
@MainActor
@Suite("File d'ordres de l'utilitaire")
struct AIOrderQueueTests {
    let runner = FakeAIRunner()

    @Test("Trois ordres donnés ensemble : un à la fois, dans l'ordre, aucun refusé, chacun reçoit sa réponse")
    func oneAtATime() {
        let queue = AIOrderQueue(runner: runner)
        let results = QueueResults()
        queue.run(on: false) { results.values.append("off \($0)") }
        queue.runPrivacy(on: true) { results.values.append("privacy on \($0)") }
        queue.readPrivacy { results.values.append("status \($0)") }
        #expect(runner.inFlight == .tracking(false))
        #expect(queue.waiting == 2)
        runner.answer(.tracking(false))
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true), .sdkError)
        #expect(runner.inFlight == .status)
        runner.answer(.status)
        #expect(runner.inFlight == nil)
        #expect(runner.refused.isEmpty)
        #expect(results.values == ["off success", "privacy on sdkError", "status state(PTZCore.CameraRunState.run, pitch: nil)"])
    }

    @Test("L'exposition passe par la même file que la vie privée : jamais deux ordres ensemble (§ 6.11)")
    func exposureSharesTheQueue() {
        let queue = AIOrderQueue(runner: runner)
        let results = QueueResults()
        queue.readExposure { results.values.append("lu \($0)") }
        queue.runPrivacy(on: true) { results.values.append("privacy \($0)") }
        queue.runExposure(ExposureSetting(shutter: 31, auto: true)) { results.values.append("réglé \($0)") }
        #expect(runner.inFlight == .exposureStatus)
        #expect(queue.waiting == 2)
        runner.answer(.exposureStatus)
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true))
        #expect(runner.inFlight == .exposure(ExposureSetting(shutter: 31, auto: true)))
        runner.answer(.exposure(ExposureSetting(shutter: 31, auto: true)))
        #expect(runner.inFlight == nil)
        #expect(runner.refused.isEmpty)
        #expect(runner.exposure == ExposureSetting(shutter: 31, auto: true))
        #expect(results.values == ["lu setting(PTZCore.ExposureSetting(shutter: 31, auto: false))", "privacy success", "réglé success"])
    }

    @Test("Un ordre donné par un rappel part après ceux qui attendaient déjà")
    func orderFromCallbackQueuesBehind() {
        let queue = AIOrderQueue(runner: runner)
        queue.run(on: false) { _ in
            queue.readPrivacy { _ in }
        }
        queue.runPrivacy(on: true) { _ in }
        runner.answer(.tracking(false))
        #expect(runner.inFlight == .privacy(true))
        runner.answer(.privacy(true))
        #expect(runner.inFlight == .status)
        #expect(runner.refused.isEmpty)
    }

    @Test("reset : l'ordre en cours échoue, le suivant part sur l'utilitaire neuf")
    func resetFailsCurrentAndContinues() {
        let queue = AIOrderQueue(runner: runner)
        let results = QueueResults()
        queue.runPrivacy(on: true) { results.values.append("\($0)") }
        queue.readPrivacy { results.values.append("\($0)") }
        queue.reset()
        #expect(runner.resets == 1)
        #expect(results.values == [#"launchFailed("utilitaire réinitialisé")"#])
        #expect(runner.inFlight == .status)
    }

    @Test("Préparation et disponibilité passent à l'utilitaire")
    func forwards() {
        let queue = AIOrderQueue(runner: runner)
        queue.prewarm()
        #expect(runner.prewarms == 1)
        #expect(!queue.supportsNativePrivacy)
        runner.nativePrivacyAvailable = true
        #expect(queue.supportsNativePrivacy)
        // SDK prêt : une session ouverte, qui a déjà répondu.
        #expect(!queue.isReady)
        queue.run(on: false) { _ in }
        #expect(!queue.isReady)
        runner.answer(.tracking(false))
        #expect(queue.isReady)
    }
}

@MainActor
private final class QueueResults {
    var values: [String] = []
}
