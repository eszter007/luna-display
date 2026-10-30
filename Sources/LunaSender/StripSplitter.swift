import CoreVideo
import Metal

/// Splits a captured 4:2:0 frame into vertical strips with a GPU blit per
/// plane. The CPU copy it replaces left freshly CPU-written buffers for the
/// encoder and made a 5K frame take 40-60 ms whenever updates came in now
/// and then, which is most of real use.
final class StripSplitter {
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private var pool: CVPixelBufferPool?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { return nil }
        self.queue = queue
        textureCache = cache
    }

    /// Copies the strips at `indices` (of `count` equal vertical strips).
    func split(_ source: CVPixelBuffer, strips indices: [Int], of count: Int) -> [CVPixelBuffer]? {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferWidthKey: CVPixelBufferGetWidth(source) / count,
                kCVPixelBufferHeightKey: CVPixelBufferGetHeight(source),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var strips: [CVPixelBuffer] = []
        for _ in indices {
            var strip: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &strip) == kCVReturnSuccess, let strip else { return nil }
            strips.append(strip)
        }
        guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return nil }
        // The CVMetalTextures must outlive the GPU work.
        var textures: [CVMetalTexture] = []
        // 10-bit 4:2:0 stores each sample in 16 bits.
        let tenBit = CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        func texture(_ buffer: CVPixelBuffer, plane: Int) -> MTLTexture? {
            var cvTexture: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, buffer, nil,
                plane == 0 ? (tenBit ? .r16Unorm : .r8Unorm) : (tenBit ? .rg16Unorm : .rg8Unorm),
                CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane),
                plane, &cvTexture
            )
            guard let cvTexture, let metalTexture = CVMetalTextureGetTexture(cvTexture) else { return nil }
            textures.append(cvTexture)
            return metalTexture
        }
        for plane in 0 ..< 2 {
            guard let from = texture(source, plane: plane) else { return nil }
            let stripWidth = CVPixelBufferGetWidthOfPlane(source, plane) / count
            let height = CVPixelBufferGetHeightOfPlane(source, plane)
            for (index, strip) in zip(indices, strips) {
                guard let to = texture(strip, plane: plane) else { return nil }
                blit.copy(
                    from: from, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: index * stripWidth, y: 0, z: 0),
                    sourceSize: MTLSize(width: stripWidth, height: height, depth: 1),
                    to: to, destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
        }
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(textures) {}
        strips.forEach { CVBufferPropagateAttachments(source, $0) }
        return strips
    }
}
