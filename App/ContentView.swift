import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                previewPanel
                statusBar
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    setupSection
                    modeSection
                    controlsSection
                    meetingSection
                }
                .padding(20)
            }
            .frame(width: 320)
            .background(.regularMaterial)
        }
    }

    // MARK: Preview

    private var previewPanel: some View {
        ZStack {
            Color.black
            if model.cameraFound && model.previewOn && !model.cameraDenied {
                CameraPreview(session: model.previewSession)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: model.cameraDenied ? "video.slash" : "video.badge.plus")
                        .font(.system(size: 40, weight: .light))
                    Text(placeholderText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    if model.cameraDenied {
                        Button("Open Camera Privacy Settings") { model.openCameraSettings() }
                    }
                }
                .foregroundStyle(.white.opacity(0.8))
            }
            recaptureOverlay
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    private var placeholderText: String {
        if model.cameraDenied { return "VanishCam needs camera access to show the preview." }
        if !model.previewOn { return "Preview is off. Vanish Camera still works in other apps." }
        return "Install the camera extension to see “Vanish Camera” here."
    }

    @ViewBuilder
    private var recaptureOverlay: some View {
        switch model.status.recaptureStage {
        case "leave":
            banner("Step out of the frame", String(format: "Capturing starts in %.0f s", model.status.recaptureRemaining.rounded(.up)))
        case "capturing":
            banner("Learning your background…", String(format: "Stay out of view for %.0f s", model.status.recaptureRemaining.rounded(.up)))
        default:
            EmptyView()
        }
    }

    private func banner(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusBar: some View {
        HStack(spacing: 18) {
            Label(cameraLabel, systemImage: "camera")
            Label(model.status.phase.capitalized, systemImage: phaseSymbol)
            HStack(spacing: 6) {
                Image(systemName: "hand.raised")
                ProgressView(value: model.status.gestureProgress)
                    .frame(width: 90)
            }
            .help("Fills up while you hold the trigger gesture")
            Spacer()
            Toggle("Preview", isOn: $model.previewOn).toggleStyle(.switch).controlSize(.small)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var cameraLabel: String {
        switch model.status.camera {
        case "ok": return model.status.cameraName.isEmpty ? "Camera on" : model.status.cameraName
        case "denied": return "Extension has no camera access"
        case "missing": return "No physical camera"
        default: return model.connected ? "Idle" : "Not connected"
        }
    }

    private var phaseSymbol: String {
        switch model.status.phase {
        case "vanished": return "eye.slash"
        case "vanishing", "reappearing": return "wand.and.stars"
        default: return "person"
        }
    }

    // MARK: Sidebar

    private var setupSection: some View {
        section("Camera extension") {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.cameraFound ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.cameraFound ? "Vanish Camera is available" : model.installState.label)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.installState == .needsApproval {
                Button("Open System Settings") { model.openExtensionSettings() }
            }
            HStack {
                Button(model.cameraFound ? "Reinstall" : "Install Camera Extension") { model.installExtension() }
                    .buttonStyle(.borderedProminent)
                if model.cameraFound {
                    Button("Uninstall", role: .destructive) { model.uninstallExtension() }
                }
            }
        }
    }

    private var modeSection: some View {
        section("Effect") {
            ForEach(VanishMode.allCases) { mode in
                Button { model.setMode(mode) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: mode.symbol)
                            .frame(width: 22)
                            .foregroundStyle(model.mode == mode ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mode.title).font(.body.weight(.medium))
                            Text(mode.gestureHint).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(model.mode == mode ? Color.accentColor.opacity(0.12) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(model.mode == mode ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .disabled(!model.connected)
            }
        }
    }

    private var controlsSection: some View {
        section("Controls") {
            Button { model.send(.recapture) } label: {
                Label("Recapture background", systemImage: "arrow.triangle.2.circlepath.camera")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Do this once per setup: click, step out of frame for ~7 s. The background is remembered.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Vanish now") { model.send(.vanish) }
                Button("Reappear") { model.send(.reappear) }
            }
        }
        .disabled(!model.connected)
    }

    private var meetingSection: some View {
        section("Use in meetings") {
            Text("In Zoom, Google Meet (Chrome), Teams, FaceTime or Photo Booth, pick **Vanish Camera** as your camera. It switches on by itself whenever an app opens it — this window doesn't need to stay open.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - AVFoundation preview

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}
}

final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer = previewLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // Mirror like a normal self-view; what other people see is not mirrored.
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}
