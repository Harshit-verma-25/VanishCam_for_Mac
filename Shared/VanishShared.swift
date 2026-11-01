import Foundation

/// Effect modes, shared by the app (UI) and the camera extension (rendering).
enum VanishMode: String, CaseIterable, Identifiable, Codable {
    case normal, particles, goku, naruto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal Vanish"
        case .particles: return "Particles"
        case .goku: return "Goku Teleport"
        case .naruto: return "Naruto Substitution"
        }
    }

    var gestureHint: String {
        switch self {
        case .normal: return "Show a V sign (index + middle finger apart). Do it again to reappear."
        case .particles: return "Show a V sign. You break into fragments carried by the wind. V again to reappear."
        case .goku: return "Hold index + middle finger together on your forehead for 1 second. Repeat to come back."
        case .naruto: return "Press your palms together in front of you, fingers up. Repeat to come back."
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "sparkles"
        case .particles: return "wind"
        case .goku: return "bolt.fill"
        case .naruto: return "cloud.fill"
        }
    }

    var vanishDuration: Double {
        switch self {
        case .normal: return 3.6
        case .particles: return 2.1
        case .goku: return 1.3
        case .naruto: return 1.6
        }
    }

    var reappearDuration: Double {
        switch self {
        case .normal: return 2.4
        case .particles: return 2.1
        case .goku: return 1.3
        case .naruto: return 1.6
        }
    }
}

/// Commands the app can send to the extension.
enum VanishCommand: String {
    case recapture   // re-learn the empty background (user steps out of frame)
    case vanish      // trigger the effect without a gesture
    case reappear
}

/// Live state the extension publishes; the app polls it for its UI.
struct VanishStatus: Codable, Equatable {
    var camera: String = "idle"          // idle | ok | denied | missing
    var cameraName: String = ""
    var phase: String = "visible"        // visible | vanishing | vanished | reappearing
    var mode: String = VanishMode.normal.rawValue
    var recaptureStage: String = ""      // "" | leave | capturing
    var recaptureRemaining: Double = 0
    var gestureProgress: Double = 0      // 0...1 while the trigger gesture is being held
}

/// Names shared across the CoreMediaIO boundary.
/// Custom properties live on the virtual camera's stream; the app talks to them
/// with CMIOObjectGet/SetPropertyData, the extension sees them as CMIOExtensionProperty.
enum VanishIPC {
    static let cameraName = "Vanish Camera"
    static let modelID = "VanishCam Virtual Camera"

    static let modeSelector = "mode"
    static let commandSelector = "cmnd"
    static let statusSelector = "stat"

    static func extensionPropertyName(_ selector: String) -> String { "4cc_\(selector)_glob_0000" }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
