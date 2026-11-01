import SwiftUI
import AppKit
import AVFoundation
import CoreMediaIO

@MainActor
final class AppModel: ObservableObject {
    @Published var installState: InstallState = .unknown
    @Published var cameraFound = false
    @Published var connected = false
    @Published var mode: VanishMode = .normal
    @Published var status = VanishStatus()
    @Published var cameraDenied = false
    @Published var previewOn = true {
        didSet { previewOn ? refresh(force: true) : stopPreview() }
    }

    let previewSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "VanishCam.preview")
    private var previewDeviceID: String?
    private var streamID: CMIOObjectID?
    private var pollTimer: Timer?
    private var tickCount = 0

    static var extensionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.harshitverma.VanishCam") + ".CameraExtension"
    }

    private lazy var installer = ExtensionInstaller(identifier: Self.extensionIdentifier) { [weak self] state in
        Task { @MainActor in
            self?.installState = state
            if state == .installed { self?.refresh(force: true) }
        }
    }

    init() {
        refresh(force: true)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Actions

    func installExtension() { installer.install() }

    func uninstallExtension() {
        stopPreview()
        installer.uninstall()
    }

    func setMode(_ newMode: VanishMode) {
        mode = newMode
        if let streamID { CMIOBridge.setString(streamID, VanishIPC.modeSelector, newMode.rawValue) }
    }

    func send(_ command: VanishCommand) {
        guard let streamID else { return }
        // Nonce makes repeated commands register as a property change.
        CMIOBridge.setString(streamID, VanishIPC.commandSelector, "\(command.rawValue):\(UUID().uuidString.prefix(8))")
    }

    func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func openExtensionSettings() {
        // macOS 15+: General → Login Items & Extensions; macOS 13/14: Privacy & Security.
        let candidates = ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                          "x-apple.systempreferences:com.apple.preference.security"]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Device discovery & polling

    private func tick() {
        tickCount += 1
        if streamID == nil {
            if tickCount % 4 == 0 { refresh() }
            return
        }
        readStatus()
    }

    func refresh(force: Bool = false) {
        let device = Self.findVanishDevice()
        cameraFound = device != nil
        if cameraFound, installState == .unknown || installState == .removed { installState = .installed }

        if let id = CMIOBridge.deviceID(named: VanishIPC.cameraName), let stream = CMIOBridge.streams(of: id).first {
            streamID = stream
            connected = true
            if let raw = CMIOBridge.string(stream, VanishIPC.modeSelector), let m = VanishMode(rawValue: raw) { mode = m }
        } else {
            streamID = nil
            connected = false
        }

        if let device, previewOn { startPreview(device, force: force) }
    }

    private func readStatus() {
        guard let streamID else { return }
        guard let json = CMIOBridge.string(streamID, VanishIPC.statusSelector) else {
            self.streamID = nil
            connected = false
            return
        }
        if let data = json.data(using: .utf8), let decoded = try? JSONDecoder().decode(VanishStatus.self, from: data) {
            status = decoded
            if let m = VanishMode(rawValue: decoded.mode), m != mode { mode = m }
        }
    }

    static func findVanishDevice() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.external] } else { types = [.externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
            .devices.first { $0.localizedName == VanishIPC.cameraName }
    }

    // MARK: Preview (the app is just another client of Vanish Camera)

    private func startPreview(_ device: AVCaptureDevice, force: Bool) {
        guard force || previewDeviceID != device.uniqueID else { return }
        previewDeviceID = device.uniqueID

        let session = previewSession
        let queue = sessionQueue
        let begin = {
            queue.async {
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
                if !session.isRunning { session.startRunning() }
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraDenied = false
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    self.cameraDenied = !granted
                    if granted { begin() }
                }
            }
        default:
            cameraDenied = true
        }
    }

    private func stopPreview() {
        previewDeviceID = nil
        let session = previewSession
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }
}
