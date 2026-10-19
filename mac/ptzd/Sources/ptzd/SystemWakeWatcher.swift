import Foundation
import IOKit
import IOKit.pwr_mgt

/// Signale la sortie de veille du Mac, par les notifications d'alimentation d'IOKit sur la file principale : en vie
/// privée native, ptzd relit alors l'état réel de la caméra (spec § 6.5 bis). Chaque demande de mise en veille est
/// acceptée tout de suite : ptzd ne retarde jamais la veille. Le port IOKit garde un pointeur non retenu vers cet
/// objet : il doit vivre aussi longtemps que le processus.
@MainActor
final class SystemWakeWatcher {
    // Les messages d'alimentation d'IOKit (IOMessage.h : iokit_common_msg), que Swift n'importe pas.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let onWake: @MainActor () -> Void
    private var rootPort: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(onWake: @escaping @MainActor () -> Void) {
        self.onWake = onWake
    }

    /// Arme les notifications ; sans effet si elles le sont déjà, ou si IOKit les refuse.
    func start() {
        guard port == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var notificationPort: IONotificationPortRef?
        let root = IORegisterForSystemPower(context, &notificationPort, { context, _, message, argument in
            guard let context else { return }
            let watcher = Unmanaged<SystemWakeWatcher>.fromOpaque(context).takeUnretainedValue()
            let identifier = Int(bitPattern: argument)
            MainActor.assumeIsolated { watcher.received(message, identifier: identifier) }
        }, &notifier)
        guard root != 0, let notificationPort else { return }
        rootPort = root
        port = notificationPort
        IONotificationPortSetDispatchQueue(notificationPort, DispatchQueue.main)
    }

    private func received(_ message: UInt32, identifier: Int) {
        switch message {
        case Self.canSystemSleep, Self.systemWillSleep:
            IOAllowPowerChange(rootPort, identifier)
        case Self.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }
}
