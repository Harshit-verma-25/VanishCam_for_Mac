import Foundation
import AVFoundation
import CoreImage
import CoreText
import Metal
import QuartzCore
import Vision
import os.log

/// Camera in → person segmentation + gesture detection → effect → frame out.
/// Everything stateful runs on `queue`; the public methods are safe to call from any thread.
final class VanishEngine {
    enum Phase: Equatable {
        case visible
        case vanishing(start: CFTimeInterval)
        case vanished
        case reappearing(start: CFTimeInterval)

        var name: String {
            switch self {
            case .visible: return "visible"
            case .vanishing: return "vanishing"
            case .vanished: return "vanished"
            case .reappearing: return "reappearing"
            }
        }
    }

    private enum RecaptureStage { case none, leave, capturing }

    var onFrame: ((CVPixelBuffer) -> Void)?

    let width: Int
    let height: Int
    private let extent: CGRect
    private let queue = DispatchQueue(label: "VanishCam.engine", qos: .userInteractive)

    private lazy var capture = CameraCapture(queue: queue)
    private let ciContext: CIContext
    private let kernels = EffectKernels()
    private let gestures = GestureDetector()
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private let sequenceHandler = VNSequenceRequestHandler()
    private let outputPool: CVPixelBufferPool?
    private let workPool: CVPixelBufferPool?
    private lazy var logImage = LogArt.make()
    private lazy var noise: CIImage = makeNoise()

    // Engine-queue state
    private var running = false
    private var mode: VanishMode
    private var phase: Phase = .visible
    private var frameIndex = 0
    private var plate: CVPixelBuffer?          // learned empty background
    private var coverage: CVPixelBuffer?       // white where the background has actually been seen
    private var filledBuffer: CVPixelBuffer?
    private var filledBackground: CIImage?     // plate with unseen holes filled in
    private var recaptureStart: CFTimeInterval?
    private var recaptureResetDone = false
    private var gestureSince: CFTimeInterval?
    private var gestureArmed = true
    private var lastGestureSeen: CFTimeInterval = 0
    private var gestureProgress = 0.0
    private var needsSnapshot = false
    private var snapshotLive: CIImage?
    private var snapshotMask: CIImage?
    private var snapshotBuffers: [CVPixelBuffer] = []
    private var heldMask: CVPixelBuffer?       // last frame's mask while hidden, so a missed detection can't flash you
    private var anchor = CGRect.zero           // person bounds when they vanished (Naruto log position)
    private var smokeSeed: Float = 0
    private var fallbackTimer: DispatchSourceTimer?

