import Foundation
import NacelleProtocol

/// L'exposition automatique de la caméra (spec § 6.11) : un interrupteur « activé », la caméra en exposition automatique
/// continue ; « désactivé », retour **exact** au réglage lu juste avant l'activation.
///
/// Tout passe par l'utilitaire (`obsbot-ai`), par la même file que la vie privée et le suivi IA : un ordre à la fois,
/// jamais croisés. L'activation lit le réglage en place (le **réglage d'origine**), l'écrit dans state.json, puis passe en
/// automatique ; la désactivation le remet, sans relire celui d'OBSBOT Center. Le choix voulu et l'origine survivent à un
/// redémarrage de ptzd, et sont réappliqués au démarrage, au rebranchement de la caméra et après `aiUpdated`.
///
/// Le réglage d'origine écrit dans state.json est aussi le témoin « un retour reste à faire » : il n'est effacé qu'après un
/// retour réussi, ou après un refus certain de la caméra (rien n'a changé).
///
/// **Aucun ordre à la caméra tant que la vie privée est voulue** (`canOrder`, spec § 6.11) : une caméra en mode natif dort,
/// et rien ne dit qu'un ordre d'exposition ne la réveillerait pas. L'interrupteur reste utilisable : le choix est retenu
/// et publié, mais ni lecture ni réglage ne partent. À la sortie de la vie privée, `privacyEnded` réapplique le choix (la
/// caméra a pu reprendre son propre réglage en se réveillant).
@MainActor
public final class ExposureReconciler {
    private let runner: any AIRunner
    private let store: any StateStore
    private let log: LogSink

    /// Le dernier choix de l'utilisateur (ou celui retenu par state.json).
    private var wanted: Bool
    /// Le réglage lu avant l'activation, à remettre à la désactivation.
    private var origin: ExposureSetting?
    /// state.json voulait l'exposition automatique mais sans réglage d'origine (fichier abîmé) : la réapplication ne
    /// peut relire que l'obturation, et la désactivation remet cette obturation en manuel.
    private var originLost: Bool
    /// La caméra est en automatique par notre ordre, confirmé dans la session en cours de l'utilitaire. Retombe à faux à
    /// chaque nouvelle session (branchement, mise à jour) : l'ordre est alors réapplicable.
    private var applied = false
    /// Un ordre est en cours : les demandes suivantes attendent la fin de l'étape.
    private var busy = false
    /// obsbot-ai est d'avant l'exposition automatique (« ordre inconnu ») : elle attend sa recompilation.
    private var updating = false
    /// Le client qui a demandé la séquence en cours (à prévenir d'un échec) ; nil pour une réapplication.
    private var requester: ClientID?
    /// Change à chaque session neuve de l'utilitaire : la réponse d'un ordre donné à une session qui n'existe plus est
    /// écartée.
    private var ticket = 0

    /// Un ordre peut partir à la caméra : faux tant que la vie privée est voulue ou en cours (fournie par le contrôleur).
    public var canOrder: () -> Bool = { true }
    /// Jette les ordres d'exposition encore en file, à l'abandon d'une session (fournie par le contrôleur).
    public var discardQueuedOrders: () -> Void = {}

    /// Appelé quand l'état publié a pu changer.
    public var onChange: (() -> Void)?
    /// Erreur à transmettre à un client dont la demande a échoué.
    public var onClientError: ((ClientID, ErrorCode, String) -> Void)?

    public init(runner: any AIRunner, store: any StateStore, log: @escaping LogSink) {
        self.runner = runner
        self.store = store
        self.log = log
        let persisted = store.load()
        wanted = persisted.autoExposure
        origin = persisted.exposureOrigin
        originLost = persisted.autoExposure && persisted.exposureOrigin == nil
    }

    /// L'état publié : le choix voulu dès la demande (sans attendre la caméra), `unavailable` quand ptzd ne peut pas tenir
    /// l'ordre (pas d'utilitaire, ou utilitaire d'avant l'exposition).
    public var published: AutoExposure {
        if !runner.supportsNativePrivacy || updating {
            return .unavailable
        }
        return wanted ? .on : .off
    }

