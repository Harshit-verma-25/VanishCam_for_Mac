import CoreImage
import CoreGraphics
import os.log

/// Swift wrappers around the Metal kernels in Effects.metal, with plain Core Image
/// fallbacks so the camera still works if a kernel fails to load.
final class EffectKernels {
    private let fillKernel: CIKernel?
    private let dissolveKernel: CIKernel?
    private let gokuKernel: CIKernel?
    private let particlesKernel: CIKernel?
    private let smokeKernel: CIKernel?

    init() {
        var data: Data?
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib") {
            data = try? Data(contentsOf: url)
        }
        func load(_ name: String) -> CIKernel? {
            guard let data else { return nil }
            do { return try CIKernel(functionName: name, fromMetalLibraryData: data) }
            catch { extLog.error("kernel \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"); return nil }
        }
        if data == nil { extLog.error("default.metallib not found — effects fall back to simple blends") }
        fillKernel = load("vanishFill")
        dissolveKernel = load("vanishDissolve")
        gokuKernel = load("vanishGoku")
        particlesKernel = load("vanishParticles")
        smokeKernel = load("narutoSmoke")
    }

    private let samePixel: CIKernelROICallback = { _, rect in rect }

    func fill(plate: CIImage, coverage: CIImage,
              blurPremul: CIImage, blurCov: CIImage,
              blurPremul2: CIImage, blurCov2: CIImage, extent: CGRect) -> CIImage {
        guard let k = fillKernel else { return plate }
        return k.apply(extent: extent, roiCallback: samePixel,
                       arguments: [plate, coverage, blurPremul, blurCov, blurPremul2, blurCov2]) ?? plate
    }

    func dissolve(live: CIImage, background: CIImage, mask: CIImage, noise: CIImage,
                  progress: Double, extent: CGRect) -> CIImage {
        guard let k = dissolveKernel else {
            return Self.simpleHide(live: live, background: background, mask: mask, amount: progress)
        }
        return k.apply(extent: extent, roiCallback: samePixel,
                       arguments: [live, background, mask, noise, Float(progress)]) ?? live
    }

    func goku(live: CIImage, background: CIImage, mask: CIImage, tallMask: CIImage,
              t: Double, extent: CGRect) -> CIImage {
        guard let k = gokuKernel else {
            return Self.simpleHide(live: live, background: background, mask: mask, amount: t)
        }
        return k.apply(extent: extent, roiCallback: samePixel,
                       arguments: [live, background, mask, tallMask, Float(t), Float(extent.height)]) ?? live
    }

    func particles(base: CIImage, snapshot: CIImage, snapshotMask: CIImage,
                   t: Double, cell: Double, extent: CGRect) -> CIImage {
        guard let k = particlesKernel else {
            return Self.simpleHide(live: snapshot, background: base, mask: snapshotMask, amount: t)
        }
        // Fragments can come from far away, so every output tile may read the whole frame.
        return k.apply(extent: extent, roiCallback: { _, _ in extent },
                       arguments: [base, snapshot, snapshotMask, Float(t), Float(cell), Float(extent.width)]) ?? base
    }

    func smoke(base: CIImage, center: CGPoint, radius: CGFloat, t: Double, seed: Float, extent: CGRect) -> CIImage {
        guard let k = smokeKernel else { return base }
        return k.apply(extent: extent, roiCallback: samePixel,
                       arguments: [base, CIVector(x: center.x, y: center.y), Float(radius), Float(t), seed]) ?? base
    }

    /// Fallback: cross-fade the person into the background.
    private static func simpleHide(live: CIImage, background: CIImage, mask: CIImage, amount: Double) -> CIImage {
        let a = CGFloat(max(0, min(1, amount)))
        let scaled = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
        ])
        return background.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: live, kCIInputMaskImageKey: scaled,
        ])
    }
}

/// The substitution log for Naruto mode, drawn in code (no external art).
enum LogArt {
    static func make() -> CIImage {
        let w = 200, h = 560
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CIImage.empty() }

        let body = CGRect(x: 12, y: 8, width: CGFloat(w - 24), height: CGFloat(h - 50))
        let bodyPath = CGPath(roundedRect: body, cornerWidth: 26, cornerHeight: 18, transform: nil)

        // Bark: horizontal shading so it reads as a cylinder.
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        let bark = [CGColor(red: 0.30, green: 0.18, blue: 0.09, alpha: 1),
                    CGColor(red: 0.58, green: 0.38, blue: 0.20, alpha: 1),
                    CGColor(red: 0.45, green: 0.28, blue: 0.14, alpha: 1),
                    CGColor(red: 0.24, green: 0.14, blue: 0.07, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: bark, locations: [0, 0.35, 0.7, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: body.minX, y: 0), end: CGPoint(x: body.maxX, y: 0), options: [])
        }
        // Grain lines.
        ctx.setStrokeColor(CGColor(red: 0.20, green: 0.11, blue: 0.05, alpha: 0.75))
        ctx.setLineWidth(3)
        for i in 0..<8 {
            let x = body.minX + 14 + CGFloat(i) * (body.width - 28) / 7
            ctx.move(to: CGPoint(x: x, y: body.minY))
            ctx.addCurve(to: CGPoint(x: x + 4, y: body.maxY),
                         control1: CGPoint(x: x + 9, y: body.minY + body.height * 0.33),
                         control2: CGPoint(x: x - 7, y: body.minY + body.height * 0.66))
        }
        ctx.strokePath()
        // A knot.
        ctx.setFillColor(CGColor(red: 0.22, green: 0.12, blue: 0.06, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: body.midX + 10, y: body.minY + body.height * 0.45, width: 26, height: 40))
        ctx.restoreGState()

        // Cut face on top with growth rings.
        let top = CGRect(x: body.minX, y: body.maxY - 34, width: body.width, height: 68)
        ctx.setFillColor(CGColor(red: 0.86, green: 0.70, blue: 0.47, alpha: 1))
        ctx.fillEllipse(in: top)
        ctx.setStrokeColor(CGColor(red: 0.62, green: 0.44, blue: 0.24, alpha: 1))
        ctx.setLineWidth(2.5)
        for i in 1...4 {
            let inset = CGFloat(i) * 15
            ctx.strokeEllipse(in: top.insetBy(dx: inset, dy: inset * 0.34))
        }

        // Outline for the cartoon look.
        ctx.setStrokeColor(CGColor(red: 0.12, green: 0.07, blue: 0.03, alpha: 1))
        ctx.setLineWidth(4)
        ctx.addPath(bodyPath)
        ctx.strokePath()
        ctx.strokeEllipse(in: top)

        guard let image = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: image)
    }
}
