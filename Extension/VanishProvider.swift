import Foundation
import CoreMediaIO
import IOKit.audio
import os.log

let extLog = Logger(subsystem: "VanishCam.Extension", category: "provider")

let kOutputWidth: Int32 = 1280
let kOutputHeight: Int32 = 720
let kFrameRate: Int32 = 30

private let modeProperty = CMIOExtensionProperty(rawValue: VanishIPC.extensionPropertyName(VanishIPC.modeSelector))
private let commandProperty = CMIOExtensionProperty(rawValue: VanishIPC.extensionPropertyName(VanishIPC.commandSelector))
private let statusProperty = CMIOExtensionProperty(rawValue: VanishIPC.extensionPropertyName(VanishIPC.statusSelector))

// MARK: - Provider

final class VanishProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: VanishDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = VanishDeviceSource(localizedName: VanishIPC.cameraName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { props.manufacturer = "VanishCam" }
        return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

final class VanishDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: VanishStreamSource!
    private var videoDescription: CMFormatDescription!
    let engine: VanishEngine

    private var streamingCounter = 0
    private let counterLock = NSLock()

    init(localizedName: String) {
        engine = VanishEngine(width: Int(kOutputWidth), height: Int(kOutputHeight))
        super.init()

        // Fixed IDs so Zoom/Meet remember "Vanish Camera" across reboots and updates.
        let deviceID = UUID(uuidString: "6E0F2D4A-7C1B-4C55-9A0B-5A11C0DE0001")!
        let streamID = UUID(uuidString: "6E0F2D4A-7C1B-4C55-9A0B-5A11C0DE0002")!

        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)

        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: kOutputWidth, height: kOutputHeight,
                                       extensions: nil,
                                       formatDescriptionOut: &videoDescription)

        let frameDuration = CMTime(value: 1, timescale: kFrameRate)
        let format = CMIOExtensionStreamFormat(formatDescription: videoDescription,
                                               maxFrameDuration: frameDuration,
                                               minFrameDuration: frameDuration,
                                               validFrameDurations: nil)

        streamSource = VanishStreamSource(localizedName: "Vanish Camera Video", streamID: streamID,
                                          streamFormat: format, device: device, engine: engine)
        do {
            try device.addStream(streamSource.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }

        engine.onFrame = { [weak self] pixelBuffer in self?.send(pixelBuffer) }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { props.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { props.model = VanishIPC.modelID }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    /// Called when an app (Zoom, Meet, Photo Booth, the VanishCam app...) starts using the camera.
    func startStreaming() {
        counterLock.lock(); defer { counterLock.unlock() }
        streamingCounter += 1
        if streamingCounter == 1 {
            extLog.info("first client started streaming — starting engine")
            engine.start()
        }
    }

    /// Called when an app stops using the camera. The real camera is released when the last one stops.
    func stopStreaming() {
        counterLock.lock(); defer { counterLock.unlock() }
        streamingCounter = max(0, streamingCounter - 1)
        if streamingCounter == 0 {
            extLog.info("last client stopped — stopping engine")
            engine.stop()
        }
    }

    private func send(_ pixelBuffer: CVPixelBuffer) {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: kFrameRate),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     dataReady: true,
                                                     makeDataReadyCallback: nil,
                                                     refcon: nil,
                                                     formatDescription: videoDescription,
                                                     sampleTiming: &timing,
                                                     sampleBufferOut: &sampleBuffer)
        guard err == noErr, let sampleBuffer else {
            extLog.error("CMSampleBufferCreateForImageBuffer failed: \(err)")
            return
        }
        let hostTime = UInt64(max(0, timing.presentationTimeStamp.seconds) * Double(NSEC_PER_SEC))
        streamSource.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTime)
    }
}

// MARK: - Stream

final class VanishStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    private let engine: VanishEngine

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat,
         device: CMIOExtensionDevice, engine: VanishEngine) {
        self.device = device
        self.streamFormat = streamFormat
        self.engine = engine
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, modeProperty, commandProperty, statusProperty]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { props.frameDuration = CMTime(value: 1, timescale: kFrameRate) }
        if properties.contains(modeProperty) {
            props.setPropertyState(CMIOExtensionPropertyState(value: engine.currentMode.rawValue as NSString), forProperty: modeProperty)
        }
        if properties.contains(commandProperty) {
            props.setPropertyState(CMIOExtensionPropertyState(value: "" as NSString), forProperty: commandProperty)
        }
        if properties.contains(statusProperty) {
            props.setPropertyState(CMIOExtensionPropertyState(value: engine.statusJSON() as NSString), forProperty: statusProperty)
        }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { activeFormatIndex = index }

        if let state = streamProperties.propertiesDictionary[modeProperty],
           let value = state.value as? String,
           let mode = VanishMode(rawValue: value) {
            engine.setMode(mode)
        }
        // Commands arrive as "name:nonce" so sending the same command twice still registers as a change.
        if let state = streamProperties.propertiesDictionary[commandProperty],
           let value = state.value as? String,
           let name = value.split(separator: ":").first,
           let command = VanishCommand(rawValue: String(name)) {
            engine.handle(command)
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        guard let deviceSource = device.source as? VanishDeviceSource else { return }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? VanishDeviceSource else { return }
        deviceSource.stopStreaming()
    }
}
