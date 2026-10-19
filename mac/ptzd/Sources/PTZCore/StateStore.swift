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
    public var privacy: Bool
    public var saved: SavedPosition?
    /// Mode de la vie privée en cours ; sans effet hors vie privée. Absent d'un fichier ancien : `tilt`.
    public var mode: PrivacyMode

    public init(privacy: Bool, saved: SavedPosition?, mode: PrivacyMode = .tilt) {
        self.privacy = privacy
        self.saved = saved
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case privacy, saved, mode
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        privacy = try c.decode(Bool.self, forKey: .privacy)
        saved = try c.decodeIfPresent(SavedPosition.self, forKey: .saved)
        // Un fichier d'avant la vie privée V2 n'a pas de mode ; une valeur inconnue se lit aussi `tilt`, le repli qui
        // ne dépend pas du SDK.
        mode = (try? c.decodeIfPresent(PrivacyMode.self, forKey: .mode)) ?? .tilt
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
    /// par précaution (mieux vaut une caméra tournée vers le bas qu'une fuite).
    public func load() -> PersistedState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersistedState(privacy: false, saved: nil)
        }
        do {
            return try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: url))
        } catch {
            log("state.json illisible (\(error)) : vie privée activée par précaution.")
            return PersistedState(privacy: true, saved: nil)
        }
    }

    public func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
