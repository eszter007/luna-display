// Wire protocol shared by LunaSender and LunaReceiver.
//
// Framing: [type: u8][payloadLength: u32 LE][payload]
//
// Display stream (sender -> receiver):
//   hello        (1): JSON {v, w, h, fps, name, tiles}
//   paramSets    (3): [spsLen: u16 LE][sps][ppsLen: u16 LE][pps]
//   frame        (4): [ptsMicros: i64 LE][flags: u8][AVCC data]   flags bit 0 = keyframe
//   hevcParamSets(12): [tile: u8][count: u8] then count x [len: u16 LE][VPS/SPS/PPS]
//   hevcFrame   (13): [tile: u8][tiles: u8 bitmask of all tiles sent for this frame][frame payload]
//
// HEVC streams come in hello.tiles vertical strips of the w x h picture, each
// its own stream (tile 0 leftmost). Only strips that changed are sent for a
// frame; encode time scales with them (5K: ~4 ms per strip of four).
//
// Receiver -> sender:
//   caps         (2): JSON {v, maxW, maxH, name, cam, mic, cursor, hevcStrips}
//   camParamSets (5): same layout as paramSets
//   camFrame     (6): same layout as frame
//   audio        (7): [ptsMicros: i64 LE][sampleRate: u32 LE][channels: u8][PCM s16 LE interleaved]
//   captureStatus(9): JSON {cam, mic} — strings: "off", "streaming", "denied", "none", "error: …"
//   frameAck    (14): [ptsMicros: i64 LE][receiverMicros: u32 LE] — every tile of
//                     that frame is decoded; receiverMicros is arrival -> decoded.
//                     Once acks arrive, the sender caps the frames in flight
//                     so no queue builds up anywhere between capture and decode.
//
// Sender -> receiver:
//   capture      (8): JSON {cam: bool, mic: bool} — start/stop the iMac's camera and mic
//   cursorImage (10): [hotX: f32][hotY: f32][width: f32][height: f32][PNG]
//                     hot spot as a fraction of the image, size as a fraction of the display
//   cursorPos   (11): [x: f32][y: f32][visible: u8] — hot spot as a fraction of the display, top-left origin
//
// Receivers that set caps.hevcStrips hardware-decode HEVC, which carries a full
// 5120x2880 frame; H.264 tops out around 4K on the iMacs' decoders.
//
// Receivers that set caps.cursor draw the cursor themselves from cursorImage/
// cursorPos, so it moves without waiting for capture, encode and decode.

import Foundation

public enum LunaMessage: Equatable {
    case hello(streamWidth: Int, streamHeight: Int, fps: Int, senderName: String, tiles: Int = 1)
    case caps(screenWidth: Int, screenHeight: Int, name: String, hasCamera: Bool, hasMic: Bool, drawsCursor: Bool = false, decodesHEVC: Bool = false)
    case paramSets(sps: Data, pps: Data)
    case frame(ptsMicros: Int64, keyframe: Bool, data: Data)
    case camParamSets(sps: Data, pps: Data)
    case camFrame(ptsMicros: Int64, keyframe: Bool, data: Data)
    case audio(ptsMicros: Int64, sampleRate: Int, channels: Int, pcm: Data)
    case capture(camera: Bool, mic: Bool)
    case captureStatus(camera: String, mic: String)
    case cursorImage(hotX: Float, hotY: Float, width: Float, height: Float, png: Data)
    case cursorPos(x: Float, y: Float, visible: Bool)
    case hevcParamSets(tile: Int, sets: [Data])
    /// `tiles`: bitmask of every tile sent for this frame (unchanged tiles are skipped).
    case hevcFrame(tile: Int, tiles: UInt8, ptsMicros: Int64, keyframe: Bool, data: Data)
    case frameAck(ptsMicros: Int64, receiverMicros: Int)

    /// High-rate media flowing back from the receiver (camera frames, audio).
    public var isReverseMedia: Bool {
        switch self {
        case .camParamSets, .camFrame, .audio: return true
        default: return false
        }
    }
}

public enum LunaWire {
    public static let typeHello: UInt8 = 1
    public static let typeCaps: UInt8 = 2
    public static let typeParamSets: UInt8 = 3
    public static let typeFrame: UInt8 = 4
    public static let typeCamParamSets: UInt8 = 5
    public static let typeCamFrame: UInt8 = 6
    public static let typeAudio: UInt8 = 7
    public static let typeCapture: UInt8 = 8
    public static let typeCaptureStatus: UInt8 = 9
    public static let typeCursorImage: UInt8 = 10
    public static let typeCursorPos: UInt8 = 11
    public static let typeHEVCParamSets: UInt8 = 12
    public static let typeHEVCFrame: UInt8 = 13
    public static let typeFrameAck: UInt8 = 14

