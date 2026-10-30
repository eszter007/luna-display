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
        var hevc = false
        /// Vertical strips, each its own encoder session (HEVC only).
        var tiles = 1
    }

    private var config: Config
    private let captureQueue = DispatchQueue(label: "luna.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var encoders: [VideoEncoder] = []
    private var tilePool: CVPixelBufferPool?

    /// Called with wire-ready packets (paramSets / frame envelopes).
    var onPacket: ((Data) -> Void)?
    /// Return true when the network is backed up and this frame should be
    /// dropped before encoding (frame-rate adapts, stream stays valid).
    var shouldDropFrame: (() -> Bool)?
    var onError: ((String) -> Void)?

    var framesSent: Int { encoders.first?.framesEncoded ?? 0 }
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
        let tiles = config.hevc ? config.tiles : 1
        var encoderConfig = VideoEncoder.Config(
            width: config.streamWidth / tiles, height: config.streamHeight, fps: config.fps,
            bitrate: config.bitrate / tiles, colorProperties: Self.colorProperties
        )
        encoderConfig.hevc = config.hevc
        for tile in 0 ..< tiles {
            guard let encoder = VideoEncoder(config: encoderConfig) else {
                onError?("Could not create the \(config.hevc ? "HEVC" : "H.264") encoder")
                return
            }
            if config.hevc {
                encoder.onParameterSets = { [weak self] sets in
                    self?.onPacket?(LunaWire.hevcParamSetsData(tile: tile, sets: sets))
                }
                encoder.onEncodedFrame = { [weak self] pts, keyframe, data in
                    self?.onPacket?(LunaWire.hevcFrameData(tile: tile, ptsMicros: pts, keyframe: keyframe, data: data))
                }
            } else {
                encoder.onParameterSets = { [weak self] sets in
                    self?.onPacket?(LunaWire.paramSetsData(sps: sets[0], pps: sets[1]))
                }
                encoder.onEncodedFrame = { [weak self] pts, keyframe, avcc in
                    self?.onPacket?(LunaWire.frameData(ptsMicros: pts, keyframe: keyframe, avcc: avcc))
                }
            }
            encoders.append(encoder)
        }

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
        encoders.forEach { $0.invalidate() }
        encoders = []
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]])?.first,
              let statusRaw = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              !encoders.isEmpty
        else { return }

        if shouldDropFrame?() == true {
            framesDropped += 1
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if encoders.count == 1 {
            encoders[0].encode(pixelBuffer, pts: pts)
            return
        }
        for (index, encoder) in encoders.enumerated() {
            guard let strip = copyStrip(pixelBuffer, index: index, count: encoders.count) else { return }
            encoder.encode(strip, pts: pts)
        }
    }

    /// Copies one vertical strip of a bi-planar 4:2:0 frame into a pooled
    /// buffer. ponytail: CPU copy, about 2 ms per 5K frame on Apple Silicon;
    /// a VTPixelTransferSession crop would move it to the GPU if that matters.
    private func copyStrip(_ source: CVPixelBuffer, index: Int, count: Int) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source) / count
        let height = CVPixelBufferGetHeight(source)
        if tilePool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &tilePool)
        }
        var strip: CVPixelBuffer?
        guard let tilePool, CVPixelBufferPoolCreatePixelBuffer(nil, tilePool, &strip) == kCVReturnSuccess,
              let strip
        else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(strip, [])
        defer {
            CVPixelBufferUnlockBaseAddress(strip, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        for plane in 0 ..< CVPixelBufferGetPlaneCount(source) {
            // Both planes are one byte per luma column: Y, then interleaved CbCr at half height.
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(strip, plane)
            else { return nil }
            let fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let toStride = CVPixelBufferGetBytesPerRowOfPlane(strip, plane)
            for row in 0 ..< CVPixelBufferGetHeightOfPlane(strip, plane) {
                memcpy(to + row * toStride, from + row * fromStride + index * width, width)
            }
        }
        CVBufferPropagateAttachments(source, strip)
        return strip
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Capture stopped: \(error.localizedDescription)")
    }
}
