import Foundation
import NacelleProtocol
import Testing
@testable import PTZCore

/// L'exposition automatique (spec § 6.11), sur l'utilitaire simulé : jamais la vraie caméra.
@MainActor
@Suite("Exposition automatique")
struct ExposureReconcilerTests {
    let runner = FakeAIRunner()
    let store = MemoryStateStore()
    let log = LogRecorder()
    let errors = ClientErrorBox()

    private static let manual31 = ExposureSetting(shutter: 31, auto: false)
    private static let auto31 = ExposureSetting(shutter: 31, auto: true)

    init() {
        runner.nativePrivacyAvailable = true
    }

    private func makeReconciler() -> ExposureReconciler {
        let reconciler = ExposureReconciler(runner: runner, store: store, log: log.sink)
        reconciler.onClientError = { [errors] in errors.values.append(($0, $1, $2)) }
        return reconciler
    }

    /// Active et répond à tout : la lecture, puis le passage en automatique.
    private func activate(_ reconciler: ExposureReconciler) {
        #expect(reconciler.request(on: true, from: 1) == nil)
        runner.answer(.exposureStatus)
        runner.answer(.exposure(Self.auto31))
    }

    @Test("Activation : le réglage en place est lu et écrit dans state.json avant le passage en automatique")
    func activation() {
        let reconciler = makeReconciler()
        #expect(reconciler.published == .off)
        #expect(reconciler.request(on: true, from: 1) == nil)
        #expect(reconciler.published == .on)
        #expect(runner.inFlight == .exposureStatus)
        runner.answer(.exposureStatus)
        // L'origine est écrite avant l'ordre : un arrêt de ptzd ici ne la perd pas.
        #expect(runner.inFlight == .exposure(Self.auto31))
        #expect(store.state.autoExposure)
        #expect(store.state.exposureOrigin == Self.manual31)
        runner.answer(.exposure(Self.auto31))
        #expect(runner.inFlight == nil)
        #expect(runner.exposure == Self.auto31)
        #expect(runner.exposureOrders == [Self.auto31])
        #expect(errors.values.isEmpty)
        #expect(log.lines.contains { $0.contains("Exposition auto : réglage d'origine lu (obturation 31, manuel)") })
    }

    @Test("Désactivation : le réglage d'origine est remis tel quel, sans relire OBSBOT Center ; la ligne du journal le dit")
    func deactivationRestoresOrigin() {
        let reconciler = makeReconciler()
        activate(reconciler)
        // Le réglage a été changé dans OBSBOT Center entre-temps : on remet quand même l'ancien.
        runner.exposure = ExposureSetting(shutter: 90, auto: true)
        #expect(reconciler.request(on: false, from: 1) == nil)
        #expect(reconciler.published == .off)
        #expect(runner.inFlight == .exposure(Self.manual31))
        runner.answer(.exposure(Self.manual31))
        #expect(runner.exposure == Self.manual31)
        #expect(runner.exposureReads == 1)
        #expect(!store.state.autoExposure)
        #expect(store.state.exposureOrigin == nil)
        #expect(log.lines.contains { $0.contains("sans relire celui d'OBSBOT Center") })
        #expect(errors.values.isEmpty)
    }

    @Test("L'origine est celle de l'activation, quelle qu'elle soit (obturation 47, manuel)")
    func originIsWhateverWasRead() {
        runner.exposure = ExposureSetting(shutter: 47, auto: false)
        let reconciler = makeReconciler()
        _ = reconciler.request(on: true, from: 1)
        runner.answer(.exposureStatus)
        #expect(runner.inFlight == .exposure(ExposureSetting(shutter: 47, auto: true)))
        runner.answer(.exposure(ExposureSetting(shutter: 47, auto: true)))
        _ = reconciler.request(on: false, from: 1)
        runner.answer(.exposure(ExposureSetting(shutter: 47, auto: false)))
        #expect(runner.exposure == ExposureSetting(shutter: 47, auto: false))
    }

    @Test("Origine déjà automatique (réglée dans OBSBOT Center) : retenue telle quelle et remise telle quelle")
    func originAlreadyAuto() {
        runner.exposure = ExposureSetting(shutter: 31, auto: true)
        let reconciler = makeReconciler()
        _ = reconciler.request(on: true, from: 1)
        runner.answer(.exposureStatus)
        runner.answer(.exposure(Self.auto31))
        #expect(store.state.exposureOrigin == Self.auto31)
        _ = reconciler.request(on: false, from: 1)
        #expect(runner.inFlight == .exposure(Self.auto31))
        runner.answer(.exposure(Self.auto31))
        #expect(reconciler.published == .off)
        #expect(store.state.exposureOrigin == nil)
    }

