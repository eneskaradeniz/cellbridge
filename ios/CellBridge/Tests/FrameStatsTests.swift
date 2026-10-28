import XCTest
@testable import CellBridge

final class FrameStatsTests: XCTestCase {
    private func frame(zero: Bool) -> Data { Data(repeating: zero ? 0 : 1, count: 640) }

    func testCountsZeroAndIsolatedZeroFrames() {
        // loud, ZERO, loud | ZERO ZERO | loud | ZERO at the end
        let data = [false, true, false, true, true, false, true].reduce(into: Data()) { $0.append(frame(zero: $1)) }
        let stats = FrameStats(raw: data)
        XCTAssertEqual(stats.frames, 7)
        XCTAssertEqual(stats.zeroFrames, 4)
        XCTAssertEqual(stats.isolatedZeroFrames, 1) // only the first: a run of two and the last frame do not count
        XCTAssertEqual(stats.zeroPercent, 57)
    }

    func testPartialFrameAtTheEndIsIgnoredAndEmptyIsSafe() {
        XCTAssertEqual(FrameStats(raw: Data()).frames, 0)
        XCTAssertEqual(FrameStats(raw: Data()).zeroPercent, 0)
        XCTAssertEqual(FrameStats(raw: frame(zero: false) + Data(count: 100)).frames, 1)
    }

    func testZeroChopsCountsInnerRunsOnly() {
        let samples: [Int16] = [0, 0, 0, 5, 0, 0, 0, 0, 7, 0, 3, 0, 0, 0, 0, 0]
        let raw = samples.withUnsafeBytes { Data($0) }
        let chops = ZeroChops.count(in: raw, minRun: 4)
        XCTAssertEqual(chops.runs, 1)    // the leading run (before any sound) and the trailing run (never ended by sound) are skipped
        XCTAssertEqual(chops.longest, 4)
        XCTAssertEqual(ZeroChops.count(in: raw, minRun: 1).runs, 2) // the 4-run and the single zero before the 3; the unfinished trailing run never counts
    }

    func testZeroChopsCanBeLimitedToTheArtifactLength() {
        // inner zero runs of 3 and of 6 samples
        let samples: [Int16] = [1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 3]
        let raw = samples.withUnsafeBytes { Data($0) }
        XCTAssertEqual(ZeroChops.count(in: raw, minRun: 3).runs, 2)
        XCTAssertEqual(ZeroChops.count(in: raw, minRun: 5, maxRun: 7).runs, 1)
        XCTAssertEqual(ZeroChops.count(in: raw, minRun: 4, maxRun: 5).runs, 0)
    }
}
