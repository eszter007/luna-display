import Foundation
import LunaProto
import AVFoundation
import CoreMedia
import VideoToolbox

/// Hardware-decodes the H.264/HEVC stream to RGB and shows it in an
/// AVSampleBufferDisplayLayer. Decoding ourselves (instead of handing the
/// layer compressed samples) lets every frame be labeled Display P3 as plain
/// RGB, which macOS color-manages like any window. The 2020 iMac on Tahoe
/// mishandled the video color tags of compressed HEVC and showed it washed out.
final class VideoPipeline {
    let layer = AVSampleBufferDisplayLayer()
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    /// Called on the decoder's thread with each decoded frame's timestamp.
    var onDecoded: ((Int64) -> Void)?
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    init() {
        // The host view sizes each layer to exactly its part of the picture.
        layer.videoGravity = .resize
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func reset() {
        formatDescription = nil
        invalidateSession()
        layer.flush()
    }

    private func invalidateSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    deinit {
        invalidateSession()
    }

    /// What the sender always encodes (Display P3, sRGB curve, full range),
    /// set explicitly so the YCbCr to RGB conversion doesn't depend on the
    /// decoder reading them from the stream.
    private static let senderColorTags = [
        kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_P3_D65,
        kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_sRGB,
        kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        kCMFormatDescriptionExtension_FullRangeVideo: kCFBooleanTrue!,
    ] as CFDictionary

    /// SPS, PPS for H.264; VPS, SPS, PPS for HEVC.
    func setParameterSets(_ sets: [Data], hevc: Bool) {
        var desc: CMVideoFormatDescription?
        // Copy into one buffer so every pointer stays valid for the call.
        let joined = sets.reduce(Data(), +)
        let status: OSStatus = joined.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, !sets.isEmpty else { return OSStatus(-1) }
            let sizes = sets.map(\.count)
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(base + offset)
                offset += size
            }
            if hevc {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: Self.senderColorTags,
                    formatDescriptionOut: &desc
                )
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: sets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &desc
            )
        }
        guard status == noErr, let desc else {
            lunaLog("luna: could not create %@ format description (%d)", hevc ? "HEVC" : "H.264", status)
            return
        }
        formatDescription = desc
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: desc) {
            return
        }
        invalidateSession()
        // BGRA output: VideoToolbox converts with the stream's matrix and range;
        // the result is Display P3 RGB, labeled as such in show(_:pts:).
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if sessionStatus != noErr {
            lunaLog("luna: could not create the %@ decoder (%d)", hevc ? "HEVC" : "H.264", sessionStatus)
        }
        layer.flush()
    }

    private var framesEnqueued = 0
    private var framesWithoutFormat = 0
    private let counterLock = NSLock()
    private var framesDecoded = 0
    private var decodeErrors = 0
    /// Arrival time per frame timestamp, and arrival -> decoded durations.
    private var arrivals: [Int64: CFTimeInterval] = [:]
    private var decodeTimes: [Double] = []

    /// One line for the log: is this stream decoding and showing frames?
    var statusDescription: String {
        let status = ["unknown", "rendering", "failed"][min(layer.status.rawValue, 2)]
        let error = layer.status == .failed ? " (\(layer.error?.localizedDescription ?? "?"))" : ""
        counterLock.lock()
        defer { counterLock.unlock() }
        let ms = decodeTimes.map { $0 * 1000 }.sorted()
        let timing = ms.isEmpty ? "n/a" : String(format: "median %.0f ms, p90 %.0f ms", ms[ms.count / 2], ms[ms.count * 9 / 10])
        return "\(status)\(error), \(framesEnqueued) frames in, \(framesDecoded) decoded, \(decodeErrors) decode errors, "
            + "arrival->decoded \(timing), "
            + "\(framesWithoutFormat) without format, "
            + "format \(formatDescription.map { "\(CMVideoFormatDescriptionGetDimensions($0).width)x\(CMVideoFormatDescriptionGetDimensions($0).height)" } ?? "none")"
    }

    func enqueue(ptsMicros: Int64, data: Data) {
        guard let formatDescription, let session else {
            framesWithoutFormat += 1
            return
        }
        framesEnqueued += 1
        counterLock.lock()
        arrivals[ptsMicros] = CACurrentMediaTime()
        counterLock.unlock()

        if #available(macOS 11.0, *), layer.requiresFlushToResumeDecoding {
            layer.flush()
        }
        if layer.status == .failed {
            lunaLog("luna: display layer failed (%@), flushing", layer.error?.localizedDescription ?? "?")
            layer.flush()
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return }

        status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard status == noErr else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: ptsMicros, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }

        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, image, pts, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                self.counterLock.lock()
                self.decodeErrors += 1
                let first = self.decodeErrors == 1
                self.counterLock.unlock()
                if first { lunaLog("luna: decode failed (%d)", status) }
                return
            }
            self.show(image, pts: pts)
        }
    }

    /// Called on the decoder's thread.
    private func show(_ image: CVImageBuffer, pts: CMTime) {
        CVBufferSetAttachment(image, kCVImageBufferCGColorSpaceKey, Self.displayP3, .shouldPropagate)
        var desc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &desc
        ) == noErr, let desc else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: desc,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        // Show as soon as decoded; we chase lowest latency, not smoothness.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        let ptsMicros = pts.convertScale(1_000_000, method: .roundHalfAwayFromZero).value
        counterLock.lock()
        framesDecoded += 1
        if let arrived = arrivals.removeValue(forKey: ptsMicros) {
            decodeTimes.append(CACurrentMediaTime() - arrived)
        }
        counterLock.unlock()
        onDecoded?(ptsMicros)
        // Straight from the decoder's thread: a hop through the main thread
        // waited behind the window drawing.
        layer.enqueue(sampleBuffer)
    }
}