    public static let serviceType = "_lunax._tcp"

    static func envelope(type: UInt8, payload: Data) -> Data {
        var out = Data(capacity: payload.count + 5)
        out.append(type)
        appendU32LE(&out, UInt32(payload.count))
        out.append(payload)
        return out
    }

    static func appendU16LE(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8(v >> 8))
    }

    static func appendU32LE(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 24) & 0xFF))
    }

    static func appendU64LE(_ d: inout Data, _ v: UInt64) {
        appendU32LE(&d, UInt32(v & 0xFFFF_FFFF))
        appendU32LE(&d, UInt32(v >> 32))
    }

    static func json(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    public static func helloData(streamWidth: Int, streamHeight: Int, fps: Int, senderName: String, tiles: Int = 1) -> Data {
        envelope(type: typeHello, payload: json([
            "v": 2, "w": streamWidth, "h": streamHeight, "fps": fps, "name": senderName, "tiles": tiles,
        ]))
    }

    public static func capsData(screenWidth: Int, screenHeight: Int, name: String, hasCamera: Bool, hasMic: Bool, drawsCursor: Bool = false, decodesHEVC: Bool = false) -> Data {
        envelope(type: typeCaps, payload: json([
            "v": 2, "maxW": screenWidth, "maxH": screenHeight, "name": name, "cam": hasCamera, "mic": hasMic,
            "cursor": drawsCursor, "hevcStrips": decodesHEVC,
        ]))
    }

    public static func hevcParamSetsData(tile: Int, sets: [Data]) -> Data {
        var p = Data([UInt8(tile), UInt8(sets.count)])
        for set in sets {
            appendU16LE(&p, UInt16(set.count))
            p.append(set)
        }
        return envelope(type: typeHEVCParamSets, payload: p)
    }

    public static func frameAckData(ptsMicros: Int64, receiverMicros: Int) -> Data {
        var p = Data(capacity: 12)
        appendU64LE(&p, UInt64(bitPattern: ptsMicros))
        appendU32LE(&p, UInt32(clamping: max(receiverMicros, 0)))
        return envelope(type: typeFrameAck, payload: p)
    }

    public static func hevcFrameData(tile: Int, tiles: UInt8, ptsMicros: Int64, keyframe: Bool, data: Data) -> Data {
        envelope(type: typeHEVCFrame, payload: Data([UInt8(tile), tiles]) + framePayload(ptsMicros: ptsMicros, keyframe: keyframe, avcc: data))
    }

    static func appendF32LE(_ d: inout Data, _ v: Float) {
        appendU32LE(&d, v.bitPattern)
    }

    public static func cursorImageData(hotX: Float, hotY: Float, width: Float, height: Float, png: Data) -> Data {
        var p = Data(capacity: png.count + 16)
        for v in [hotX, hotY, width, height] { appendF32LE(&p, v) }
        p.append(png)
        return envelope(type: typeCursorImage, payload: p)
    }

    public static func cursorPosData(x: Float, y: Float, visible: Bool) -> Data {
        var p = Data(capacity: 9)
        appendF32LE(&p, x)
        appendF32LE(&p, y)
        p.append(visible ? 1 : 0)
        return envelope(type: typeCursorPos, payload: p)
    }

    static func parameterSetsPayload(sps: Data, pps: Data) -> Data {
        // H.264 parameter sets are a few dozen bytes; never trap on a bad one.
        let sps = sps.prefix(Int(UInt16.max)), pps = pps.prefix(Int(UInt16.max))
        var p = Data(capacity: sps.count + pps.count + 4)
        appendU16LE(&p, UInt16(sps.count))
        p.append(sps)
        appendU16LE(&p, UInt16(pps.count))
        p.append(pps)
        return p
    }

    static func framePayload(ptsMicros: Int64, keyframe: Bool, avcc: Data) -> Data {
        var p = Data(capacity: avcc.count + 9)
        appendU64LE(&p, UInt64(bitPattern: ptsMicros))
        p.append(keyframe ? 1 : 0)
        p.append(avcc)
        return p
    }

    public static func paramSetsData(sps: Data, pps: Data) -> Data {
        envelope(type: typeParamSets, payload: parameterSetsPayload(sps: sps, pps: pps))
    }

    public static func frameData(ptsMicros: Int64, keyframe: Bool, avcc: Data) -> Data {
        envelope(type: typeFrame, payload: framePayload(ptsMicros: ptsMicros, keyframe: keyframe, avcc: avcc))
    }

    public static func camParamSetsData(sps: Data, pps: Data) -> Data {
        envelope(type: typeCamParamSets, payload: parameterSetsPayload(sps: sps, pps: pps))
    }

    public static func camFrameData(ptsMicros: Int64, keyframe: Bool, avcc: Data) -> Data {
        envelope(type: typeCamFrame, payload: framePayload(ptsMicros: ptsMicros, keyframe: keyframe, avcc: avcc))
    }

    public static func audioData(ptsMicros: Int64, sampleRate: Int, channels: Int, pcm: Data) -> Data {
        var p = Data(capacity: pcm.count + 13)
        appendU64LE(&p, UInt64(bitPattern: ptsMicros))
        appendU32LE(&p, UInt32(sampleRate))
        p.append(UInt8(clamping: channels))
        p.append(pcm)
        return envelope(type: typeAudio, payload: p)
    }

    public static func captureData(camera: Bool, mic: Bool) -> Data {
        envelope(type: typeCapture, payload: json(["cam": camera, "mic": mic]))
    }

    public static func captureStatusData(camera: String, mic: String) -> Data {
        envelope(type: typeCaptureStatus, payload: json(["cam": camera, "mic": mic]))
    }
}

