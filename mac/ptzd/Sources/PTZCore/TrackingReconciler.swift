import Foundation
import NacelleProtocol

/// Le suivi IA retenu et relu (spec § 6.4 bis) : un **choix voulu**, gardé dans state.json, que ptzd réapplique quand la
/// caméra a pu l'oublier, et un **état réel** relu par l'utilitaire (`tracking status`, champ `tiny.ai_mode` du SDK).
///
/// - **Le choix** : l'interrupteur des apps (ordre réussi) l'active ou le coupe ; le joystick le coupe (premier
///   mouvement) ; une relecture qui trouve le suivi allumé alors qu'il est voulu coupé (geste sur la caméra, caméra qui
///   démarre en suivi) l'adopte. **La vie privée ne le change pas** : elle coupe le suivi à l'entrée (`ControlTaker`), et
///   il reprend à sa sortie, une fois la position rétablie.
/// - **La réapplication** du choix « activé » (`on`) : au branchement de la caméra (et donc au démarrage de ptzd caméra
///   présente), au réveil du Mac, à la sortie de la vie privée et après `aiUpdated`. Un choix « coupé » n'envoie rien :
///   la relecture qui suit le confirme. Un échec : un nouvel essai après `ControlTaker.retryDelay`, puis la relecture
///   périodique.
/// - **La relecture** de l'état réel : après chaque réapplication, puis toutes les `rereadInterval` secondes, tant que la
///   caméra est là et l'utilitaire gardé chaud. Lu coupé alors qu'il est voulu : relancé (une fois par relecture
///   périodique au plus). Lu `switching` : relu un peu plus tard, sans rien conclure. L'état publié aux apps suit la
///   dernière lecture. Un utilitaire d'avant cet ordre (« ordre inconnu ») : plus de relecture jusqu'à `aiUpdated`.
/// - **Jamais pendant la vie privée** (voulue, en cours, ou caméra peut-être en mode natif : `canOrder`), ni pendant un
///   ordre de suivi (coupure, ordre des apps), ni juste après (la caméra bascule encore). Tout passe par la file de
///   l'utilitaire, au rang des ordres de fond : derrière la vie privée, dont l'entrée ne les attend jamais (repli), et
///   avec une condition relue au moment de partir.
@MainActor
public final class TrackingReconciler {
    /// Relecture lente de l'état réel : un suivi perdu (veille, caméra redémarrée) est relancé au plus tard après ce délai.
    public static let rereadInterval: TimeInterval = 30
    /// Après un ordre de suivi, la caméra bascule encore : `switching` pendant environ 0,5 s, `on` dès 0,5 s (essai
    /// témoin du 28/10). Aucune lecture avant ce délai, ni après un `switching`.
    public static let settleDelay: TimeInterval = 2

    private enum Step {
        case idle
        /// Une relance de fond, jusqu'à sa réponse.
        case resuming
        /// Une lecture du mode réel, jusqu'à sa réponse.
        case reading
    }

    private let control: ControlTaker
    private let queue: AIOrderQueue
    private let scheduler: any Scheduler
    private let store: any StateStore
    private let log: LogSink

    /// Le choix voulu (state.json `aiTracking`).
    public private(set) var wanted: Bool
    /// L'utilitaire ne connaît pas `tracking status` : plus de relecture jusqu'à `aiUpdated`.
    private var readsUnsupported = false
    private var step: Step = .idle
    /// Change à chaque session abandonnée (branchement, réveil, mise à jour, joystick) : la réponse d'un ordre donné avant
    /// est écartée, et un ordre encore en file n'est pas envoyé.
    private var ticket = 0
    /// La prochaine relecture, ou le nouvel essai d'une relance.
    private var timer: (any Cancellable)?
    /// La relance en cours est déjà un nouvel essai.
    private var retried = false
    /// La dernière relance a réussi : la lecture qui suit la confirme, et ne relance pas si elle lit encore « coupé ».
    private var confirming = false
    /// Une réapplication est arrivée pendant un ordre de suivi : elle part à la fin de cet ordre.
    private var deferred: String?

    /// Un ordre de suivi peut partir à la caméra : caméra présente, ni vie privée voulue ou en cours, ni caméra peut-être
    /// en mode natif (fourni par le contrôleur).
    public var canOrder: () -> Bool = { true }

