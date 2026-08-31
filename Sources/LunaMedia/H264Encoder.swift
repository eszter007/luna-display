import Foundation
import LunaProto
import VideoToolbox
import CoreMedia
import CoreVideo

/// Thin VideoToolbox H.264 encoder. Feed it pixel buffers, get back parameter
/// sets (whenever they change) and AVCC-framed access units. Used for the
/// screen stream on the sender and the camera stream on the receiver, so it
/// only relies on API available back to macOS 10.15.
public final class H264Encoder {
    public struct Config {
        public var width: Int
        public var height: Int
        public var fps: Int
        public var bitrate: Int
        /// Seconds between forced keyframes.
        public var keyframeInterval = 2

        public init(width: Int, height: Int, fps: Int, bitrate: Int) {
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrate = bitrate
        }
    }

    /// Emitted (on the encoder's callback thread) whenever the SPS/PPS change,
    /// always before the keyframe that uses them.
    public var onParameterSets: ((_ sps: Data, _ pps: Data) -> Void)?
    /// Emitted for every encoded access unit, AVCC framing (4-byte lengths).
    public var onEncodedFrame: ((_ ptsMicros: Int64, _ keyframe: Bool, _ avcc: Data) -> Void)?

    public private(set) var framesEncoded = 0

    private var session: VTCompressionSession?
    private var lastSPS: Data?
    private var lastPPS: Data?
    private var forceNextKeyframe = true

    /// Returns nil when no encoder could be created for this configuration.
    public init?(config: Config) {
        guard let session = Self.makeSession(config) else { return nil }
        self.session = session
    }

    private static func makeSession(_ config: Config) -> VTCompressionSession? {
        func create(spec: CFDictionary?) -> VTCompressionSession? {
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(config.width),
                height: Int32(config.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: spec,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
            return status == noErr ? session : nil
        }

        var session: VTCompressionSession?
        if #available(macOS 11.3, *) {
            // Low-latency rate control (Apple Silicon hardware encoder path).
            let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
            session = create(spec: spec as CFDictionary)
            if session == nil {
                lunaLog("luna: low-latency encoder unavailable, falling back")
            }
        }
        if session == nil {
            session = create(spec: nil)
        }
        guard let session else { return nil }

        func set(_ key: CFString, _ value: CFTypeRef) {
            let s = VTSessionSetProperty(session, key: key, value: value)
            if s != noErr {
                lunaLog("luna: encoder property %@ rejected (%d)", key as String, s)
            }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, config.bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, config.fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (config.fps * config.keyframeInterval) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, config.keyframeInterval as CFNumber)
        // Keep bitrate spikes bounded so latency stays flat on Wi-Fi.
        let bytesPerSecond = config.bitrate / 8 * 3 / 2
        set(kVTCompressionPropertyKey_DataRateLimits, [bytesPerSecond, 1] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    /// The next encoded frame will be a keyframe (with fresh parameter sets).
    public func requestKeyframe() {
        forceNextKeyframe = true
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        var properties: CFDictionary?
        if forceNextKeyframe {
            forceNextKeyframe = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard let self, status == noErr, let encoded else { return }
            self.emit(encoded)
        }
    }

    public func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    deinit {
        invalidate()
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]])?.first
        let notSync = attachments?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        let keyframe = !notSync

        if keyframe, let desc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            sendParameterSetsIfNeeded(desc)
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copyStatus == noErr else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsMicros = pts.isNumeric ? Int64(CMTimeGetSeconds(pts) * 1_000_000) : 0
        framesEncoded += 1
        onEncodedFrame?(ptsMicros, keyframe, data)
    }

    private func sendParameterSetsIfNeeded(_ desc: CMFormatDescription) {
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        var count = 0
        var nalHeaderLength: Int32 = 0

        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            desc, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength
        ) == noErr,
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            desc, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength
        ) == noErr,
        let spsPointer, let ppsPointer, nalHeaderLength == 4
        else {
            lunaLog("luna: unexpected parameter set layout (nal header %d)", nalHeaderLength)
            return
        }

        let sps = Data(bytes: spsPointer, count: spsSize)
        let pps = Data(bytes: ppsPointer, count: ppsSize)
        if sps != lastSPS || pps != lastPPS {
            lastSPS = sps
            lastPPS = pps
            onParameterSets?(sps, pps)
        }
    }
}
