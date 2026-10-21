import Foundation
import NacelleProtocol

/// Position mémorisée à l'entrée en vie privée.
public struct SavedPosition: Codable, Equatable, Sendable {
    public var pan: Double
    public var tilt: Double
    public var zoom: Int?

    public init(pan: Double, tilt: Double, zoom: Int?) {
        self.pan = pan
        self.tilt = tilt
        self.zoom = zoom
    }
}

/// Contenu de state.json (spec § 6.5, § 6.5 bis et § 6.11).
public struct PersistedState: Codable, Equatable, Sendable {
    /// La vie privée est en vigueur : de l'entrée demandée par l'utilisateur jusqu'à la fin de la sortie (position
    /// rétablie). Une coupure de ptzd en cours de sortie la réapplique : c'est le côté sûr.
    public var privacy: Bool
    /// La position d'avant la vie privée, écrite seulement à une entrée demandée par l'utilisateur.
    public var saved: SavedPosition?
    /// La caméra peut être en mode natif : dernier état réel constaté `privacy`, ou ordre natif parti sans lecture
    /// depuis. Tant qu'il est vrai, ptzd n'envoie aucun ordre de position avant d'avoir lu l'état réel.
    public var native: Bool
    /// L'exposition automatique est voulue (spec § 6.11) : réappliquée au démarrage, au rebranchement et après `aiUpdated`.
    public var autoExposure: Bool
    /// Le réglage d'exposition lu juste avant l'activation, remis à la désactivation. Écrit avant de passer en
    /// automatique ; nil hors exposition automatique (et, par un fichier abîmé, quand elle est voulue sans origine).
    public var exposureOrigin: ExposureSetting?

    public init(
        privacy: Bool,
        saved: SavedPosition?,
        native: Bool = false,
        autoExposure: Bool = false,
        exposureOrigin: ExposureSetting? = nil
    ) {
        self.privacy = privacy
        self.saved = saved
        self.native = native
        self.autoExposure = autoExposure
        self.exposureOrigin = exposureOrigin
    }

    private enum CodingKeys: String, CodingKey {
        case privacy, saved, native, autoExposure, exposureOrigin
        /// Le champ du premier prototype de la vie privée V2 (`native` ou `tilt`), lu seulement.
        case mode
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        privacy = try c.decode(Bool.self, forKey: .privacy)
        saved = try c.decodeIfPresent(SavedPosition.self, forKey: .saved)
        if let native = try? c.decodeIfPresent(Bool.self, forKey: .native) {
            self.native = native
        } else {
            // Un fichier d'avant la vie privée V2 n'a rien : la caméra n'a jamais été mise en mode natif. Celui du
            // premier prototype a `mode` : `native` y voulait dire « ordre natif donné », donc peut-être en mode natif.
            native = (try? c.decodeIfPresent(String.self, forKey: .mode)) == "native"
        }
        // Absents d'un fichier d'avant l'exposition automatique ; illisibles, ils se lisent « désactivée » / sans origine.
        autoExposure = (try? c.decodeIfPresent(Bool.self, forKey: .autoExposure)) ?? false
        exposureOrigin = try? c.decodeIfPresent(ExposureSetting.self, forKey: .exposureOrigin)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(privacy, forKey: .privacy)
        try c.encodeIfPresent(saved, forKey: .saved)
        try c.encode(native, forKey: .native)
        // Seulement s'ils servent : le fichier reste identique à celui de la 1.1.1 hors exposition automatique.
        if autoExposure {
            try c.encode(true, forKey: .autoExposure)
        }
        try c.encodeIfPresent(exposureOrigin, forKey: .exposureOrigin)
    }
}

public protocol StateStore: AnyObject {
    func load() -> PersistedState
    func save(_ state: PersistedState) throws
}

/// state.json, écrit de façon atomique.
public final class JSONFileStateStore: StateStore {
    private let url: URL
    private let log: (String) -> Void

    public init(url: URL, log: @escaping (String) -> Void) {
        self.url = url
        self.log = log
    }

    /// Fichier absent : pas de vie privée. Fichier illisible : vie privée,
    /// par précaution (mieux vaut une caméra tournée vers le bas qu'une fuite), et la caméra peut être en mode natif :
    /// son état réel est lu avant tout ordre de position (spec § 6.5 bis).
    public func load() -> PersistedState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersistedState(privacy: false, saved: nil)
        }
        do {
            return try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: url))
        } catch {
            log("state.json illisible (\(error)) : vie privée activée par précaution.")
            return PersistedState(privacy: true, saved: nil, native: true)
        }
    }

    public func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