    public init(control: ControlTaker, queue: AIOrderQueue, scheduler: any Scheduler, store: any StateStore, log: @escaping LogSink) {
        self.control = control
        self.queue = queue
        self.scheduler = scheduler
        self.store = store
        self.log = log
        wanted = store.load().aiTracking
    }

    // MARK: - Le choix

    /// Un ordre des apps a réussi : il devient le choix retenu.
    public func userChose(on: Bool) {
        setWanted(on)
    }

    /// Le joystick bouge (pan ou tilt non nuls) : le suivi est coupé par `ControlTaker`, et le choix retenu devient
    /// « coupé ». Une relance en file ne partira pas.
    public func userMoved() {
        guard wanted else { return }
        log("Suivi IA : coupé par le joystick, choix retenu « coupé ».")
        setWanted(false)
        abandonPending()
        scheduleRead(after: Self.rereadInterval)
    }

    // MARK: - Événements

    /// La session de l'utilitaire va être remplacée (branchement, réveil, mise à jour) : la réponse d'un ordre en cours
    /// ne vaudra plus rien. À appeler avant `ControlTaker.reset()`.
    public func abandonSession() {
        abandonPending()
        timer?.cancel()
        timer = nil
        deferred = nil
    }

    /// Caméra présente (branchement, démarrage de ptzd), Mac sorti de veille, ou vie privée finie (position rétablie) :
    /// le choix voulu est réappliqué, puis l'état réel relu. Sans effet pendant la vie privée : sa fin réapplique.
    public func reapply(reason: String) {
        guard queue.supportsNativePrivacy, canOrder() else { return }
        abandonPending()
        retried = false
        guard control.state != .taking else {
            // Une coupure ou un ordre des apps est en cours : la réapplication part à sa fin (`controlFinished`).
            deferred = reason
            return
        }
        deferred = nil
        if wanted {
            resume(reason: reason)
        } else {
            timer?.cancel()
            timer = nil
            read()
        }
    }

    /// PTZBot a recompilé obsbot-ai (`aiUpdated`) : la relecture reprend (l'utilitaire peut connaître `tracking status`),
    /// et le choix est réappliqué si la caméra est là.
    public func utilityUpdated(cameraPresent: Bool) {
        readsUnsupported = false
        guard cameraPresent else { return }
        reapply(reason: "obsbot-ai mis à jour")
    }

    /// Fin d'un ordre de suivi (`ControlTaker`) : une réapplication reportée part maintenant.
    public func controlFinished() {
        guard control.state != .taking, let reason = deferred else { return }
        deferred = nil
        reapply(reason: reason)
    }

    // MARK: - Relance

    private func resume(reason: String) {
        timer?.cancel()
        timer = nil
        step = .resuming
        let current = ticket
        let epoch = control.epoch
        control.resumePending = true
        log("Suivi IA : relance (\(reason)).")
        queue.resumeTracking(when: { [weak self] in self?.mayResume(ticket: current, epoch: epoch) ?? false }) { [weak self] result in
            guard let self, current == ticket else { return }
            step = .idle
            control.resumePending = false
            resumed(result, reason: reason)
        }
    }

    /// Condition relue quand la relance arrive en tête de la file : rien ne part si la vie privée a été voulue, le choix
    /// coupé, un ordre de suivi donné entre-temps, ou la session abandonnée.
    private func mayResume(ticket current: Int, epoch: Int) -> Bool {
        current == ticket && wanted && canOrder() && control.state != .taking && control.epoch == epoch
    }

    private func resumed(_ result: AIResult, reason: String) {
        if result == .success {
            log("Suivi IA : relancé.")
            control.observe(.on)
            confirming = true
            scheduleRead(after: Self.settleDelay)
            return
        }
        guard wanted, canOrder(), result != AIOrderQueue.discarded else {
            // Écartée à son tour (vie privée, joystick, ordre des apps) : la suite dira quoi faire.
            if canOrder() {
                scheduleRead(after: Self.rereadInterval)
            }
            return
        }
        if !retried {
            retried = true
            log("Suivi IA : relance refusée (\(result.userDescription)) : nouvel essai dans \(Int(ControlTaker.retryDelay)) s.")
            timer = scheduler.schedule(after: ControlTaker.retryDelay) { [weak self] in
                guard let self else { return }
                timer = nil
                guard step == .idle, wanted, canOrder(), control.state != .taking else { return }
                resume(reason: reason)
            }
            return
        }
        log("Suivi IA : relance refusée (\(result.userDescription)) : la relecture périodique la retentera.")
        scheduleRead(after: Self.rereadInterval)
    }

