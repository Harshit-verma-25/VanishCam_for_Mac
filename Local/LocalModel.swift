import SwiftUI
import AppKit

/// Owns the engine in-process. Replaces the CMIO custom properties the extension build talks through.
@MainActor
final class LocalModel: ObservableObject {
    @Published private(set) var mode: VanishMode
    @Published private(set) var status = VanishStatus()
    @Published private(set) var meetTabs = 0

    let sink = FrameSink()
    private let server = FrameServer()
    private let engine = VanishEngine(width: 1280, height: 720)
    private var pollTimer: Timer?
    private var terminationObserver: NSObjectProtocol?

    init() {
        mode = engine.currentMode
        engine.onFrame = { [sink, server] buffer in
            sink.push(buffer)
            server.push(buffer)
        }
        server.onClientCountChange = { [weak self] count in
            Task { @MainActor in self?.meetTabs = count }
        }
        server.start()
        engine.start()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readStatus() }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [engine] _ in engine.stopAndWait() }
    }

    func setMode(_ newMode: VanishMode) {
        mode = newMode
        engine.setMode(newMode)
    }

    func send(_ command: VanishCommand) { engine.handle(command) }

    func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func readStatus() {
        guard let data = engine.statusJSON().data(using: .utf8),
              let decoded = try? JSONDecoder().decode(VanishStatus.self, from: data),
              decoded != status else { return }
        status = decoded
    }
}
