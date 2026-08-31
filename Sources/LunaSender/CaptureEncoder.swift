import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import LunaProto
import LunaMedia

/// Captures a display with ScreenCaptureKit and encodes it to H.264,
/// emitting wire-ready packets.
@available(macOS 12.3, *)
final class CaptureEncoder: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Config {
        var displayID: CGDirectDisplayID
        var streamWidth: Int
        var streamHeight: Int
        var fps: Int
        var bitrate: Int
    }

    private let config: Config
    private let captureQueue = DispatchQueue(label: "luna.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var encoder: H264Encoder?

    /// Called with wire-ready packets (paramSets / frame envelopes).
    var onPacket: ((Data) -> Void)?
    /// Return true when the network is backed up and this frame should be
    /// dropped before encoding (frame-rate adapts, stream stays valid).
    var shouldDropFrame: (() -> Bool)?
    var onError: ((String) -> Void)?

    var framesSent: Int { encoder?.framesEncoded ?? 0 }
    private(set) var framesDropped = 0

    init(config: Config) {
        self.config = config
        super.init()
    }

    func start() {
        guard let encoder = H264Encoder(config: .init(
            width: config.streamWidth, height: config.streamHeight, fps: config.fps, bitrate: config.bitrate
        )) else {
            onError?("Could not create the H.264 encoder")
            return
        }
        encoder.onParameterSets = { [weak self] sps, pps in
            self?.onPacket?(LunaWire.paramSetsData(sps: sps, pps: pps))
        }
        encoder.onEncodedFrame = { [weak self] pts, keyframe, avcc in
            self?.onPacket?(LunaWire.frameData(ptsMicros: pts, keyframe: keyframe, avcc: avcc))
        }
        self.encoder = encoder

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            if let error {
                self.onError?("Screen capture unavailable: \(error.localizedDescription)")
                return
            }
            guard let display = content?.displays.first(where: { $0.displayID == self.config.displayID }) else {
                self.onError?("Virtual display not found by ScreenCaptureKit")
                return
            }
            self.startStream(display: display)
        }
    }

    private func startStream(display: SCDisplay) {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let conf = SCStreamConfiguration()
        conf.width = config.streamWidth
        conf.height = config.streamHeight
        conf.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        conf.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        conf.showsCursor = true
        conf.queueDepth = 4

        let stream = SCStream(filter: filter, configuration: conf, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        } catch {
            onError?("Could not attach capture output: \(error.localizedDescription)")
            return
        }
        stream.startCapture { [weak self] error in
            if let error {
                self?.onError?("Could not start capture: \(error.localizedDescription)")
            } else {
                lunaLog("luna: capture started on display %u", self?.config.displayID ?? 0)
            }
        }
        self.stream = stream
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        encoder?.invalidate()
        encoder = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]])?.first,
              let statusRaw = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let encoder
        else { return }

        if shouldDropFrame?() == true {
            framesDropped += 1
            return
        }
        encoder.encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Capture stopped: \(error.localizedDescription)")
    }
}
