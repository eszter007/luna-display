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
    /// Called on the decoder's thread with each decoded frame's timestamp,
    /// the seconds from its arrival to decoded, and how many tiles that frame has.
    var onDecoded: ((Int64, Double, Int) -> Void)?
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    private static func fourCC(_ code: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
    }
    /// `defaults write local.luna.receiver decodeToRGB -bool true`: convert
    /// to RGB in the decoder (the older path, ~2 ms more per 5K half on the
    /// 2020 iMac, whose decoder handles the halves one after the other).
    private static let decodeToRGB = UserDefaults.standard.bool(forKey: "decodeToRGB")
    /// The colors the sender's frames are in, attached to every decoded frame
    /// so the display doesn't depend on what the decoder carried over.
    private static let frameColors: [CFString: CFTypeRef] = [
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_P3_D65,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_sRGB,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        kCVImageBufferCGColorSpaceKey: displayP3,
    ]

    /// Shared by all tiles of a stream, with this pipeline's tile index.
    private let tileSync: TileSync
    private let tile: Int

    init(tile: Int = 0, sync: TileSync = TileSync()) {
        self.tile = tile
        tileSync = sync
        // The host view sizes each layer to exactly its part of the picture.
        layer.videoGravity = .resize
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func reset() {
        tileSync.reset()
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
        // Native full-range 4:2:0 out of the decoder, labeled in show(_:pts:);
        // the display converts on the GPU. 3.9 vs 5.8 ms per 5K half on the
        // iMac. HEVC is 10-bit (Main10): keep all 10 bits to the display,
        // 2.0 ms per strip, where 8-bit output would bring the banding back.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Self.decodeToRGB ? kCVPixelFormatType_32BGRA
                : hevc ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
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
    private var decodedFormat: OSType = 0
    /// Arrival time per frame timestamp, and arrival -> decoded durations.
    private var arrivals: [Int64: (time: CFTimeInterval, tiles: Int)] = [:]
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
            + "\(framesWithoutFormat) without format, decoded to '\(Self.fourCC(decodedFormat))', "
            + "format \(formatDescription.map { "\(CMVideoFormatDescriptionGetDimensions($0).width)x\(CMVideoFormatDescriptionGetDimensions($0).height)" } ?? "none")"
    }

    /// `tiles`: how many tiles were sent for this frame.
    func enqueue(ptsMicros: Int64, data: Data, tiles: Int = 1) {
        guard let formatDescription, let session else {
            framesWithoutFormat += 1
            return
        }
        framesEnqueued += 1
        counterLock.lock()
        arrivals[ptsMicros] = (CACurrentMediaTime(), tiles)
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
        for (key, value) in Self.frameColors {
            CVBufferSetAttachment(image, key, value, .shouldPropagate)
        }
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

        // Show as soon as decoded; we chase lowest latency.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        let ptsMicros = pts.convertScale(1_000_000, method: .roundHalfAwayFromZero).value
        var duration = 0.0
        var tiles = 1
        counterLock.lock()
        framesDecoded += 1
        decodedFormat = CVPixelBufferGetPixelFormatType(image)
        if let arrived = arrivals.removeValue(forKey: ptsMicros) {
            duration = CACurrentMediaTime() - arrived.time
            tiles = arrived.tiles
            decodeTimes.append(duration)
        }
        counterLock.unlock()
        onDecoded?(ptsMicros, duration, tiles)
        // Straight from the decoder's thread: a hop through the main thread
        // waited behind the window drawing.
        tileSync.add(tile: tile, of: tiles, ptsMicros: ptsMicros, layer: layer, sample: sampleBuffer)
    }
}

/// Puts all tiles sent for a frame on screen together, the moment the last
/// one is decoded. Shown independently, the parts of a window crossing a
/// strip edge could be a frame apart, a visible step at its edges.
final class TileSync {
    private let lock = NSLock()
    private var pending: [Int64: [Int: (AVSampleBufferDisplayLayer, CMSampleBuffer)]] = [:]

    /// Decoder threads. `count`: tiles sent for this frame.
    func add(tile: Int, of count: Int, ptsMicros: Int64, layer: AVSampleBufferDisplayLayer, sample: CMSampleBuffer) {
        lock.lock()
        var parts = pending[ptsMicros] ?? [:]
        parts[tile] = (layer, sample)
        guard parts.count >= count else {
            pending[ptsMicros] = parts
            lock.unlock()
            return
        }
        // An older frame still missing a tile is not superseded: it may hold
        // strips no later frame repeats. Only give up on it after a second.
        pending[ptsMicros] = nil
        pending = pending.filter { $0.key > ptsMicros - 1_000_000 }
        lock.unlock()
        for (layer, sample) in parts.values {
            layer.enqueue(sample)
        }
    }

    func reset() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }
}

