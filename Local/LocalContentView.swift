import SwiftUI

struct LocalContentView: View {
    @EnvironmentObject private var model: LocalModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                videoPanel
                statusBar
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
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

    // MARK: Video

    private var videoPanel: some View {
        ZStack {
            VideoView(sink: model.sink)
            recaptureOverlay
        }
        .background(Color.black)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
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
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var cameraLabel: String {
        switch model.status.camera {
        case "ok": return model.status.cameraName.isEmpty ? "Camera on" : model.status.cameraName
        case "denied": return "No camera access"
        case "missing": return "No camera found"
        default: return "Starting…"
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
            if model.status.camera == "denied" {
                Button("Open Camera Privacy Settings") { model.openCameraSettings() }
            }
        }
    }

    private var meetingSection: some View {
        section("Use in meetings") {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.meetTabs > 0 ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(model.meetTabs > 0 ? "Sending video to Google Meet" : "Not connected to Google Meet")
                    .font(.callout)
            }
            Text("**Google Meet:** with the Chrome extension installed, pick **Vanish Camera** in Meet's camera list. Keep this app open during the call.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("**Zoom and other apps:** add the Output window to OBS with Window Capture, click **Start Virtual Camera**, then pick **OBS Virtual Camera**.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Output Window") { openWindow(id: "output") }
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
