import Vision
import CoreVideo
import QuartzCore

enum Gesture: String {
    case none, vSign, palmsTogether, gokuForehead
}

extension VanishMode {
    var triggerGesture: Gesture {
        switch self {
        case .normal, .particles: return .vSign
        case .naruto: return .palmsTogether
        case .goku: return .gokuForehead
        }
    }

    /// How long the gesture must be held before it fires.
    var gestureHold: Double { self == .goku ? 1.0 : 0.25 }
}

@inline(__always) func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

/// One detected hand, joints in pixel coordinates (origin bottom-left, same as Core Image).
struct Hand {
    typealias Joint = VNHumanHandPoseObservation.JointName
    private let points: [Joint: CGPoint]

    init?(_ observation: VNHumanHandPoseObservation, size: CGSize) {
        guard let all = try? observation.recognizedPoints(.all) else { return nil }
        var pts: [Joint: CGPoint] = [:]
        for (joint, p) in all where p.confidence > 0.3 {
            pts[joint] = CGPoint(x: p.location.x * size.width, y: p.location.y * size.height)
        }
        guard pts[.wrist] != nil, pts[.middleMCP] != nil else { return nil }
        points = pts
    }

    func point(_ joint: Joint) -> CGPoint? { points[joint] }
    var wrist: CGPoint { points[.wrist]! }
    /// Palm length — used to make every threshold independent of distance from the camera.
    var scale: CGFloat { max(1, dist(wrist, points[.middleMCP]!)) }

    private func extended(_ tip: Joint, _ pip: Joint) -> Bool {
        guard let t = points[tip], let p = points[pip] else { return false }
        return dist(wrist, t) > dist(wrist, p) * 1.15
    }

    private func curled(_ tip: Joint, _ pip: Joint) -> Bool {
        guard let t = points[tip], let p = points[pip] else { return true } // hidden fingers are usually folded
        return dist(wrist, t) < dist(wrist, p) * 1.05
    }

    private var twoFingersUp: Bool {
        extended(.indexTip, .indexPIP) && extended(.middleTip, .middlePIP)
            && curled(.ringTip, .ringPIP) && curled(.littleTip, .littlePIP)
    }

    private var tipGap: CGFloat {
        guard let a = points[.indexTip], let b = points[.middleTip] else { return .infinity }
        return dist(a, b) / scale
    }

    var isVSign: Bool { twoFingersUp && tipGap > 0.35 }
    var isGokuFingers: Bool { twoFingersUp && tipGap < 0.3 }

    var fingersPointUp: Bool {
        guard let tip = points[.middleTip] ?? points[.indexTip] else { return false }
        return tip.y > wrist.y + scale * 0.5
    }

    func touchesForehead(of face: CGRect) -> Bool {
        guard let a = points[.indexTip], let b = points[.middleTip] else { return false }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        // Vision's face box ends around the eyebrows, so the forehead straddles its top edge.
        let zone = CGRect(x: face.minX - face.width * 0.15,
                          y: face.maxY - face.height * 0.35,
                          width: face.width * 1.3,
                          height: face.height * 0.8)
        return zone.contains(mid)
    }
}

final class GestureDetector {
    private let handRequest: VNDetectHumanHandPoseRequest
    private let faceRequest = VNDetectFaceRectanglesRequest()
    /// Fingers on the forehead often hide the face, so the last face box stays valid for a moment.
    private var lastFace: (rect: CGRect, time: CFTimeInterval)?

    init() {
        handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 2
    }

    func detect(in buffer: CVPixelBuffer, mode: VanishMode, now: CFTimeInterval) -> Gesture {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        var requests: [VNRequest] = [handRequest]
        if mode == .goku { requests.append(faceRequest) }
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform(requests)
        } catch {
            return .none
        }
        let hands = (handRequest.results ?? []).compactMap { Hand($0, size: size) }

        switch mode {
        case .normal, .particles:
            return hands.contains(where: { $0.isVSign }) ? .vSign : .none

        case .naruto:
            return Self.palmsTogether(hands) ? .palmsTogether : .none

        case .goku:
            if let face = (faceRequest.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
                lastFace = (VNImageRectForNormalizedRect(face.boundingBox, Int(size.width), Int(size.height)), now)
            }
            guard let face = lastFace, now - face.time < 1.5 else { return .none }
            return hands.contains(where: { $0.isGokuFingers && $0.touchesForehead(of: face.rect) }) ? .gokuForehead : .none
        }
    }

    private static func palmsTogether(_ hands: [Hand]) -> Bool {
        guard hands.count >= 2 else { return false }
        let a = hands[0], b = hands[1]
        let s = (a.scale + b.scale) / 2
        guard let ta = a.point(.middleTip) ?? a.point(.indexTip),
              let tb = b.point(.middleTip) ?? b.point(.indexTip) else { return false }
        return dist(a.wrist, b.wrist) < 1.4 * s
            && dist(ta, tb) < 0.9 * s
            && a.fingersPointUp && b.fingersPointUp
    }
}
