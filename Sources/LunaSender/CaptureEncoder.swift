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
    private let encodeQueue = DispatchQueue(label: "luna.encode", qos: .userInteractive)
    /// Newest captured frame not yet picked up by the encode queue.
    private let pendingLock = NSLock()
    private var pendingFrame: (CVPixelBuffer, CMTime)?
    private var draining = false
    private var tilePool: CVPixelBufferPool?

    /// Called with wire-ready packets (paramSets / frame envelopes).
    var onPacket: ((Data) -> Void)?
    /// Return true when the network is backed up and this frame should be
    /// dropped before encoding (frame-rate adapts, stream stays valid).
    var shouldDropFrame: (() -> Bool)?
    /// Called on the capture queue for every frame handed to the encoder,
    /// with the timestamp the receiver will ack (host time, microseconds).
    var onFrameSubmitted: ((Int64) -> Void)?
    /// Called when a captured frame is replaced by a newer one before the
    /// encoder got to it.
    var onFrameSkipped: (() -> Void)?
    var onError: ((String) -> Void)?

    var framesSent: Int { encoders.first?.framesEncoded ?? 0 }
    private(set) var framesDropped = 0

    /// Only the YCbCr matrix: the receiver converts to RGB with it and labels
    /// the result Display P3 itself. Primaries/transfer tags here must not
    /// differ from the frames' own: ScreenCaptureKit labels its (P3) frames
    /// Rec. 709, and on any mismatch VideoToolbox "converts" every frame on a
    /// slow path (~100 ms at 5K) that also drains saturation.
    static let colorProperties: [CFString: CFString] = [
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
        // Never make ScreenCaptureKit wait: an encode call blocks for the
        // whole encode, and while this callback runs SCK queues new frames,
        // each then arriving that much later. Hand over the newest frame and
        // return; the encode queue always takes the newest one waiting.
        pendingLock.lock()
        let replaced = pendingFrame != nil
        pendingFrame = (pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let startDraining = !draining
        draining = true
        pendingLock.unlock()
        if replaced { onFrameSkipped?() }
        if startDraining {
            encodeQueue.async { [weak self] in self?.drainPendingFrames() }
        }
    }

    /// Encode queue.
    private func drainPendingFrames() {
        while true {
            pendingLock.lock()
            guard let (pixelBuffer, pts) = pendingFrame else {
                draining = false
                pendingLock.unlock()
                return
            }
            pendingFrame = nil
            pendingLock.unlock()
            encode(pixelBuffer, pts: pts)
        }
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let encoders = encoders
        guard !encoders.isEmpty else { return }
        // Same rounding as VideoEncoder's ptsMicros, so acks match.
        onFrameSubmitted?(Int64(CMTimeGetSeconds(pts) * 1_000_000))
        if encoders.count == 1 {
            encoders[0].encode(pixelBuffer, pts: pts)
            return
        }
        // Both halves at once; one after the other they would take twice as long.
        makeTilePool(for: pixelBuffer, count: encoders.count)
        DispatchQueue.concurrentPerform(iterations: encoders.count) { index in
            guard let strip = copyStrip(pixelBuffer, index: index, count: encoders.count) else { return }
            encoders[index].encode(strip, pts: pts)
        }
    }

    /// Encode queue, before the strips are copied in parallel.
    private func makeTilePool(for source: CVPixelBuffer, count: Int) {
        guard tilePool == nil else { return }
        let width = CVPixelBufferGetWidth(source) / count
        let height = CVPixelBufferGetHeight(source)
        do {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &tilePool)
        }
    }

    /// Copies one vertical strip of a bi-planar 4:2:0 frame into a pooled
    /// buffer. ponytail: CPU copy, about 2 ms per 5K frame on Apple Silicon;
    /// a VTPixelTransferSession crop would move it to the GPU if that matters.
    private func copyStrip(_ source: CVPixelBuffer, index: Int, count: Int) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source) / count
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
