import Foundation
import LunaProto
import AVFoundation
import CoreMedia

/// Feeds compressed H.264 samples straight into an AVSampleBufferDisplayLayer,
/// which hardware-decodes internally. No VTDecompressionSession needed, and
/// it works back to old macOS on the iMac.
final class VideoPipeline {
    let layer = AVSampleBufferDisplayLayer()
    private var formatDescription: CMVideoFormatDescription?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func reset() {
        formatDescription = nil
        layer.flush()
    }

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
                    extensions: nil,
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
            lunaLog("luna: could not create format description (%d)", status)
            return
        }
        formatDescription = desc
        layer.flush()
    }

    func enqueue(ptsMicros: Int64, data: Data) {
        guard let formatDescription else { return }

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

        // Render as soon as decoded; we chase lowest latency, not smoothness.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        layer.enqueue(sampleBuffer)
    }
}