    // MARK: - Événements

    /// Le message `autoExposure` d'un client, caméra présente. Rend l'erreur à lui renvoyer tout de suite, ou nil ; un échec
    /// plus tardif passe par `onClientError`. Un choix donné pendant une étape change l'état voulu, et la séquence repart
    /// vers le dernier choix à la fin de l'étape.
    public func request(on: Bool, from client: ClientID) -> (code: ErrorCode, message: String)? {
        guard runner.supportsNativePrivacy else {
            log("Exposition auto : demande refusée, pas d'utilitaire obsbot-ai (SDK absent).")
            return (.uvcFailed, ExposureFailureText.noSDK)
        }
        guard !updating else {
            log("Exposition auto : demande refusée, obsbot-ai n'est pas à jour.")
            return (.uvcFailed, ExposureFailureText.needsUpdate)
        }
        log("Exposition auto : \(on ? "activation" : "désactivation") demandée.")
        if !canOrder() {
            log("Exposition auto : la vie privée est voulue, le choix est retenu et l'ordre part à sa sortie.")
        }
        if on, !wanted {
            // Une activation neuve relit le réglage en place : il devient l'origine.
            originLost = false
        }
        wanted = on
        requester = client
        persist()
        onChange?()
        advance()
        return nil
    }

    /// La caméra a été branchée ou débranchée, ou l'utilitaire a été recompilé : la session de l'utilitaire ne vaut plus.
    /// L'ordre en cours est abandonné ; sa réponse sera écartée.
    public func abandonSession() {
        ticket += 1
        busy = false
        applied = false
        requester = nil
        // Un ordre mis en file avant cette session ne partira pas : il serait donné à une session qui n'existe plus.
        discardQueuedOrders()
    }

    /// Caméra présente (démarrage de ptzd, branchement) : l'exposition automatique voulue est réappliquée, la caméra a pu
    /// l'oublier ; un retour resté à faire (origine retenue, plus rien de voulu) est refait.
    public func reapply(reason: String) {
        guard wanted || origin != nil || originLost else { return }
        guard canOrder() else {
            log("Exposition auto : réapplication (\(reason)) reportée à la sortie de la vie privée.")
            return
        }
        log("Exposition auto : réapplication (\(reason)).")
        advance()
        onChange?()
    }

    /// La vie privée vient de finir, la caméra lue éveillée : l'exposition voulue est réappliquée. La caméra a pu reprendre
    /// son propre réglage en se réveillant : le mode automatique n'est plus tenu pour acquis.
    public func privacyEnded() {
        applied = false
        reapply(reason: "sortie de la vie privée")
    }

    /// PTZBot a recompilé ou réinstallé obsbot-ai (`aiUpdated`) : l'utilitaire est celui d'après. L'indicateur « en cours de
    /// mise à jour » retombe dans tous les cas ; l'ordre est réessayé si la caméra est là, sinon au branchement.
    public func utilityUpdated(cameraPresent: Bool) {
        updating = false
        abandonSession()
        if cameraPresent {
            reapply(reason: "obsbot-ai mis à jour")
        }
        onChange?()
    }

    // MARK: - Séquences

    /// Fait le pas suivant vers l'état voulu, s'il n'y en a pas un en cours. Sans ordre à donner, personne n'attend plus de
    /// réponse : le demandeur est oublié.
    private func advance() {
        guard !busy else { return }
        guard runner.supportsNativePrivacy, !updating else {
            requester = nil
            return
        }
        // Vie privée voulue : le choix est retenu, aucun ordre ne part ; le demandeur attend la sortie.
        guard canOrder() else { return }
        if wanted, !applied {
            activate()
        } else if !wanted, origin != nil || originLost {
            restore()
        } else {
            requester = nil
        }
    }

