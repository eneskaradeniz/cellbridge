import XCTest
@testable import CellBridge

final class ToneSynthTests: XCTestCase {
    func testTheRingbackIsOneSecondOfToneAndFourOfSilence() throws {
        let pattern = try XCTUnwrap(ToneSynth.pattern(for: 23))
        XCTAssertTrue(pattern.loops)
        let samples = ToneSynth.samples(pattern, rate: 8000)
        XCTAssertEqual(samples.count, 8000 * 5)
        XCTAssertTrue(samples[0..<8000].contains { abs($0) > 4000 })
        XCTAssertTrue(samples[8000...].allSatisfy { $0 == 0 })
    }

    func testTheToneIsAt425Hz() throws {
        let samples = ToneSynth.samples(try XCTUnwrap(ToneSynth.pattern(for: 23)), rate: 8000)
        // Upward zero crossings in the first second of tone = its frequency.
        let crossings = (1..<8000).filter { samples[$0 - 1] <= 0 && samples[$0] > 0 }.count
        XCTAssertTrue((424...426).contains(crossings), "crossings: \(crossings)")
    }

    func testBusyCongestionAndCallWaitingCadences() throws {
        XCTAssertEqual(ToneSynth.samples(try XCTUnwrap(ToneSynth.pattern(for: 17)), rate: 8000).count, 8000)       // 500 on + 500 off
        XCTAssertEqual(ToneSynth.samples(try XCTUnwrap(ToneSynth.pattern(for: 18)), rate: 8000).count, 3200)       // 200 on + 200 off
        XCTAssertEqual(ToneSynth.samples(try XCTUnwrap(ToneSynth.pattern(for: 22)), rate: 8000).count, 8000 * 4)   // 200+600, 200+3000
    }

    func testABeepDoesNotLoopAndAnUnknownToneIsNotPlayed() throws {
        XCTAssertFalse(try XCTUnwrap(ToneSynth.pattern(for: 19)).loops)
        XCTAssertNil(ToneSynth.pattern(for: 9999))
    }

    func testEveryLoopHasAnUpperBoundAndTheRingbackAllowsTheLongest() throws {
        let ids = [16, 17, 18, 21, 22, 23]
        let bounds = try ids.map { try XCTUnwrap(ToneSynth.pattern(for: $0)).maxSeconds }
        XCTAssertTrue(bounds.allSatisfy { $0 > 0 })
        XCTAssertEqual(bounds.max(), try XCTUnwrap(ToneSynth.pattern(for: 23)).maxSeconds) // a call can ring for a minute
    }

    func testTheWavHasAValidHeader() {
        let wav = ToneSynth.wav([0, 1, 2, 3], rate: 8000)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(wav.count, 44 + 8)
    }
}