    // MARK: - Relecture

    /// Les relectures demandent l'utilitaire gardé chaud (ptzd lancé avec le SDK, spec § 6.9) et à jour.
    private var readsPossible: Bool {
        queue.keepsWarm && queue.supportsNativePrivacy && !readsUnsupported
    }

    private func scheduleRead(after delay: TimeInterval) {
        timer?.cancel()
        timer = nil
        guard readsPossible else { return }
        timer = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            timer = nil
            read()
        }
    }

    private func read() {
        // Caméra absente, vie privée, utilitaire froid ou ancien : la relecture s'arrête ; le branchement, la sortie de
        // la vie privée ou la mise à jour la relancent.
        guard readsPossible, canOrder(), step == .idle else { return }
        if control.state == .taking {
            scheduleRead(after: Self.settleDelay)
            return
        }
        if let end = control.lastOrderEnd, scheduler.now - end < Self.settleDelay {
            scheduleRead(after: Self.settleDelay - (scheduler.now - end))
            return
        }
        step = .reading
        let current = ticket
        let epoch = control.epoch
        queue.readTracking(when: { [weak self] in self?.mayRead(ticket: current, epoch: epoch) ?? false }) { [weak self] reading in
            guard let self, current == ticket else { return }
            step = .idle
            readDone(reading, epoch: epoch)
        }
    }

    private func mayRead(ticket current: Int, epoch: Int) -> Bool {
        current == ticket && canOrder() && control.state != .taking && control.epoch == epoch
    }

    private func readDone(_ reading: TrackingReading, epoch: Int) {
        let confirmation = confirming
        confirming = false
        guard control.epoch == epoch, control.state != .taking, canOrder() else {
            // Un ordre de suivi est parti depuis la lecture, ou la vie privée est voulue : elle ne dit plus rien.
            if canOrder() {
                scheduleRead(after: Self.rereadInterval)
            }
            return
        }
        switch reading {
        case .mode(.on):
            if !wanted {
                log("Suivi IA : lu activé alors qu'il est voulu coupé (geste sur la caméra, ou caméra démarrée en suivi) : état réel adopté.")
                setWanted(true)
            }
            control.observe(.on)
            scheduleRead(after: Self.rereadInterval)
        case .mode(.off):
            control.observe(.off)
            guard wanted else {
                scheduleRead(after: Self.rereadInterval)
                return
            }
            if confirmation {
                // Juste après une relance réussie : pas de nouvelle relance tout de suite, la relecture suivante la refera.
                log("Suivi IA : toujours lu coupé après la relance ; nouvel essai à la prochaine relecture.")
                scheduleRead(after: Self.rereadInterval)
                return
            }
            log("Suivi IA : lu coupé alors qu'il est voulu, relancé.")
            retried = false
            resume(reason: "relecture")
        case .mode(.switching):
            // La caméra bascule : rien à conclure, relu un peu plus tard.
            confirming = confirmation
            scheduleRead(after: Self.settleDelay)
        case .failed(.unknownOrder):
            log("Suivi IA : obsbot-ai ne sait pas lire le mode IA ; plus de relecture jusqu'à sa mise à jour.")
            readsUnsupported = true
        case let .failed(result):
            if result != AIOrderQueue.discarded {
                log("Suivi IA : mode IA illisible (\(result.userDescription)).")
            }
            scheduleRead(after: Self.rereadInterval)
        }
    }

    // MARK: - Outils

    /// Une relance ou une lecture en cours ne vaut plus : sa réponse sera écartée, et en file elle ne partira pas.
    private func abandonPending() {
        ticket += 1
        step = .idle
        confirming = false
        control.resumePending = false
    }

    private func setWanted(_ value: Bool) {
        guard wanted != value else { return }
        wanted = value
        persist()
    }

    /// Relit d'abord le fichier : la vie privée et l'exposition y écrivent aussi, leurs champs ne doivent pas être effacés.
    private func persist() {
        var state = store.load()
        state.aiTracking = wanted
        do {
            try store.save(state)
        } catch {
            log("Enregistrement de state.json impossible : \(error)")
        }
    }
}
