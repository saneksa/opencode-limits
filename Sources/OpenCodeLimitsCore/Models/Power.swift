import Foundation

/// Power source of the machine, used to decide whether polling should slow
/// down. `.lowPower` always wins over the raw power source.
public enum PowerState: String, Sendable, Equatable {
    case ac = "ac"
    case battery = "battery"
    case lowPower = "lowPower"
    case unknown = "unknown"

    public var title: String {
        switch self {
        case .ac: return "От сети"
        case .battery: return "От батареи"
        case .lowPower: return "Low Power Mode"
        case .unknown: return "Неизвестно"
        }
    }

    /// Whether energy-saving behaviour should apply.
    public var isEnergySaving: Bool { self == .battery || self == .lowPower }

    /// Pure parser so it can be unit-tested without spawning `pmset`.
    /// Low Power Mode wins over AC. Unrecognised output → `.unknown`.
    public static func parse(pmsetOutput: String, lowPowerEnabled: Bool) -> PowerState {
        if lowPowerEnabled { return .lowPower }
        let output = pmsetOutput.lowercased()
        if output.contains("battery power") { return .battery }
        if output.contains("ac power") { return .ac }
        return .unknown
    }
}