    @Test("Sans SDK : demande refusée (uvcFailed), état « indisponible », aucun ordre")
    func noSDK() {
        runner.nativePrivacyAvailable = false
        let reconciler = makeReconciler()
        #expect(reconciler.published == .unavailable)
        let refusal = reconciler.request(on: true, from: 1)
        #expect(refusal?.code == .uvcFailed)
        #expect(refusal?.message == ExposureFailureText.noSDK)
        #expect(runner.received.isEmpty)
        #expect(!store.state.autoExposure)
    }

    @Test("Réglage d'origine illisible : activation abandonnée, rien n'a changé, le client est prévenu")
    func originUnreadable() {
        let reconciler = makeReconciler()
        _ = reconciler.request(on: true, from: 7)
        runner.answer(.exposureStatus, .sdkError)
        #expect(runner.inFlight == nil)
        #expect(runner.exposureOrders.isEmpty)
        #expect(reconciler.published == .off)
        #expect(!store.state.autoExposure)
        #expect(store.state.exposureOrigin == nil)
        #expect(errors.values.count == 1)
        #expect(errors.values.first?.0 == 7)
        #expect(errors.values.first?.1 == .uvcFailed)
        #expect(errors.values.first?.2 == ExposureFailureText.readFailed)
    }

    @Test("Passage en automatique refusé par la caméra : « désactivé », origine effacée, uvcFailed")
    func activationRefused() {
        let reconciler = makeReconciler()
        _ = reconciler.request(on: true, from: 7)
        runner.answer(.exposureStatus)
        runner.answer(.exposure(Self.auto31), .sdkError)
        #expect(runner.inFlight == nil)
        #expect(reconciler.published == .off)
        #expect(!store.state.autoExposure)
        #expect(store.state.exposureOrigin == nil)
        #expect(errors.values.map(\.2) == [ExposureFailureText.activateFailed])
    }

    @Test("Réponse perdue à l'activation (délai dépassé) : la caméra a peut-être changé, le retour est refait, sans client")
    func activationLostReply() {
        let reconciler = makeReconciler()
        _ = reconciler.request(on: true, from: 7)
        runner.answer(.exposureStatus)
        runner.lose(.exposure(Self.auto31))
        // L'ordre a agi (la réponse seule s'est perdue) : le retour au réglage d'origine part tout seul.
        #expect(runner.inFlight == .exposure(Self.manual31))
        #expect(reconciler.published == .off)
        #expect(errors.values.map(\.2) == [ExposureFailureText.activateFailed])
        runner.answer(.exposure(Self.manual31))
        #expect(runner.exposure == Self.manual31)
        #expect(store.state.exposureOrigin == nil)
        #expect(errors.values.count == 1)
    }

    @Test("Retour raté : l'interrupteur redit « activé » (la caméra est restée en automatique), origine gardée ; une demande retente")
    func deactivationFailure() {
        let reconciler = makeReconciler()
        activate(reconciler)
        _ = reconciler.request(on: false, from: 7)
        runner.answer(.exposure(Self.manual31), .sdkError)
        #expect(reconciler.published == .on)
        #expect(store.state.autoExposure)
        #expect(store.state.exposureOrigin == Self.manual31)
        #expect(errors.values.map(\.2) == [ExposureFailureText.deactivateFailed])
        #expect(errors.values.first?.0 == 7)
        #expect(runner.inFlight == nil)
        // Une nouvelle demande retente le retour.
        _ = reconciler.request(on: false, from: 7)
        runner.answer(.exposure(Self.manual31))
        #expect(reconciler.published == .off)
        #expect(runner.exposure == Self.manual31)
        #expect(store.state.exposureOrigin == nil)
    }

    @Test("Désactivation demandée pendant l'activation : la séquence finit son étape puis repart vers le dernier choix")
    func lastChoiceWins() {
        let reconciler = makeReconciler()
        _ = reconciler.request(on: true, from: 1)
        runner.answer(.exposureStatus)
        _ = reconciler.request(on: false, from: 1)
        #expect(reconciler.published == .off)
        // L'ordre en cours n'est pas refusé ni croisé.
        #expect(runner.inFlight == .exposure(Self.auto31))
        runner.answer(.exposure(Self.auto31))
        #expect(runner.inFlight == .exposure(Self.manual31))
        runner.answer(.exposure(Self.manual31))
        #expect(runner.inFlight == nil)
        #expect(runner.refused.isEmpty)
        #expect(runner.exposure == Self.manual31)
        #expect(reconciler.published == .off)
        #expect(store.state.exposureOrigin == nil)
    }