    /// Activation : lire le réglage d'origine et l'écrire dans state.json **avant** de passer en automatique, pour qu'un
    /// arrêt de ptzd au milieu ne perde jamais l'origine.
    private func activate() {
        busy = true
        let session = ticket
        let client = take()
        if let origin {
            log("Exposition auto : réglage d'origine déjà retenu (\(Self.text(origin))).")
            applyAuto(shutter: origin.shutter, session: session, client: client)
            return
        }
        log("Exposition auto : lecture du réglage en place.")
        runner.readExposure { [weak self] reading in
            guard let self, session == ticket else { return }
            switch reading {
            case let .failed(result):
                log("Exposition auto : réglage en place illisible (\(result.userDescription)), activation abandonnée.")
                noteUpdating(result)
                busy = false
                if client != nil {
                    // Rien n'a changé sur la caméra : le choix voulu revient à « désactivé ». Une réapplication garde le
                    // sien, la suivante réessaiera.
                    wanted = false
                    persist()
                }
                activationFailed(client, text: result == .unknownOrder ? ExposureFailureText.needsUpdate : ExposureFailureText.readFailed)
            case let .setting(setting):
                guard wanted else {
                    // Désactivation demandée pendant la lecture : la caméra n'a pas bougé, elle ne passera pas en
                    // automatique pour rien (un creux d'image d'une seconde). Rien n'a été écrit, l'origine n'a pas servi.
                    log("Exposition auto : désactivation demandée pendant la lecture, la caméra reste telle quelle.")
                    busy = false
                    onChange?()
                    advance()
                    return
                }
                guard canOrder() else {
                    // La vie privée est voulue depuis l'ordre de lecture : rien d'autre ne part. La lecture est refaite à la
                    // sortie (rien n'a été écrit).
                    log("Exposition auto : vie privée voulue pendant la lecture, le passage en automatique attend sa sortie.")
                    busy = false
                    requester = requester ?? client
                    return
                }
                if originLost {
                    // Fichier abîmé : l'origine n'est pas connue, seule l'obturation en place est reprise.
                    log("Exposition auto : réglage d'origine inconnu, obturation \(setting.shutter) reprise.")
                } else {
                    log("Exposition auto : réglage d'origine lu (\(Self.text(setting))).")
                    origin = setting
                    persist()
                }
                applyAuto(shutter: setting.shutter, session: session, client: client)
            }
        }
    }

    private func applyAuto(shutter: Int, session: Int, client: ClientID?) {
        runner.runExposure(ExposureSetting(shutter: shutter, auto: true)) { [weak self] result in
            guard let self, session == ticket else { return }
            busy = false
            guard result == .success else {
                log("Exposition auto : passage en automatique refusé (\(result.userDescription)).")
                noteUpdating(result)
                guard client != nil else {
                    // Réapplication (démarrage, branchement, mise à jour) : le choix voulu reste, la suivante réessaiera.
                    onChange?()
                    return
                }
                // Refus certain : rien n'a changé, l'origine ne sert plus. Réponse perdue ou utilitaire réinitialisé : la
                // caméra a peut-être changé, l'origine reste et le retour sera refait (ci-dessous).
                if Self.isDefinitiveRefusal(result) {
                    origin = nil
                    originLost = false
                }
                wanted = false
                persist()
                activationFailed(client, text: result == .unknownOrder ? ExposureFailureText.needsUpdate : ExposureFailureText.activateFailed)
                return
            }
            applied = true
            log("Exposition auto : automatique en service.")
            persist()
            onChange?()
            advance()
        }
    }

