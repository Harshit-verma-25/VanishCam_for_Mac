import Foundation
import CoreMediaIO

// Entry point of the camera extension process. macOS launches it on demand;
// the provider publishes the "Vanish Camera" device to every app on the Mac.
let providerSource = VanishProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