    @Test("Deux demandes d'activation de suite : une seule lecture, un seul passage en automatique")
    func repeatedActivation() {
        let reconciler = makeReconciler()
        _ = reconciler.request(on: true, from: 1)
        _ = reconciler.request(on: true, from: 2)
        runner.answer(.exposureStatus)
        runner.answer(.exposure(Self.auto31))
        #expect(runner.inFlight == nil)
        #expect(runner.exposureReads == 1)
        #expect(runner.exposureOrders == [Self.auto31])
        // Déjà activée : une demande de plus ne fait rien.
        _ = reconciler.request(on: true, from: 3)
        #expect(runner.inFlight == nil)
        #expect(runner.exposureOrders == [Self.auto31])
        #expect(errors.values.isEmpty)
    }

    @Test("Redémarrage de ptzd : le choix et l'origine sont relus de state.json, et réappliqués sans relire le réglage")
    func reapplyAtStartup() {
        store.state = PersistedState(privacy: false, saved: nil, autoExposure: true, exposureOrigin: Self.manual31)
        runner.exposure = ExposureSetting(shutter: 31, auto: false)
        let reconciler = makeReconciler()
        #expect(reconciler.published == .on)
        #expect(runner.received.isEmpty)
        reconciler.reapply(reason: "démarrage")
        #expect(runner.inFlight == .exposure(Self.auto31))
        runner.answer(.exposure(Self.auto31))
        #expect(runner.exposureReads == 0)
        #expect(runner.exposure == Self.auto31)
        #expect(store.state.exposureOrigin == Self.manual31)
        // La désactivation remet l'origine d'avant le redémarrage.
        _ = reconciler.request(on: false, from: 1)
        runner.answer(.exposure(Self.manual31))
        #expect(runner.exposure == Self.manual31)
    }

    @Test("Rebranchement : la caméra a oublié le mode automatique, il est réappliqué ; la réponse d'avant est écartée")
    func reapplyAfterReplug() {
        let reconciler = makeReconciler()
        activate(reconciler)
        runner.powerCycle()
        #expect(runner.exposure == Self.manual31)
        reconciler.abandonSession()
        reconciler.reapply(reason: "caméra branchée")
        #expect(runner.inFlight == .exposure(Self.auto31))
        runner.answer(.exposure(Self.auto31))
        #expect(runner.exposure == Self.auto31)
        #expect(runner.exposureReads == 1)
        #expect(errors.values.isEmpty)
    }

    @Test("Caméra débranchée pendant un ordre : sa réponse est écartée ; la réapplication au branchement reprend")
    func staleAnswerIgnored() {
        let reconciler = makeReconciler()
        _ = reconciler.request(on: true, from: 1)
        runner.answer(.exposureStatus)
        // Débranchement : l'ordre en cours échoue avec l'utilitaire, la séquence est abandonnée.
        reconciler.abandonSession()
        runner.reset()
        #expect(errors.values.isEmpty)
        #expect(reconciler.published == .on)
        reconciler.reapply(reason: "caméra branchée")
        #expect(runner.inFlight == .exposure(Self.auto31))
        runner.answer(.exposure(Self.auto31))
        #expect(runner.exposure == Self.auto31)
        #expect(store.state.exposureOrigin == Self.manual31)
    }

    @Test("Réapplication ratée : journalisée, aucun client prévenu, l'état voulu reste « activé » et la suivante réessaie")
    func reapplyFailureRetries() {
        store.state = PersistedState(privacy: false, saved: nil, autoExposure: true, exposureOrigin: Self.manual31)
        let reconciler = makeReconciler()
        reconciler.reapply(reason: "démarrage")
        runner.answer(.exposure(Self.auto31), .sdkError)
        #expect(errors.values.isEmpty)
        #expect(log.lines.contains { $0.contains("passage en automatique refusé") })
        #expect(reconciler.published == .on)
        #expect(store.state.autoExposure)
        #expect(store.state.exposureOrigin == Self.manual31)
        #expect(runner.inFlight == nil)
        // Le rebranchement suivant réessaie.
        reconciler.abandonSession()
        reconciler.reapply(reason: "caméra branchée")
        runner.answer(.exposure(Self.auto31))
        #expect(runner.exposure == Self.auto31)
    }

