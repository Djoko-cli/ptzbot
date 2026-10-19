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

/// Contenu de state.json (spec § 6.5 et § 6.5 bis).
public struct PersistedState: Codable, Equatable, Sendable {
    /// La vie privée est en vigueur : de l'entrée demandée par l'utilisateur jusqu'à la fin de la sortie (position
    /// rétablie). Une coupure de ptzd en cours de sortie la réapplique : c'est le côté sûr.
    public var privacy: Bool
    /// La position d'avant la vie privée, écrite seulement à une entrée demandée par l'utilisateur.
    public var saved: SavedPosition?
    /// La caméra peut être en mode natif : dernier état réel constaté `privacy`, ou ordre natif parti sans lecture
    /// depuis. Tant qu'il est vrai, ptzd n'envoie aucun ordre de position avant d'avoir lu l'état réel.
    public var native: Bool

    public init(privacy: Bool, saved: SavedPosition?, native: Bool = false) {
        self.privacy = privacy
        self.saved = saved
        self.native = native
    }

    private enum CodingKeys: String, CodingKey {
        case privacy, saved, native
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
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(privacy, forKey: .privacy)
        try c.encodeIfPresent(saved, forKey: .saved)
        try c.encode(native, forKey: .native)
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