/// Incremental parser: feed raw bytes from the socket, get complete messages out.
public final class LunaMessageParser {
    /// Largest payload we will buffer. A 4K keyframe is well under 4 MB; a
    /// length beyond this means a corrupt or hostile stream, not a big frame.
    public static let maxPayloadLength = 16 * 1024 * 1024

    private var buffer = Data()
    /// Set once a frame header exceeds `maxPayloadLength`; the stream is out
    /// of sync and the caller should drop the connection.
    public private(set) var corrupted = false

    public init() {}

    public func feed(_ data: Data) -> [LunaMessage] {
        guard !corrupted else { return [] }
        buffer.append(data)
        var out: [LunaMessage] = []
        // Walk the messages by offset and drop the consumed bytes once at the
        // end: removing each message from the front re-copied the rest of a
        // read of up to 1 MB per message, which on the receiving iMac slowed
        // reading enough to back the stream up on the sender.
        var offset = 0
        while true {
            guard buffer.count - offset >= 5 else { break }
            let type = byte(at: offset)
            let length = Int(u32LE(at: offset + 1))
            guard length <= Self.maxPayloadLength else {
                corrupted = true
                buffer.removeAll()
                return out
            }
            guard buffer.count - offset >= 5 + length else { break }
            let payload = buffer.subdata(in: index(offset + 5) ..< index(offset + 5 + length))
            offset += 5 + length
            if let msg = Self.decode(type: type, payload: payload) {
                out.append(msg)
            }
        }
        if offset > 0 {
            buffer.removeSubrange(buffer.startIndex ..< index(offset))
        }
        return out
    }

    private func index(_ offset: Int) -> Data.Index {
        buffer.index(buffer.startIndex, offsetBy: offset)
    }

    private func byte(at offset: Int) -> UInt8 {
        buffer[index(offset)]
    }

    private func u32LE(at offset: Int) -> UInt32 {
        UInt32(byte(at: offset))
            | UInt32(byte(at: offset + 1)) << 8
            | UInt32(byte(at: offset + 2)) << 16
            | UInt32(byte(at: offset + 3)) << 24
    }

    private static func jsonDict(_ payload: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }

    private static func parameterSets(_ payload: Data) -> (sps: Data, pps: Data)? {
        guard payload.count >= 4 else { return nil }
        let bytes = [UInt8](payload)
        let spsLen = Int(bytes[0]) | Int(bytes[1]) << 8
        guard payload.count >= 2 + spsLen + 2 else { return nil }
        let sps = Data(bytes[2 ..< 2 + spsLen])
        let ppsLenOffset = 2 + spsLen
        let ppsLen = Int(bytes[ppsLenOffset]) | Int(bytes[ppsLenOffset + 1]) << 8
        guard payload.count >= ppsLenOffset + 2 + ppsLen else { return nil }
        let pps = Data(bytes[(ppsLenOffset + 2) ..< (ppsLenOffset + 2 + ppsLen)])
        return (sps, pps)
    }

    private static func i64LE(_ bytes: [UInt8], at offset: Int) -> Int64 {
        var v: UInt64 = 0
        for i in (offset ..< offset + 8).reversed() {
            v = (v << 8) | UInt64(bytes[i])
        }
        return Int64(bitPattern: v)
    }

    private static func frame(_ payload: Data) -> (ptsMicros: Int64, keyframe: Bool, data: Data)? {
        guard payload.count >= 9 else { return nil }
        let bytes = [UInt8](payload.prefix(9))
        let keyframe = bytes[8] & 1 == 1
        let data = payload.subdata(in: payload.index(payload.startIndex, offsetBy: 9) ..< payload.endIndex)
        return (i64LE(bytes, at: 0), keyframe, data)
    }

