import SwiftUI
import AppKit
import os.log

/// The shared engine files log through this; the extension target defines its own in VanishProvider.swift.
let extLog = Logger(subsystem: "VanishCam.Local", category: "engine")

@main
struct VanishCamLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LocalModel()

    var body: some Scene {
        Window("VanishCam Local", id: "main") {
            LocalContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)

        // Video only, so OBS Window Capture gets no buttons or sidebar.
        Window("VanishCam Output", id: "output") {
            VideoView(sink: model.sink)
                .background(Color.black)
                .frame(minWidth: 640, minHeight: 360)
        }
        .defaultSize(width: 1280, height: 720)
    }
}

/// Closing the windows quits the app, so the camera never keeps running with nothing on screen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