    /// Désactivation : remet le réglage d'origine, sans relire celui d'OBSBOT Center.
    private func restore() {
        busy = true
        let session = ticket
        let client = take()
        if let origin {
            log("Exposition auto : retour au réglage d'origine (\(Self.text(origin))), sans relire celui d'OBSBOT Center.")
            applyRestore(origin, session: session, client: client)
            return
        }
        // Origine inconnue (fichier abîmé) : l'obturation en place est remise en manuel.
        log("Exposition auto : réglage d'origine inconnu, retour en manuel à l'obturation en place.")
        runner.readExposure { [weak self] reading in
            guard let self, session == ticket else { return }
            switch reading {
            case let .failed(result):
                busy = false
                log("Exposition auto : réglage en place illisible (\(result.userDescription)), retour abandonné.")
                noteUpdating(result)
                restoreFailed(client, text: result == .unknownOrder ? ExposureFailureText.needsUpdate : ExposureFailureText.deactivateFailed)
            case let .setting(setting):
                guard canOrder() else {
                    log("Exposition auto : vie privée voulue pendant la lecture, le retour attend sa sortie.")
                    busy = false
                    requester = requester ?? client
                    return
                }
                applyRestore(ExposureSetting(shutter: setting.shutter, auto: false), session: session, client: client)
            }
        }
    }

    private func applyRestore(_ setting: ExposureSetting, session: Int, client: ClientID?) {
        runner.runExposure(setting) { [weak self] result in
            guard let self, session == ticket else { return }
            busy = false
            guard result == .success else {
                log("Exposition auto : retour refusé (\(result.userDescription)), la caméra est peut-être restée en automatique.")
                noteUpdating(result)
                restoreFailed(client, text: result == .unknownOrder ? ExposureFailureText.needsUpdate : ExposureFailureText.deactivateFailed)
                return
            }
            origin = nil
            originLost = false
            applied = false
            log("Exposition auto : retour au réglage d'origine fait.")
            persist()
            onChange?()
            advance()
        }
    }

    // MARK: - Échecs

    /// Activation ratée : l'état voulu revient à « désactivé » (déjà fait par l'appelant), le client est prévenu. Si l'état
    /// voulu a été changé entre-temps, ou si un retour reste à faire (origine retenue), la séquence continue.
    private func activationFailed(_ client: ClientID?, text: String) {
        if let client {
            onClientError?(client, .uvcFailed, text)
        }
        onChange?()
        if !wanted, origin != nil {
            advance()
        }
    }

    /// Retour raté : la caméra est restée en automatique. Pour une demande d'un client, l'état voulu revient à « activé »
    /// (l'interrupteur dit ce que fait la caméra) et le client est prévenu ; une nouvelle demande retente. Sans client
    /// (suite d'un échec, réapplication), l'état voulu reste « désactivé » et le retour reste à faire.
    private func restoreFailed(_ client: ClientID?, text: String) {
        if let client {
            wanted = true
            applied = true
            persist()
            onClientError?(client, .uvcFailed, text)
        }
        onChange?()
    }

    /// Un « ordre inconnu » rend l'exposition indisponible jusqu'à `aiUpdated` (raison de la vie privée : `updating`).
    private func noteUpdating(_ result: AIResult) {
        if result == .unknownOrder {
            updating = true
        }
    }

    /// Le refus vient de la caméra ou du SDK : l'ordre n'a pas agi. Un délai dépassé, un utilitaire réinitialisé ou mort
    /// laissent un doute.
    private static func isDefinitiveRefusal(_ result: AIResult) -> Bool {
        switch result {
        case .sdkError, .cameraNotFound, .unknownOrder: true
        case .success, .timeout, .launchFailed, .unexpectedExit: false
        }
    }

    // MARK: - Utilitaires

    private func take() -> ClientID? {
        defer { requester = nil }
        return requester
    }

    /// Une erreur d'écriture n'empêche pas de régler la caméra : on la journalise.
    private func persist() {
        var state = store.load()
        // « Voulu » n'est écrit qu'avec son origine (ou si l'origine est déjà perdue) : un arrêt de ptzd entre la demande et
        // la lecture du réglage en place ne doit pas laisser un « voulu » sans origine, dont le retour ne serait pas exact.
        // Le choix en attente reste en mémoire et publié.
        state.autoExposure = wanted && (origin != nil || originLost)
        state.exposureOrigin = origin
        do {
            try store.save(state)
        } catch {
            log("Enregistrement de state.json impossible : \(error)")
        }
    }

    private static func text(_ setting: ExposureSetting) -> String {
        "obturation \(setting.shutter), \(setting.auto ? "automatique" : "manuel")"
    }
}