    private static func decode(type: UInt8, payload: Data) -> LunaMessage? {
        switch type {
        case LunaWire.typeHello:
            guard let dict = jsonDict(payload) else { return nil }
            return .hello(
                streamWidth: dict["w"] as? Int ?? 0,
                streamHeight: dict["h"] as? Int ?? 0,
                fps: dict["fps"] as? Int ?? 60,
                senderName: dict["name"] as? String ?? "Mac",
                tiles: dict["tiles"] as? Int ?? 1
            )
        case LunaWire.typeCaps:
            guard let dict = jsonDict(payload) else { return nil }
            return .caps(
                screenWidth: dict["maxW"] as? Int ?? 0,
                screenHeight: dict["maxH"] as? Int ?? 0,
                name: dict["name"] as? String ?? "Mac",
                hasCamera: dict["cam"] as? Bool ?? false,
                hasMic: dict["mic"] as? Bool ?? false,
                drawsCursor: dict["cursor"] as? Bool ?? false,
                // Was "hevc", then "hevcTiles" for older stream formats; a receiver reporting
                // that must get H.264, not tiles it can't read.
                decodesHEVC: dict["hevcStrips"] as? Bool ?? false
            )
        case LunaWire.typeParamSets:
            guard let ps = parameterSets(payload) else { return nil }
            return .paramSets(sps: ps.sps, pps: ps.pps)
        case LunaWire.typeFrame:
            guard let f = frame(payload) else { return nil }
            return .frame(ptsMicros: f.ptsMicros, keyframe: f.keyframe, data: f.data)
        case LunaWire.typeCamParamSets:
            guard let ps = parameterSets(payload) else { return nil }
            return .camParamSets(sps: ps.sps, pps: ps.pps)
        case LunaWire.typeCamFrame:
            guard let f = frame(payload) else { return nil }
            return .camFrame(ptsMicros: f.ptsMicros, keyframe: f.keyframe, data: f.data)
        case LunaWire.typeAudio:
            guard payload.count >= 13 else { return nil }
            let bytes = [UInt8](payload.prefix(13))
            let rate = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
            let channels = Int(bytes[12])
            let pcm = payload.subdata(in: payload.index(payload.startIndex, offsetBy: 13) ..< payload.endIndex)
            return .audio(ptsMicros: i64LE(bytes, at: 0), sampleRate: rate, channels: channels, pcm: pcm)
        case LunaWire.typeCapture:
            guard let dict = jsonDict(payload) else { return nil }
            return .capture(camera: dict["cam"] as? Bool ?? false, mic: dict["mic"] as? Bool ?? false)
        case LunaWire.typeCaptureStatus:
            guard let dict = jsonDict(payload) else { return nil }
            return .captureStatus(camera: dict["cam"] as? String ?? "off", mic: dict["mic"] as? String ?? "off")
        case LunaWire.typeHEVCParamSets:
            let bytes = [UInt8](payload)
            guard bytes.count >= 2 else { return nil }
            let count = bytes[1]
            var sets: [Data] = []
            var offset = 2
            for _ in 0 ..< count {
                guard bytes.count >= offset + 2 else { return nil }
                let len = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                guard bytes.count >= offset + 2 + len else { return nil }
                sets.append(Data(bytes[(offset + 2) ..< (offset + 2 + len)]))
                offset += 2 + len
            }
            return .hevcParamSets(tile: Int(bytes[0]), sets: sets)
        case LunaWire.typeFrameAck:
            guard payload.count >= 8 else { return nil }
            let bytes = [UInt8](payload.prefix(12))
            let receiverMicros = bytes.count >= 12
                ? Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24 : 0
            return .frameAck(ptsMicros: i64LE(bytes, at: 0), receiverMicros: receiverMicros)
        case LunaWire.typeHEVCFrame:
            guard payload.count >= 2, let f = frame(payload.dropFirst(2)) else { return nil }
            let head = [UInt8](payload.prefix(2))
            return .hevcFrame(tile: Int(head[0]), tiles: head[1], ptsMicros: f.ptsMicros, keyframe: f.keyframe, data: f.data)
        case LunaWire.typeCursorImage:
            guard payload.count >= 16 else { return nil }
            let bytes = [UInt8](payload.prefix(16))
            let png = payload.subdata(in: payload.index(payload.startIndex, offsetBy: 16) ..< payload.endIndex)
            return .cursorImage(hotX: f32LE(bytes, at: 0), hotY: f32LE(bytes, at: 4),
                                width: f32LE(bytes, at: 8), height: f32LE(bytes, at: 12), png: png)
        case LunaWire.typeCursorPos:
            guard payload.count >= 9 else { return nil }
            let bytes = [UInt8](payload.prefix(9))
            return .cursorPos(x: f32LE(bytes, at: 0), y: f32LE(bytes, at: 4), visible: bytes[8] & 1 == 1)
        default:
            return nil
        }
    }

    private static func f32LE(_ bytes: [UInt8], at offset: Int) -> Float {
        Float(bitPattern: UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
    }
}
