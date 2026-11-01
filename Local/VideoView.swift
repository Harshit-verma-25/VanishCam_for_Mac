import SwiftUI
import AVFoundation

/// Fans each engine frame out to every visible video layer. The layer list is main-thread only.
final class FrameSink {
    private let layers = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()

    func add(_ layer: AVSampleBufferDisplayLayer) { layers.add(layer) }

    /// Called on the engine queue.
    func push(_ buffer: CVPixelBuffer) {
        DispatchQueue.main.async { [self] in
            guard let sample = Self.makeSample(buffer) else { return }
            for layer in layers.allObjects {
                if layer.status == .failed { layer.flush() }
                layer.enqueue(sample)
            }
        }
    }

    private static func makeSample(_ buffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                 formatDescription: format, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return nil }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        return sample
    }
}

struct VideoView: NSViewRepresentable {
    let sink: FrameSink

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        sink.add(view.videoLayer)
        return view
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {}
}

final class VideoLayerView: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        layer = videoLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
