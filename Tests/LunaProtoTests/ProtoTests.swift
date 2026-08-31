import XCTest
@testable import LunaProto

final class ProtoTests: XCTestCase {
    private func roundTrip(_ packets: [Data], chunk: Int) -> [LunaMessage] {
        let parser = LunaMessageParser()
        var all = Data()
        packets.forEach { all.append($0) }
        var out: [LunaMessage] = []
        var offset = 0
        while offset < all.count {
            let end = min(offset + chunk, all.count)
            out += parser.feed(all.subdata(in: offset ..< end))
            offset = end
        }
        return out
    }

    func testAllMessagesRoundTripAtEveryChunkSize() {
        let sps = Data([0x67, 0x64, 0x00, 0x1F])
        let pps = Data([0x68, 0xEE, 0x3C, 0x80])
        let avcc = Data((0 ..< 300).map { UInt8($0 & 0xFF) })
        let pcm = Data((0 ..< 960).map { UInt8($0 & 0xFF) })
        let packets: [Data] = [
            LunaWire.helloData(streamWidth: 3840, streamHeight: 2160, fps: 60, senderName: "MacBook"),
            LunaWire.capsData(screenWidth: 5120, screenHeight: 2880, name: "iMac", hasCamera: true, hasMic: false),
            LunaWire.paramSetsData(sps: sps, pps: pps),
            LunaWire.frameData(ptsMicros: -5, keyframe: true, avcc: avcc),
            LunaWire.camParamSetsData(sps: sps, pps: pps),
            LunaWire.camFrameData(ptsMicros: 1_234_567_890_123, keyframe: false, avcc: avcc),
            LunaWire.audioData(ptsMicros: 42, sampleRate: 48_000, channels: 1, pcm: pcm),
            LunaWire.captureData(camera: true, mic: false),
            LunaWire.captureStatusData(camera: "streaming", mic: "denied"),
        ]
        let expected: [LunaMessage] = [
            .hello(streamWidth: 3840, streamHeight: 2160, fps: 60, senderName: "MacBook"),
            .caps(screenWidth: 5120, screenHeight: 2880, name: "iMac", hasCamera: true, hasMic: false),
            .paramSets(sps: sps, pps: pps),
            .frame(ptsMicros: -5, keyframe: true, data: avcc),
            .camParamSets(sps: sps, pps: pps),
            .camFrame(ptsMicros: 1_234_567_890_123, keyframe: false, data: avcc),
            .audio(ptsMicros: 42, sampleRate: 48_000, channels: 1, pcm: pcm),
            .capture(camera: true, mic: false),
            .captureStatus(camera: "streaming", mic: "denied"),
        ]
        for chunk in [1, 3, 7, 64, 1000, 100_000] {
            XCTAssertEqual(roundTrip(packets, chunk: chunk), expected, "chunk size \(chunk)")
        }
    }

    func testOldCapsWithoutCameraFieldsDecodes() {
        // A v1 receiver never sends cam/mic; they must default to false.
        let json = try! JSONSerialization.data(withJSONObject: ["v": 1, "maxW": 1, "maxH": 2, "name": "old"])
        var packet = Data([LunaWire.typeCaps])
        LunaWire.appendU32LE(&packet, UInt32(json.count))
        packet.append(json)
        XCTAssertEqual(LunaMessageParser().feed(packet),
                       [.caps(screenWidth: 1, screenHeight: 2, name: "old", hasCamera: false, hasMic: false)])
    }

    func testTruncatedPayloadsAreDroppedNotCrashed() {
        for type in [LunaWire.typeParamSets, LunaWire.typeFrame, LunaWire.typeAudio, LunaWire.typeCamFrame] {
            var packet = Data([type])
            LunaWire.appendU32LE(&packet, 3)
            packet.append(Data([1, 2, 3]))
            XCTAssertEqual(LunaMessageParser().feed(packet), [], "type \(type)")
        }
    }

    func testReverseMediaClassification() {
        XCTAssertTrue(LunaMessage.audio(ptsMicros: 0, sampleRate: 1, channels: 1, pcm: Data()).isReverseMedia)
        XCTAssertTrue(LunaMessage.camFrame(ptsMicros: 0, keyframe: false, data: Data()).isReverseMedia)
        XCTAssertFalse(LunaMessage.capture(camera: true, mic: true).isReverseMedia)
        XCTAssertFalse(LunaMessage.frame(ptsMicros: 0, keyframe: false, data: Data()).isReverseMedia)
    }

    func testOversizedFrameMarksParserCorrupted() {
        let parser = LunaMessageParser()
        var header = Data([LunaWire.typeFrame])
        let huge = UInt32(LunaMessageParser.maxPayloadLength + 1)
        header.append(contentsOf: withUnsafeBytes(of: huge.littleEndian) { Array($0) })
        XCTAssertTrue(parser.feed(header).isEmpty)
        XCTAssertTrue(parser.corrupted)
        // Nothing gets through afterwards; a fresh parser is unaffected.
        let capture = LunaWire.captureData(camera: true, mic: false)
        XCTAssertTrue(parser.feed(capture).isEmpty)
        XCTAssertEqual(LunaMessageParser().feed(capture), [.capture(camera: true, mic: false)])
        // A payload exactly at the limit is still legal.
        let atLimit = LunaMessageParser()
        var maxHeader = Data([LunaWire.typeFrame])
        maxHeader.append(contentsOf: withUnsafeBytes(of: UInt32(LunaMessageParser.maxPayloadLength).littleEndian) { Array($0) })
        XCTAssertTrue(atLimit.feed(maxHeader).isEmpty)
        XCTAssertFalse(atLimit.corrupted)
    }
}
