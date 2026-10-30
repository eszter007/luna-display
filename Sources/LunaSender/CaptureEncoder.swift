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
    /// With the strips that changed since the last encoded frame (bitmask).
    private var pendingFrame: (CVPixelBuffer, CMTime, UInt8)?
    private var sentFirstFrame = false
    /// Menu bar changes (clock, the screen recording indicator, which pulses)
    /// go out at most 10 times a second instead of forcing two full-height
    /// strips into almost every frame. Capture queue only.
    private var menuBarOwed: UInt8 = 0
    private var lastMenuBarFlush: CFTimeInterval = 0
    private var menuBarFlushScheduled = false
    private var lastFrame: CVPixelBuffer?
    private var skippedOwed: UInt8 = 0
    private var draining = false
    private lazy var splitter = StripSplitter()

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
    /// Called once every tile of a frame is encoded, with the seconds since
    /// it was handed to the encoder.
    var onFrameEncoded: ((Double) -> Void)?
    /// Seconds to copy a strip out of the captured frame (5K only).
    var onStripCopied: ((Double) -> Void)?
    /// Test harness: seconds from the test window's last move to its capture.
    var onChangeCaptured: ((Double) -> Void)?
    private let encodeTimesLock = NSLock()
    private var encodeStarts: [Int64: (start: CFTimeInterval, tilesLeft: Int, tiles: UInt8)] = [:]
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
        encoderConfig.tenBit = config.hevc
        // TCP loses nothing, so keyframes are only a safety net; each one is
        // a burst several times a normal frame.
        encoderConfig.keyframeInterval = 10
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
                    guard let self else { return }
                    let tiles = self.tilesSent(pts)
                    self.tileEncoded(pts)
                    self.onPacket?(LunaWire.hevcFrameData(tile: tile, tiles: tiles, ptsMicros: pts, keyframe: keyframe, data: data))
                }
            } else {
                encoder.onParameterSets = { [weak self] sets in
                    self?.onPacket?(LunaWire.paramSetsData(sps: sets[0], pps: sets[1]))
                }
                encoder.onEncodedFrame = { [weak self] pts, keyframe, avcc in
                    self?.tileEncoded(pts)
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
        // Full range P3; 10-bit for HEVC: 8 bits banded visibly in gradients
        // once compressed (10-bit costs ~12% more encode time).
        conf.pixelFormat = config.hevc
            ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
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

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let since = TestProbe.sinceLastMove() { onChangeCaptured?(since) }
        lastFrame = pixelBuffer
        let dirty = changedStrips(attachments, width: CVPixelBufferGetWidth(pixelBuffer))
        // Changes of a frame not sent (network backed up) are owed to the next.
        var changed = dirty.content | skippedOwed
        if shouldDropFrame?() == true {
            framesDropped += 1
            skippedOwed = changed | dirty.menuBar
            return
        }
        skippedOwed = 0
        menuBarOwed |= dirty.menuBar & ~changed
        let now = CACurrentMediaTime()
        if menuBarOwed != 0, now - lastMenuBarFlush >= 0.1 {
            changed |= menuBarOwed
            menuBarOwed = 0
            lastMenuBarFlush = now
        } else if menuBarOwed != 0, !menuBarFlushScheduled {
            // Nothing else may change for a while; don't strand the update.
            menuBarFlushScheduled = true
            captureQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.flushMenuBar() }
        }
        guard changed != 0 else { return }
        submit(pixelBuffer, pts: pts, changed: changed)
    }

    /// Capture queue: sends menu bar changes still owed, on the latest frame.
    private func flushMenuBar() {
        menuBarFlushScheduled = false
        guard menuBarOwed != 0, let pixelBuffer = lastFrame else { return }
        let changed = menuBarOwed
        menuBarOwed = 0
        lastMenuBarFlush = CACurrentMediaTime()
        // A fresh timestamp: the encoders need them strictly increasing.
        submit(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()), changed: changed)
    }

    /// Capture queue. Never makes ScreenCaptureKit wait: an encode call
    /// blocks for the whole encode, and while the capture callback runs SCK
    /// queues new frames, each then arriving that much later. Hands over the
    /// newest frame and returns; the encode queue takes the newest one waiting.
    private func submit(_ pixelBuffer: CVPixelBuffer, pts: CMTime, changed: UInt8) {
        var changed = changed
        pendingLock.lock()
        let replaced = pendingFrame != nil
        // A frame replaced before it was encoded still owes its changes.
        changed |= pendingFrame?.2 ?? 0
        pendingFrame = (pixelBuffer, pts, changed)
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
            guard let (pixelBuffer, pts, changed) = pendingFrame else {
                draining = false
                pendingLock.unlock()
                return
            }
            pendingFrame = nil
            pendingLock.unlock()
            encode(pixelBuffer, pts: pts, changed: changed)
        }
    }

    /// Bitmasks of the strips ScreenCaptureKit reports dirty in this frame:
    /// by changes below the menu bar, and by changes within it.
    private func changedStrips(_ attachments: [String: Any], width: Int) -> (content: UInt8, menuBar: UInt8) {
        let count = encoders.count
        let all = UInt8(truncatingIfNeeded: (1 << count) - 1)
        guard count > 1,
              let rects = attachments[SCStreamFrameInfo.dirtyRects.rawValue] as? [NSDictionary]
        else { return (all, 0) }
        let stripWidth = CGFloat(width) / CGFloat(count)
        // Pixels from the top; the 5K Retina menu bar is ~74 px tall.
        let menuBarBottom: CGFloat = 80
        var content: UInt8 = 0
        var menuBar: UInt8 = 0
        for dict in rects {
            guard let rect = CGRect(dictionaryRepresentation: dict as CFDictionary), !rect.isEmpty else { continue }
            let first = max(0, min(count - 1, Int(rect.minX / stripWidth)))
            let last = max(0, min(count - 1, Int((rect.maxX - 1) / stripWidth)))
            for strip in first ... last {
                if rect.maxY <= menuBarBottom { menuBar |= 1 << strip } else { content |= 1 << strip }
            }
        }
        return (content, menuBar)
    }

    private func tilesSent(_ pts: Int64) -> UInt8 {
        encodeTimesLock.lock()
        defer { encodeTimesLock.unlock() }
        return encodeStarts[pts]?.tiles ?? 0
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, changed: UInt8) {
        let encoders = encoders
        guard !encoders.isEmpty else { return }
        // The receiver has nothing yet: the first frame carries every strip.
        let tiles = sentFirstFrame ? changed : UInt8(truncatingIfNeeded: (1 << encoders.count) - 1)
        sentFirstFrame = true
        let indices = encoders.indices.filter { tiles & (1 << $0) != 0 }
        // Same rounding as VideoEncoder's ptsMicros, so acks match.
        let ptsMicros = Int64(CMTimeGetSeconds(pts) * 1_000_000)
        onFrameSubmitted?(ptsMicros)
        encodeTimesLock.lock()
        encodeStarts[ptsMicros] = (CACurrentMediaTime(), indices.count, tiles)
        encodeTimesLock.unlock()
        if encoders.count == 1 {
            encoders[0].encode(pixelBuffer, pts: pts)
            return
        }
        let splitStart = CACurrentMediaTime()
        guard let strips = splitter?.split(pixelBuffer, strips: indices, of: encoders.count) else { return }
        onStripCopied?(CACurrentMediaTime() - splitStart)
        // Only changed strips are encoded: the encoder's time scales with the
        // pixels (5K: ~4 ms per strip of four, ~16 ms for all). Wait until
        // they are out before taking the next frame. At 5K60 the encoder is
        // near its limit; frames handed over freely queued up inside it and
        // every frame then waited ~43 ms instead of ~20. drainPendingFrames
        // meanwhile keeps only the newest capture.
        DispatchQueue.concurrentPerform(iterations: indices.count) { n in
            let encoder = encoders[indices[n]]
            encoder.encode(strips[n], pts: pts)
            encoder.waitForFrames(through: pts)
        }
    }

    /// Encoder callback threads.
    private func tileEncoded(_ pts: Int64) {
        encodeTimesLock.lock()
        guard let entry = encodeStarts[pts] else {
            encodeTimesLock.unlock()
            return
        }
        if entry.tilesLeft > 1 {
            encodeStarts[pts] = (entry.start, entry.tilesLeft - 1, entry.tiles)
            encodeTimesLock.unlock()
            return
        }
        encodeStarts = encodeStarts.filter { $0.key > pts }
        encodeTimesLock.unlock()
        onFrameEncoded?(CACurrentMediaTime() - entry.start)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Capture stopped: \(error.localizedDescription)")
    }
}
