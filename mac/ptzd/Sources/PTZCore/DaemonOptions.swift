import Foundation

/// Options du service (la commande par défaut de ptzd), données par PTZBot (spec ptzd dans l'app § 5.4).
/// Sans elles, ptzd garde son fonctionnement en ligne de commande.
public struct DaemonOptions: Equatable, Sendable {
    /// Processus à surveiller : ptzd s'arrête quand il disparaît.
    public var parent: pid_t?
    /// Chemin d'obsbot-ai ; remplace `aiPath` de config.json.
    public var aiPath: String?
    /// Dossier contenant `libdev.dylib`, passé à obsbot-ai par `DYLD_LIBRARY_PATH`.
    public var sdkDirectory: String?

    public init(parent: pid_t? = nil, aiPath: String? = nil, sdkDirectory: String? = nil) {
        self.parent = parent
        self.aiPath = aiPath
        self.sdkDirectory = sdkDirectory
    }

    /// Lancé avec le SDK (`--ai`, donné par PTZBot) : l'utilitaire reste chargé tant que ptzd tourne (spec § 6.9).
    public var keepsAIWarm: Bool { aiPath != nil }

    public static let usage = "usage : ptzd [--parent <pid>] [--ai <chemin d'obsbot-ai>] [--sdk <dossier du SDK>]"

    /// Code de sortie d'une option inconnue ou mal formée (EX_USAGE).
    public static let usageStatus: Int32 = 64
    /// Code de sortie quand un autre ptzd tourne déjà : verrou de service tenu, ou port de 127.0.0.1
    /// déjà pris sous `--parent` (EX_TEMPFAIL). PTZBot ne relance pas ptzd sur ce code.
    public static let busyStatus: Int32 = 75

    public enum ParseError: Error, Equatable {
        case unknownOption(String)
        case missingValue(String)
        case invalidValue(option: String, value: String)
        case duplicate(String)
    }

    /// Lit `--parent <pid>`, `--ai <chemin>` et `--sdk <dossier>`, chacun au plus une fois.
    /// Les chemins sont absolus ; le PID est un entier strictement positif.
    public static func parse(_ arguments: [String]) throws(ParseError) -> DaemonOptions {
        var options = DaemonOptions()
        var seen: Set<String> = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let option = arguments[index]
            guard ["--parent", "--ai", "--sdk"].contains(option) else {
                throw .unknownOption(option)
            }
            guard seen.insert(option).inserted else {
                throw .duplicate(option)
            }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else {
                throw .missingValue(option)
            }
            let value = arguments[next]
            switch option {
            case "--parent":
                guard let pid = pid_t(value), pid > 0 else {
                    throw .invalidValue(option: option, value: value)
                }
                options.parent = pid
            case "--ai":
                guard value.hasPrefix("/") else {
                    throw .invalidValue(option: option, value: value)
                }
                options.aiPath = value
            default:
                guard value.hasPrefix("/") else {
                    throw .invalidValue(option: option, value: value)
                }
                options.sdkDirectory = value
            }
            index = arguments.index(after: next)
        }
        return options
    }

    /// L'environnement ajouté à celui de ptzd pour lancer obsbot-ai.
    public var aiEnvironment: [String: String] {
        guard let sdkDirectory else { return [:] }
        return ["DYLD_LIBRARY_PATH": sdkDirectory]
    }

    /// Le chemin d'obsbot-ai : `--ai`, sinon celui de config.json.
    public func aiURL(config: PTZConfig, relativeTo base: URL) -> URL {
        aiPath.map { URL(fileURLWithPath: $0) } ?? config.aiURL(relativeTo: base)
    }
}

extension DaemonOptions.ParseError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .unknownOption(option): "option inconnue : \(option)"
        case let .missingValue(option): "valeur manquante après \(option)"
        case let .invalidValue(option, value): "valeur invalide pour \(option) : \(value)"
        case let .duplicate(option): "option donnée deux fois : \(option)"
        }
    }
}
