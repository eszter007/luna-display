import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import VideoToolbox
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
        var showsCursor = true
    }

    private var config: Config
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

    /// Written into the H.264 VUI so the receiver color-manages the stream as
    /// Display P3 with the sRGB curve. Untagged video is shown with the
    /// Rec. 709 video gamma, which looks washed out for desktop content.
    static let colorProperties: [CFString: CFString] = [
        kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_P3_D65,
        kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_sRGB,
        kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
    ]

    init(config: Config) {
        self.config = config
        super.init()
    }

    func start() {
        guard let encoder = H264Encoder(config: .init(
            width: config.streamWidth, height: config.streamHeight, fps: config.fps, bitrate: config.bitrate,
            colorProperties: Self.colorProperties
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
        // Full range P3 so the stream matches the color tags in colorProperties.
        conf.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        conf.colorSpaceName = CGColorSpace.displayP3
        conf.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        conf.showsCursor = config.showsCursor
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
        self.streamConfig = conf
    }

    private var streamConfig: SCStreamConfiguration?

    /// Leave the cursor out of the video once the receiver draws it itself.
    func hideCursor() {
        config.showsCursor = false
        guard let stream, let streamConfig else { return }
        streamConfig.showsCursor = false
        stream.updateConfiguration(streamConfig) { error in
            if let error { lunaLog("luna: could not hide the captured cursor: %@", error.localizedDescription) }
        }
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
