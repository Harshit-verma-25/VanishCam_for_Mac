import SwiftUI

@main
struct VanishCamApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("VanishCam") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}
