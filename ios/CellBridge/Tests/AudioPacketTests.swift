import XCTest
@testable import CellBridge

final class AudioPacketTests: XCTestCase {
    private let pcm = (0..<AudioPacket.samplesPerFrame).map { Int16($0 - 160) * 100 }

    func testEncodesLittleEndianHeaderThenPcm() {
        let data = AudioPacket.encode(seq: 0x1234, pcm: pcm)
        XCTAssertEqual(data.count, 644)
        XCTAssertEqual([UInt8](data.prefix(4)), [0x34, 0x12, 0, 0])
        XCTAssertEqual([UInt8](data[4..<6]), [UInt8(truncatingIfNeeded: pcm[0]), UInt8(truncatingIfNeeded: pcm[0] >> 8)])
    }

    func testRoundTrip() throws {
        let decoded = try XCTUnwrap(AudioPacket.decode(AudioPacket.encode(seq: 65535, pcm: pcm)))
        XCTAssertEqual(decoded.seq, 65535)
        XCTAssertEqual(decoded.pcm, pcm)
    }

    func testRejectsAnythingButAWholeFrame() {
        XCTAssertNil(AudioPacket.decode(Data()))
        XCTAssertNil(AudioPacket.decode(Data(count: 643)))
        XCTAssertNil(AudioPacket.decode(Data(count: 645)))
    }
}