    private let statusLock = NSLock()
    private var status = VanishStatus()

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        extent = CGRect(x: 0, y: 0, width: width, height: height)

        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            ciContext = CIContext(options: options)
        }

        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8

        outputPool = Self.makePool(width: width, height: height)
        workPool = Self.makePool(width: width, height: height)

        mode = VanishMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .normal
        status.mode = mode.rawValue
    }

    // MARK: Public API (any thread)

    func start() { queue.async { self.startOnQueue() } }
    func stop() { queue.async { self.stopOnQueue() } }
    /// For app termination: returns only after the camera is released and the background is saved.
    func stopAndWait() { queue.sync { self.stopOnQueue() } }

    func setMode(_ newMode: VanishMode) {
        queue.async {
            self.mode = newMode
            self.phase = .visible
            self.gestureSince = nil
            self.gestureArmed = true
            UserDefaults.standard.set(newMode.rawValue, forKey: "mode")
            self.publishStatus()
        }
    }

    func handle(_ command: VanishCommand) {
        queue.async {
            let now = CACurrentMediaTime()
            switch command {
            case .recapture:
                self.phase = .visible
                self.recaptureStart = now
                self.recaptureResetDone = false
            case .vanish:
                if self.phase == .visible { self.beginVanish(now) }
            case .reappear:
                if self.phase == .vanished { self.beginReappear(now) }
            }
            self.publishStatus()
        }
    }

    var currentMode: VanishMode {
        statusLock.lock(); defer { statusLock.unlock() }
        return VanishMode(rawValue: status.mode) ?? .normal
    }

    func statusJSON() -> String {
        statusLock.lock()
        let snapshot = status
        statusLock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Lifecycle

    private func startOnQueue() {
        guard !running else { return }
        running = true
        loadBackground()
        CameraCapture.authorize { granted in
            self.queue.async {
                guard self.running else { return }
                guard granted else {
                    self.setCamera("denied")
                    self.showMessage("Camera access needed",
                                     detail: "Open the VanishCam app and allow camera access in System Settings → Privacy & Security → Camera.")
                    return
                }
                do {
                    self.capture.onFrame = { [weak self] buffer in self?.process(buffer) }
                    try self.capture.start()
                    self.stopMessage()
                    self.setCamera("ok", name: self.capture.deviceName)
                } catch {
                    extLog.error("camera start failed: \(String(describing: error), privacy: .public)")
                    self.setCamera("missing")
                    self.showMessage("No camera found", detail: "Connect a webcam or close apps that are holding the camera.")
                }
            }
        }
    }

    private func stopOnQueue() {
        guard running else { return }
        running = false
        capture.stop()
        stopMessage()
        saveBackground()
        phase = .visible
        recaptureStart = nil
        setCamera("idle")
    }

    // MARK: Per-frame pipeline

    private func process(_ cameraBuffer: CVPixelBuffer) {
        guard running else { return }
        frameIndex &+= 1
        let now = CACurrentMediaTime()
        guard let input = normalized(cameraBuffer) else { return }
        let live = CIImage(cvPixelBuffer: input)

        let recapture = advanceRecapture(now)
        let backgroundTick = frameIndex % 6 == 0
        let needMask = phase != .visible || plate == nil || recapture == .capturing || backgroundTick

        var mask: CIImage?
        var maskBuffer: CVPixelBuffer?
        if needMask, let buffer = segment(input) {
            maskBuffer = buffer
            mask = maskImage(from: buffer)
        }
        if phase == .visible {
            heldMask = nil
        } else if let current = mask {
            mask = holdMask(current)
        }

        if let mask {
            if plate == nil {
                seedBackground(live: live, mask: mask)
            } else if recapture == .capturing {
                updateBackground(live: live, mask: mask, rate: 0.35)
            } else if recapture == .none && backgroundTick {
                updateBackground(live: live, mask: mask, rate: 0.12)
            }
        }

        if needsSnapshot, let mask, let maskBuffer {
            takeSnapshot(live: live, mask: mask, maskBuffer: maskBuffer)
        }

        if recapture == .none && frameIndex % 2 == 0 {
            handleGesture(gestures.detect(in: input, mode: mode, now: now), now: now)
        }

        advancePhase(now)

        let composed = compose(live: live, mask: mask, now: now)
        guard let pool = outputPool, let out = newBuffer(pool) else { return }
        ciContext.render(composed, to: out, bounds: extent, colorSpace: nil)
        if frameIndex % 5 == 0 { publishStatus() }
        onFrame?(out)
    }

    /// Scales/crops whatever the camera delivers to exactly width × height BGRA.
    private func normalized(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
           CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
            return buffer
        }
        let image = CIImage(cvPixelBuffer: buffer)
        let s = max(CGFloat(width) / image.extent.width, CGFloat(height) / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let dx = (scaled.extent.width - CGFloat(width)) / 2
        let dy = (scaled.extent.height - CGFloat(height)) / 2
        let fitted = scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy)).cropped(to: extent)
        return render(fitted)
    }

    private func segment(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        do {
            try sequenceHandler.perform([segmentation], on: buffer, orientation: .up)
            return segmentation.results?.first?.pixelBuffer
        } catch {
            return nil
        }
    }

    /// Vision mask → full-size, grown and softened so no outline of you is left behind.
    /// Low-confidence pixels (hair, edges, backlit shoulders) are boosted to fully "person".
    private func maskImage(from buffer: CVPixelBuffer) -> CIImage {
        let m = CIImage(cvPixelBuffer: buffer)
        return m.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / m.extent.width,
                                                   y: CGFloat(height) / m.extent.height))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 3, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 3, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 3, y: 0, z: 0, w: 0),
            ])
            .applyingFilter("CIColorClamp")
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 10])
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 4)
            .cropped(to: extent)
    }

    /// While hidden, keeps a fading copy of earlier masks so fast moves and dropped detections stay covered.
    private func holdMask(_ mask: CIImage) -> CIImage {
        var held = mask
        if let previous = heldMask {
            let faded = CIImage(cvPixelBuffer: previous).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.85, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.85, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.85, w: 0),
            ])
            held = mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: faded])
        }
        heldMask = render(held)
        return heldMask.map { CIImage(cvPixelBuffer: $0) } ?? held
    }

    /// Where it's safe to learn the room: well away from anything that might be you.
    /// Done at quarter size because the wide grow is the expensive part.
    private func learnableArea(_ mask: CIImage) -> CIImage {
        mask.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 8])
            .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 6)
            .cropped(to: extent)
            .applyingFilter("CIColorInvert")
    }

    // MARK: Background model

    private func advanceRecapture(_ now: CFTimeInterval) -> RecaptureStage {
        guard let start = recaptureStart else { return .none }
        let elapsed = now - start
        if elapsed < 3 { return .leave }                 // time to walk out of the frame
        if elapsed < 7 {
            if !recaptureResetDone, let black = render(CIImage(color: .black).cropped(to: extent)) {
                coverage = black                          // forget what we thought we knew
                recaptureResetDone = true
            }
            return .capturing
        }
        recaptureStart = nil
        recaptureResetDone = false
        saveBackground()
        return .none
    }

    private func recaptureInfo(_ now: CFTimeInterval) -> (String, Double) {
        guard let start = recaptureStart else { return ("", 0) }
        let elapsed = now - start
        return elapsed < 3 ? ("leave", 3 - elapsed) : ("capturing", max(0, 7 - elapsed))
    }

    private func seedBackground(live: CIImage, mask: CIImage) {
        plate = render(live)
        coverage = render(learnableArea(mask))
        refreshFilledBackground()
    }

    private func updateBackground(live: CIImage, mask: CIImage, rate: CGFloat) {
        guard let plate, let coverage else { return }
        let notPerson = learnableArea(mask)
        let weight = notPerson.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: rate, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: rate, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: rate, w: 0),
        ])
        let blended = live.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(cvPixelBuffer: plate),
            kCIInputMaskImageKey: weight,
        ])
        let grown = notPerson.applyingFilter("CIMaximumCompositing", parameters: [
            kCIInputBackgroundImageKey: CIImage(cvPixelBuffer: coverage),
        ])
        if let p = render(blended) { self.plate = p }
        if let c = render(grown) { self.coverage = c }
        refreshFilledBackground()
    }

    private func refreshFilledBackground() {
        guard let plate, let coverage else { return }
        let p = CIImage(cvPixelBuffer: plate)
        let c = CIImage(cvPixelBuffer: coverage)
        let premul = p.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .black).cropped(to: extent),
            kCIInputMaskImageKey: c,
        ])
        // Blur at quarter resolution — much cheaper, and it's going to be blurry anyway.
        func blur(_ image: CIImage, _ sigma: Double) -> CIImage {
            image.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
                .cropped(to: extent)
        }
        let filled = kernels.fill(plate: p, coverage: c,
                                  blurPremul: blur(premul, 8), blurCov: blur(c, 8),
                                  blurPremul2: blur(premul, 40), blurCov2: blur(c, 40),
                                  extent: extent)
        if let buffer = render(filled) {
            filledBuffer = buffer
            filledBackground = CIImage(cvPixelBuffer: buffer)
        }
    }

    /// "Background2": plates saved before the stricter learning area can hold a ghost of you, so they're not reused.
    private var storageDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VanishCam", isDirectory: true)
            .appendingPathComponent("Background2", isDirectory: true)
    }

    /// The background survives restarts, so on a normal day you can vanish without stepping out first.
    private func saveBackground() {
        guard let plate, let coverage, let dir = storageDirectory,
              let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? ciContext.writePNGRepresentation(of: CIImage(cvPixelBuffer: plate), to: dir.appendingPathComponent("plate.png"),
                                              format: .RGBA8, colorSpace: cs, options: [:])
        try? ciContext.writePNGRepresentation(of: CIImage(cvPixelBuffer: coverage), to: dir.appendingPathComponent("coverage.png"),
                                              format: .RGBA8, colorSpace: cs, options: [:])
    }

    private func loadBackground() {
        guard plate == nil, let dir = storageDirectory else { return }
        let opts: [CIImageOption: Any] = [.colorSpace: NSNull()]
        guard let p = CIImage(contentsOf: dir.appendingPathComponent("plate.png"), options: opts),
              let c = CIImage(contentsOf: dir.appendingPathComponent("coverage.png"), options: opts),
              p.extent.size == extent.size, c.extent.size == extent.size else { return }
        plate = render(p)
        coverage = render(c)
        refreshFilledBackground()
    }

    // MARK: Gestures & phases

    private func handleGesture(_ gesture: Gesture, now: CFTimeInterval) {
        if gesture == mode.triggerGesture {
            lastGestureSeen = now
            if gestureSince == nil { gestureSince = now }
        } else if now - lastGestureSeen > 0.35 {
            // Tolerate a few missed detections; a real release re-arms the trigger.
            gestureSince = nil
            gestureArmed = true
        }
        let held = gestureSince.map { now - $0 } ?? 0
        gestureProgress = gestureArmed ? min(1, held / mode.gestureHold) : 0
        guard gestureArmed, held >= mode.gestureHold else { return }

        switch phase {
        case .visible:
            beginVanish(now)
            gestureArmed = false
        case .vanished:
            beginReappear(now)
            gestureArmed = false
        default:
            break
        }
    }

    private func beginVanish(_ now: CFTimeInterval) {
        phase = .vanishing(start: now)
        needsSnapshot = true
        smokeSeed = Float.random(in: 0...100)
    }

    private func beginReappear(_ now: CFTimeInterval) {
        phase = .reappearing(start: now)
        needsSnapshot = true
        smokeSeed = Float.random(in: 0...100)
    }

    private func advancePhase(_ now: CFTimeInterval) {
        switch phase {
        case .vanishing(let start) where now - start >= mode.vanishDuration:
            phase = .vanished
        case .reappearing(let start) where now - start >= mode.reappearDuration:
            phase = .visible
            snapshotLive = nil
            snapshotMask = nil
            snapshotBuffers = []
        default:
            break
        }
    }

    private func takeSnapshot(live: CIImage, mask: CIImage, maskBuffer: CVPixelBuffer) {
        needsSnapshot = false
        if case .vanishing = phase {
            anchor = personBounds(maskBuffer) ?? CGRect(x: extent.midX - 200, y: 0, width: 400, height: extent.height * 0.8)
        }
        if let l = render(live), let m = render(mask) {
            snapshotBuffers = [l, m]
            snapshotLive = CIImage(cvPixelBuffer: l)
            snapshotMask = CIImage(cvPixelBuffer: m)
        }
    }

    /// Bounding box of the person in output pixel coordinates (origin bottom-left).
    private func personBounds(_ buffer: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in stride(from: 0, to: h, by: 2) {
            let row = pixels + y * bytesPerRow
            for x in stride(from: 0, to: w, by: 2) where row[x] > 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let sx = CGFloat(width) / CGFloat(w), sy = CGFloat(height) / CGFloat(h)
        // Buffer rows run top-down; Core Image runs bottom-up.
        return CGRect(x: CGFloat(minX) * sx, y: CGFloat(h - 1 - maxY) * sy,
                      width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
    }

    // MARK: Compositing

    private func compose(live: CIImage, mask: CIImage?, now: CFTimeInterval) -> CIImage {
        guard phase != .visible, let mask, let background = filledBackground else { return live }
        let hidden = background.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: live, kCIInputMaskImageKey: mask,
        ])

        switch phase {
        case .visible:
            return live

        case .vanished:
            return mode == .naruto ? overlayLog(on: hidden, fall: 1) : hidden

        case .vanishing(let start), .reappearing(let start):
            var vanishing = false
            if case .vanishing = phase { vanishing = true }
            let duration = vanishing ? mode.vanishDuration : mode.reappearDuration
            let p = max(0, min(1, (now - start) / duration))
            let t = vanishing ? p : 1 - p          // effect time: 0 = fully there, 1 = fully gone

            switch mode {
            case .normal:
                return kernels.dissolve(live: live, background: background, mask: mask, noise: noise, progress: t, extent: extent)
            case .particles:
                guard let snap = snapshotLive, let snapMask = snapshotMask else { return vanishing ? live : hidden }
                return kernels.particles(base: hidden, snapshot: snap, snapshotMask: snapMask, t: t, cell: 8, extent: extent)
            case .goku:
                let tall = mask.clampedToExtent()
                    .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 60, kCIInputAngleKey: Double.pi / 2])
                    .cropped(to: extent)
                return kernels.goku(live: live, background: background, mask: mask, tallMask: tall, t: t, extent: extent)
            case .naruto:
                return composeNaruto(live: live, hidden: hidden, p: p, vanishing: vanishing)
            }
        }
    }

    private func composeNaruto(live: CIImage, hidden: CIImage, p: Double, vanishing: Bool) -> CIImage {
        var base: CIImage
        if vanishing {
            base = p < 0.12 ? live : hidden
            if p >= 0.12 { base = overlayLog(on: base, fall: smoothstep(0.3, 0.75, p)) }
        } else {
            base = p < 0.3 ? hidden : live
            if p < 0.15 { base = overlayLog(on: base, fall: 1) }
        }
        let radius = max(180, max(anchor.width, anchor.height) * 0.75)
        return kernels.smoke(base: base, center: CGPoint(x: anchor.midX, y: anchor.midY),
                             radius: radius, t: p, seed: smokeSeed, extent: extent)
    }

    /// Log stands where you were, then tips over to the right and stays on the floor.
    private func overlayLog(on base: CIImage, fall: Double) -> CIImage {
        guard !logImage.extent.isEmpty else { return base }
        let logHeight = max(160, min(CGFloat(height) * 0.8, anchor.height * 0.7))
        let s = logHeight / logImage.extent.height
        let pivot = CGPoint(x: anchor.midX, y: max(20, anchor.minY + 10))
        let angle = -CGFloat(fall) * .pi / 2 * 0.92
        let rest = CGFloat(fall) * logImage.extent.width * s * 0.5   // lift so the fallen log rests on the floor
        let transform = CGAffineTransform(translationX: -logImage.extent.width / 2, y: 0)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y + rest))
        return logImage.transformed(by: transform).composited(over: base).cropped(to: extent)
    }

    // MARK: Status

    private func setCamera(_ state: String, name: String = "") {
        statusLock.lock()
        status.camera = state
        status.cameraName = name
        statusLock.unlock()
        publishStatus()
    }

    private func publishStatus() {
        let (stage, remaining) = recaptureInfo(CACurrentMediaTime())
        statusLock.lock()
        status.mode = mode.rawValue
        status.phase = phase.name
        status.recaptureStage = stage
        status.recaptureRemaining = remaining
        status.gestureProgress = gestureProgress
        statusLock.unlock()
    }

    // MARK: Message frames (no camera / no permission)

    private func showMessage(_ title: String, detail: String) {
        stopMessage()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.2)
        timer.setEventHandler { [weak self] in self?.emitMessageFrame(title: title, detail: detail) }
        timer.resume()
        fallbackTimer = timer
    }

    private func stopMessage() {
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    private func emitMessageFrame(title: String, detail: String) {
        guard let pool = outputPool, let buffer = newBuffer(pool), let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: cs,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1))
            ctx.fill(extent)
            drawCentered(title, size: 46, y: CGFloat(height) / 2 + 20, in: ctx)
            drawCentered(detail, size: 22, y: CGFloat(height) / 2 - 40, in: ctx, alpha: 0.7)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        onFrame?(buffer)
    }

    private func drawCentered(_ text: String, size: CGFloat, y: CGFloat, in ctx: CGContext, alpha: CGFloat = 1) {
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (CGFloat(width) - CGFloat(lineWidth)) / 2, y: y)
        CTLineDraw(line, ctx)
    }

    // MARK: Helpers

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                attrs as CFDictionary, &pool)
        return pool
    }

    private func newBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func render(_ image: CIImage) -> CVPixelBuffer? {
        guard let pool = workPool, let buffer = newBuffer(pool) else { return nil }
        ciContext.render(image, to: buffer, bounds: extent, colorSpace: nil)
        return buffer
    }

    /// Smooth value noise used by the dissolve, rendered once.
    private func makeNoise() -> CIImage {
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return CIImage(color: .gray).cropped(to: extent) }
        let cell: CGFloat = 14
        let small = random.cropped(to: CGRect(x: 0, y: 0, width: ceil(CGFloat(width) / cell) + 2,
                                              height: ceil(CGFloat(height) / cell) + 2))
        let smooth = small.samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 3)
            .cropped(to: extent)
        guard let cg = ciContext.createCGImage(smooth, from: extent) else { return smooth }
        return CIImage(cgImage: cg)
    }
}

@inline(__always) private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}
