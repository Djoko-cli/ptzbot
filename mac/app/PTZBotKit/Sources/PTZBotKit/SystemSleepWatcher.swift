import AppKit
import IOKit
import IOKit.pwr_mgt

/// Relie les notifications d'alimentation de macOS à `Go2RTCSleepPause` (spec B3 § 15), sans logique : toute la décision
/// est dans la pause, que les tests couvrent. Sur le modèle de `SystemWakeWatcher` (ptzd), sur la file principale.
///
/// L'annonce de veille (`kIOMessageSystemWillSleep`) n'est acquittée qu'à la demande de la pause : go2rtc a alors fini de
/// s'arrêter, ou la limite de temps est passée. Toute demande de mise en veille possible (`kIOMessageCanSystemSleep`) est
/// acceptée tout de suite : PTZBot ne refuse jamais une veille. Le port IOKit garde un pointeur non retenu vers cet
/// objet : il doit vivre aussi longtemps que l'app.
@MainActor
public final class SystemSleepWatcher {
    // Les messages d'alimentation d'IOKit (IOMessage.h : iokit_common_msg), que Swift n'importe pas.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let pause: Go2RTCSleepPause
    private var rootPort: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var observers: [any NSObjectProtocol] = []

    public init(pause: Go2RTCSleepPause) {
        self.pause = pause
    }

    /// Arme les notifications ; sans effet si elles le sont déjà, ou si IOKit les refuse.
    public func start() {
        guard port == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var notificationPort: IONotificationPortRef?
        let root = IORegisterForSystemPower(context, &notificationPort, { context, _, message, argument in
            guard let context else { return }
            let watcher = Unmanaged<SystemSleepWatcher>.fromOpaque(context).takeUnretainedValue()
            let identifier = Int(bitPattern: argument)
            MainActor.assumeIsolated { watcher.received(message, identifier: identifier) }
        }, &notifier)
        guard root != 0, let notificationPort else { return }
        rootPort = root
        port = notificationPort
        IONotificationPortSetDispatchQueue(notificationPort, DispatchQueue.main)
        // Le réveil complet et les écrans, que les notifications d'IOKit ne distinguent pas du réveil sombre.
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause.systemDidWake() }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause.screensDidWake() }
            },
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause.screensDidSleep() }
            },
        ]
    }

    private func received(_ message: UInt32, identifier: Int) {
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, identifier)
        case Self.systemWillSleep:
            let root = rootPort
            pause.systemWillSleep { IOAllowPowerChange(root, identifier) }
        case Self.systemHasPoweredOn:
            pause.systemDidPowerOn()
        default:
            break
        }
    }
}
