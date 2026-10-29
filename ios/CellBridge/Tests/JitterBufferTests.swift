import XCTest
@testable import CellBridge

/// The same scenarios as the daemon's tests/jitter_test.c.
final class JitterBufferTests: XCTestCase {
    private let samples = 4

    private func make() -> JitterBuffer { JitterBuffer(frameSamples: samples) }

    /// Frames carry a non-zero marker derived from the sequence, distinguishable from concealment silence.
    private func marker(_ seq: Int) -> Int16 { Int16(seq & 0xff) | 1 }

    private func push(_ j: JitterBuffer, _ seq: Int) {
        j.push(seq: UInt16(truncatingIfNeeded: seq), frame: [Int16](repeating: marker(seq), count: samples))
    }

    private func fill(_ j: JitterBuffer, from: Int, count: Int) { (0..<count).forEach { push(j, from + $0) } }

    func testPrimesThenPlaysInOrder() {
        let j = make()
        fill(j, from: 100, count: 2)
        XCTAssertEqual(j.pop().result, .priming) // 2 < start target 3
        push(j, 102)
        for i in 0..<3 {
            let popped = j.pop()
            XCTAssertEqual(popped.result, .frame)
            XCTAssertEqual(popped.frame[0], marker(100 + i))
        }
    }

    func testLostPacketIsConcealedAndSkipped() {
        let j = make()
        [10, 11, 13, 14].forEach { push(j, $0) } // 12 is lost
        XCTAssertEqual(j.pop().result, .frame)
        XCTAssertEqual(j.pop().result, .frame)
        let hole = j.pop()
        XCTAssertEqual(hole.result, .concealed)
        XCTAssertEqual(hole.frame, [Int16](repeating: marker(11) * 3 / 4, count: samples)) // a faded repeat of 11, not a hole
        XCTAssertEqual(j.pop().result, .frame)
        let stats = j.currentStats()
        XCTAssertEqual(stats.concealed, 1)
        XCTAssertEqual(stats.played, 3)
        XCTAssertEqual(stats.target, 3) // a hole is not starvation
    }

    func testReorderingWithinWindowIsRepaired() {
        let j = make()
        [1, 3, 2].forEach { push(j, $0) }
        for i in 1...3 {
            let popped = j.pop()
            XCTAssertEqual(popped.result, .frame)
            XCTAssertEqual(popped.frame[0], marker(i))
        }
    }

    func testLateAndDuplicatePacketsAreCounted() {
        let j = make()
        fill(j, from: 50, count: 4)
        _ = j.pop(); _ = j.pop() // 50, 51 played
        push(j, 50) // late
        push(j, 53) // duplicate
        let stats = j.currentStats()
        XCTAssertEqual(stats.late, 1)
        XCTAssertEqual(stats.duplicate, 1)
    }

    func testSequenceWraparound() {
        let j = make()
        for seq in 65534...65535 { push(j, seq) }
        for seq in 0...3 { push(j, seq) }
        var expected = 65534
        for _ in 0..<6 {
            let popped = j.pop()
            XCTAssertEqual(popped.result, .frame)
            XCTAssertEqual(popped.frame[0], marker(expected))
            expected = (expected + 1) % 65536
        }
    }

    func testStarvationDeepensBufferUpToMax() {
        let j = make()
        for round in 0..<8 {
            let depth = j.currentStats().target // priming needs `target` frames
            fill(j, from: 1000 + round * 10, count: depth)
            for _ in 0..<depth { XCTAssertEqual(j.pop().result, .frame) }
            XCTAssertEqual(j.pop().result, .concealed) // nothing left: starved
        }
        XCTAssertEqual(j.currentStats().target, 14) // grows by 2 per starvation, capped at 14 (280 ms)
    }

    func testCalmPeriodShrinksBuffer() {
        let j = make()
        var seq = 0
        fill(j, from: seq, count: 3); seq += 3
        for _ in 0..<300 { // steady 1-in 1-out stream
            push(j, seq); seq += 1
            XCTAssertEqual(j.pop().result, .frame)
        }
        XCTAssertEqual(j.currentStats().target, 3) // the floor is 3 now
    }

    func testFarJumpResyncs() {
        let j = make()
        fill(j, from: 0, count: 3)
        XCTAssertEqual(j.pop().result, .frame)
        fill(j, from: 5000, count: 3) // sender restarted far away
        XCTAssertEqual(j.currentStats().overflow, 1)
        for i in 0..<3 {
            let popped = j.pop()
            XCTAssertEqual(popped.result, .frame)
            XCTAssertEqual(popped.frame[0], marker(5000 + i))
        }
    }

    func testBurstKeepsLatencyBounded() {
        let j = make()
        fill(j, from: 0, count: 3)
        _ = j.pop()
        fill(j, from: 3, count: 20)
        XCTAssertGreaterThan(j.currentStats().overflow, 0)
        let popped = j.pop()
        XCTAssertEqual(popped.result, .frame)
        XCTAssertEqual(popped.frame[0], marker(10)) // only target + 10 = 13 frames stay: 10..22
    }

    func testConcealmentFadesOutOverThreeFrames() {
        let j = make()
        [0, 1, 2].forEach { j.push(seq: UInt16($0), frame: [Int16](repeating: 1000, count: samples)) }
        j.push(seq: 8, frame: [Int16](repeating: 1000, count: samples)) // 3...7 missing, something buffered behind them
        (0..<3).forEach { _ in XCTAssertEqual(j.pop().result, .frame) }
        for expected: Int16 in [750, 500, 250, 0, 0] {
            let popped = j.pop()
            XCTAssertEqual(popped.result, .concealed)
            XCTAssertEqual(popped.frame[0], expected)
        }
    }

    func testRedundantCopyRepairsALostFrame() {
        let j = make()
        [0, 1, 2].forEach { push(j, $0) }
        XCTAssertEqual(j.pop().result, .frame) // 0
        push(j, 4) // 3 is lost; the packet for 4 carries it again
        j.pushRedundant(seq: 3, frame: [Int16](repeating: marker(3), count: samples))
        XCTAssertEqual(j.pop().result, .frame) // 1
        XCTAssertEqual(j.pop().result, .frame) // 2
        let repaired = j.pop()
        XCTAssertEqual(repaired.result, .frame)
        XCTAssertEqual(repaired.frame[0], marker(3))
        XCTAssertEqual(j.pop().frame[0], marker(4))
        let stats = j.currentStats()
        XCTAssertEqual(stats.recovered, 1)
        XCTAssertEqual(stats.concealed + stats.late + stats.duplicate, 0)
    }

    func testRedundantCopyIsIgnoredWhenNotNeeded() {
        let j = make()
        [0, 1, 2].forEach { push(j, $0) }
        j.pushRedundant(seq: 2, frame: [Int16](repeating: marker(2), count: samples)) // already held
        (0..<3).forEach { _ in _ = j.pop() }
        j.pushRedundant(seq: 1, frame: [Int16](repeating: marker(1), count: samples)) // already played
        let stats = j.currentStats()
        XCTAssertEqual(stats.recovered + stats.late + stats.duplicate, 0)
    }
}
