import CUVC
import Foundation
import PTZCore

/// La Tiny 2 vue à travers ses commandes UVC, sans ouverture exclusive.
@MainActor
public final class UVCCamera: CameraDevice {
    public static let tiny2VendorID: UInt16 = 0x3564
    public static let tiny2ProductID: UInt16 = 0xFEF8
    /// Ouverture : 5 essais à 1 s d'intervalle, puis toutes les 5 s tant que la caméra reste branchée.
    static let openRetries = 5
    static let openRetryDelay: TimeInterval = 1
    static let openSlowRetryDelay: TimeInterval = 5
    /// Au palier de 5 s, un échec journalisé par minute au plus.
    static let openSlowRetriesPerLog = 12

    /// Appelé quand la caméra devient utilisable ou cesse de l'être.
    public var onPresenceChange: ((Bool) -> Void)?

    private let vendorID: UInt16
    private let productID: UInt16
    private let log: LogSink
    private var device: OpaquePointer?
    private var watcher: USBPresenceWatcher?
    private var attached = false
    private var openRetry: DispatchWorkItem?

    public init(
        vendorID: UInt16 = UVCCamera.tiny2VendorID,
        productID: UInt16 = UVCCamera.tiny2ProductID,
        log: @escaping LogSink
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.log = log
    }

    public var isPresent: Bool {
        device != nil
    }

    /// La caméra est branchée (vue par IOKit), même si ses commandes ne sont pas encore ouvertes. Fiable dès le retour de
    /// `startWatching`, qui signale la présence actuelle avant de rendre la main.
    public var isAttached: Bool {
        attached
    }

    /// Ouvre la caméra si elle est branchée, puis suit ses branchements. Sans effet si
    /// la surveillance tourne déjà. Une UVCCamera vit aussi longtemps que le processus :
    /// la surveillance IOKit garde un pointeur non retenu vers elle et n'est jamais démontée.
    public func startWatching() {
        guard watcher == nil else { return }
        let watcher = USBPresenceWatcher(vendorID: Int(vendorID), productID: Int(productID)) { [weak self] attached in
            self?.attachmentChanged(attached)
        }
        self.watcher = watcher
        watcher.start()
    }

    public func setPanTiltRelative(_ command: PanTiltRelative) throws {
        try set(UVCPayload.selectorPanTiltRelative, UVCPayload.panTiltRelative(command))
    }

    public func setPanTiltAbsolute(panDegrees: Double, tiltDegrees: Double) throws {
        try set(UVCPayload.selectorPanTiltAbsolute, UVCPayload.panTiltAbsolute(panDegrees: panDegrees, tiltDegrees: tiltDegrees))
    }

    public func setZoom(_ value: Int) throws {
        try set(UVCPayload.selectorZoomAbsolute, UVCPayload.zoomAbsolute(value))
    }

    public func readPanTilt() throws -> PanTiltPosition {
        UVCPayload.decodePanTiltAbsolute(try get(UVCPayload.selectorPanTiltAbsolute, length: 8))
    }

    public func readZoom() throws -> Int {
        UVCPayload.decodeZoom(try get(UVCPayload.selectorZoomAbsolute, length: 2))
    }

    private func attachmentChanged(_ nowAttached: Bool) {
        attached = nowAttached
        // Une seule série d'essais à la fois, même après un débranchement-rebranchement rapide.
        openRetry?.cancel()
        openRetry = nil
        if nowAttached {
            open(attempt: 0)
        } else if device != nil {
            cuvc_close(device)
            device = nil
            onPresenceChange?(false)
        }
    }

    /// Juste après le branchement, la caméra peut ne pas répondre encore : on réessaie,
    /// sans jamais abandonner tant qu'elle reste branchée (la vie privée en dépend).
    private func open(attempt: Int) {
        openRetry = nil
        guard attached, device == nil else { return }
        var error: Int32 = 0
        if let opened = cuvc_open(vendorID, productID, &error) {
            device = opened
            onPresenceChange?(true)
            return
        }
        let slow = attempt + 1 >= Self.openRetries
        if slow, (attempt + 1 - Self.openRetries) % Self.openSlowRetriesPerLog == 0 {
            log("Caméra branchée mais commandes UVC inaccessibles (code \(Self.hex(error))) : nouvel essai toutes les 5 s.")
        }
        let retry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.open(attempt: attempt + 1) }
        }
        openRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + (slow ? Self.openSlowRetryDelay : Self.openRetryDelay), execute: retry)
    }

    private func set(_ selector: UInt8, _ payload: [UInt8]) throws {
        guard let device else { throw CameraError.absent }
        var bytes = payload
        let result = bytes.withUnsafeMutableBytes { buffer in
            cuvc_camera_control(device, UVCPayload.setCurrent, selector, buffer.baseAddress, UInt16(buffer.count))
        }
        guard result == 0 else { throw CameraError.ioKit(result) }
    }

    private func get(_ selector: UInt8, length: Int) throws -> [UInt8] {
        guard let device else { throw CameraError.absent }
        var bytes = [UInt8](repeating: 0, count: length)
        let result = bytes.withUnsafeMutableBytes { buffer in
            cuvc_camera_control(device, UVCPayload.getCurrent, selector, buffer.baseAddress, UInt16(buffer.count))
        }
        guard result == 0 else { throw CameraError.ioKit(result) }
        return bytes
    }

    static func hex(_ code: Int32) -> String {
        String(format: "0x%08x", UInt32(bitPattern: code))
    }
}
