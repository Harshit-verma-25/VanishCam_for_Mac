import Foundation
import SystemExtensions

enum InstallState: Equatable {
    case unknown, working, needsApproval, installed, removed
    case failed(String)

    var label: String {
        switch self {
        case .unknown: return "Not installed"
        case .working: return "Working…"
        case .needsApproval: return "Waiting for your approval in System Settings"
        case .installed: return "Installed"
        case .removed: return "Removed"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

/// Installs / removes the camera extension through the SystemExtensions framework.
/// macOS only allows this when VanishCam.app runs from /Applications.
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    let identifier: String
    private let onChange: (InstallState) -> Void
    private var removing = false

    init(identifier: String, onChange: @escaping (InstallState) -> Void) {
        self.identifier = identifier
        self.onChange = onChange
    }

    func install() {
        removing = false
        submit(.activationRequest(forExtensionWithIdentifier: identifier, queue: .main))
    }

    func uninstall() {
        removing = true
        submit(.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main))
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        request.delegate = self
        onChange(.working)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onChange(.needsApproval)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed: onChange(removing ? .removed : .installed)
        case .willCompleteAfterReboot: onChange(.failed("Restart your Mac to finish."))
        @unknown default: onChange(.failed("Unexpected result."))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        var message = error.localizedDescription
        if (error as NSError).code == OSSystemExtensionError.unsupportedParentBundleLocation.rawValue {
            message = "Move VanishCam.app to /Applications and open it from there."
        }
        onChange(.failed(message))
    }
}
