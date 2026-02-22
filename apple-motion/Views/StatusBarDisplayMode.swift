import SwiftUI

enum StatusBarDisplayMode: String, CaseIterable, Identifiable {
    case all      = "all"
    case spectrum = "spectrum"
    case accelMag = "accelMag"
    case roll     = "roll"
    case pitch    = "pitch"
    case lux      = "lux"
    case lidAngle = "lidAngle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:      return "All Values"
        case .spectrum: return "Vibration Spectrum"
        case .accelMag: return "Accel Magnitude"
        case .roll:     return "Roll Angle"
        case .pitch:    return "Pitch Angle"
        case .lux:      return "Ambient Light"
        case .lidAngle: return "Lid Angle"
        }
    }
}
