import AVFoundation

/// Reads frames from the Mac's real camera (never from our own virtual camera).
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum CaptureError: Error { case noCamera, configuration(String) }

    var onFrame: ((CVPixelBuffer) -> Void)?
    private(set) var deviceName = ""

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue: DispatchQueue
    private var configured = false

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    static func authorize(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
        default: completion(false)
        }
    }

    /// Prefers the built-in FaceTime camera, then any external webcam. Skips virtual cameras
    /// (including ourselves) so the extension never feeds on its own output.
    static func pickPhysicalCamera() -> AVCaptureDevice? {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        } else {
            types += [.externalUnknown]
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        let physical = devices.filter { device in
            let name = device.localizedName.lowercased()
            return device.modelID != VanishIPC.modelID && !name.contains("vanish") && !name.contains("virtual")
        }
        return physical.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? physical.first
    }

    func start() throws {
        if !configured {
            guard let device = Self.pickPhysicalCamera() else { throw CaptureError.noCamera }
            let input = try AVCaptureDeviceInput(device: device)

            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw CaptureError.configuration("cannot add camera input")
            }
            session.addInput(input)
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high

            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw CaptureError.configuration("cannot add video output")
            }
            session.addOutput(output)
            session.commitConfiguration()

            deviceName = device.localizedName
            configured = true
        }
        if !session.isRunning { session.startRunning() }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
