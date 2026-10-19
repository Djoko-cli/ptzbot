import Foundation

/// Zoom absolu, borné à 0…100, au plus 10 envois par seconde (spec § 6.3).
@MainActor
public final class ZoomDriver {
    public static let minInterval: TimeInterval = 0.1

    public private(set) var value: Int?
    /// Appelé quand `value` change.
    public var onChange: (() -> Void)?

    private let camera: any CameraDevice
    private let scheduler: any Scheduler
    private let log: LogSink
    private var lastSentAt = -TimeInterval.infinity
    private var pending: Int?
    private var flush: (any Cancellable)?

    public init(camera: any CameraDevice, scheduler: any Scheduler, log: @escaping LogSink) {
        self.camera = camera
        self.scheduler = scheduler
        self.log = log
    }

    /// Envoie tout de suite, ou garde la valeur pour le prochain créneau.
    /// Seule la dernière valeur en attente est envoyée.
    public func set(_ requested: Int) throws {
        let clamped = min(max(requested, 0), 100)
        let elapsed = scheduler.now - lastSentAt
        if flush == nil, elapsed >= Self.minInterval {
            try send(clamped)
            return
        }
        pending = clamped
        if flush == nil {
            flush = scheduler.schedule(after: Self.minInterval - elapsed) { [weak self] in
                self?.flushPending()
            }
        }
    }

    /// Relit le zoom ; publie s'il a changé.
    public func refresh() {
        guard let read = try? camera.readZoom(), read != value else { return }
        value = read
        onChange?()
    }

    /// Abandonne la valeur en attente du prochain créneau : l'entrée en vie privée n'en laisse partir aucune
    /// (spec § 6.5 bis : aucun ordre UVC une fois la vie privée demandée).
    public func cancelPending() {
        flush?.cancel()
        flush = nil
        pending = nil
    }

    /// Oublie tout (caméra débranchée).
    public func reset() {
        flush?.cancel()
        flush = nil
        pending = nil
        lastSentAt = -TimeInterval.infinity
        if value != nil {
            value = nil
            onChange?()
        }
    }

    private func send(_ newValue: Int) throws {
        try camera.setZoom(newValue)
        lastSentAt = scheduler.now
        if value != newValue {
            value = newValue
            onChange?()
        }
    }

    private func flushPending() {
        flush = nil
        guard let next = pending else { return }
        pending = nil
        do {
            try send(next)
        } catch {
            log("Zoom à \(next) impossible : \(error)")
        }
    }
}