    @Test("Sans SDK au démarrage, l'état voulu est gardé ; appliqué dès que le SDK arrive (aiUpdated)")
    func appliedWhenSDKArrives() {
        store.state = PersistedState(privacy: false, saved: nil, autoExposure: true, exposureOrigin: Self.manual31)
        runner.nativePrivacyAvailable = false
        let reconciler = makeReconciler()
        reconciler.reapply(reason: "démarrage")
        #expect(runner.received.isEmpty)
        #expect(reconciler.published == .unavailable)
        #expect(store.state.autoExposure)
        runner.nativePrivacyAvailable = true
        reconciler.utilityUpdated()
        #expect(reconciler.published == .on)
        #expect(runner.inFlight == .exposure(Self.auto31))
    }

    @Test("Origine inconnue (state.json abîmé) : la réapplication reprend l'obturation, la désactivation la remet en manuel")
    func lostOrigin() {
        store.state = PersistedState(privacy: false, saved: nil, autoExposure: true, exposureOrigin: nil)
        runner.exposure = ExposureSetting(shutter: 55, auto: false)
        let reconciler = makeReconciler()
        reconciler.reapply(reason: "démarrage")
        #expect(runner.inFlight == .exposureStatus)
        runner.answer(.exposureStatus)
        #expect(runner.inFlight == .exposure(ExposureSetting(shutter: 55, auto: true)))
        runner.answer(.exposure(ExposureSetting(shutter: 55, auto: true)))
        #expect(store.state.exposureOrigin == nil)
        #expect(log.lines.contains { $0.contains("réglage d'origine inconnu") })
        _ = reconciler.request(on: false, from: 1)
        #expect(runner.inFlight == .exposureStatus)
        runner.answer(.exposureStatus)
        #expect(runner.inFlight == .exposure(ExposureSetting(shutter: 55, auto: false)))
        runner.answer(.exposure(ExposureSetting(shutter: 55, auto: false)))
        #expect(runner.exposure == ExposureSetting(shutter: 55, auto: false))
        #expect(!store.state.autoExposure)
        #expect(errors.values.isEmpty)
    }

    @Test("obsbot-ai d'avant l'exposition (ordre inconnu) : « indisponible » jusqu'à aiUpdated, puis réessayé")
    func unknownOrder() {
        let reconciler = makeReconciler()
        _ = reconciler.request(on: true, from: 7)
        runner.answer(.exposureStatus, .unknownOrder)
        #expect(reconciler.published == .unavailable)
        #expect(errors.values.map(\.2) == [ExposureFailureText.needsUpdate])
        #expect(reconciler.request(on: true, from: 7)?.message == ExposureFailureText.needsUpdate)
        reconciler.utilityUpdated()
        #expect(reconciler.published == .off)
        #expect(reconciler.request(on: true, from: 7) == nil)
        #expect(runner.inFlight == .exposureStatus)
    }

    @Test("Un state.json d'avant l'exposition : désactivée, aucun ordre à la réapplication")
    func legacyState() {
        store.state = PersistedState(privacy: true, saved: nil)
        let reconciler = makeReconciler()
        #expect(reconciler.published == .off)
        reconciler.reapply(reason: "démarrage")
        #expect(runner.received.isEmpty)
    }

    @Test("Un retour resté à faire (origine retenue, plus rien de voulu) est refait à la réapplication")
    func pendingRestoreIsRedone() {
        store.state = PersistedState(privacy: false, saved: nil, autoExposure: false, exposureOrigin: Self.manual31)
        runner.exposure = Self.auto31
        let reconciler = makeReconciler()
        #expect(reconciler.published == .off)
        reconciler.reapply(reason: "démarrage")
        #expect(runner.inFlight == .exposure(Self.manual31))
        runner.answer(.exposure(Self.manual31))
        #expect(runner.exposure == Self.manual31)
        #expect(store.state.exposureOrigin == nil)
    }

    @Test("Une erreur d'écriture de state.json est journalisée et n'empêche pas de régler la caméra")
    func saveFailure() {
        store.failSaves = true
        let reconciler = makeReconciler()
        activate(reconciler)
        #expect(runner.exposure == Self.auto31)
        #expect(log.lines.contains { $0.contains("Enregistrement de state.json impossible") })
    }
}
