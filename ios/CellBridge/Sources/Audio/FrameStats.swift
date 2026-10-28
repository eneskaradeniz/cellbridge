import Foundation

/// How much of a raw 16 kHz S16 mono recording is digital silence, in 20 ms frames. iOS's noise gate switches the
/// microphone to exact zeros; a lot of that inside speech is what makes a voice sound robotic.
struct FrameStats: Equatable {
    var frames = 0
    var zeroFrames = 0
    /// Zero frames with a non-zero frame on both sides: the gate chopping the middle of a word.
    var isolatedZeroFrames = 0

    var zeroPercent: Int { frames == 0 ? 0 : Int((Double(zeroFrames) * 100 / Double(frames)).rounded()) }

    init(raw: Data, frameBytes: Int = AudioPacket.samplesPerFrame * 2) {
        let bytes = [UInt8](raw)
        frames = bytes.count / frameBytes
        let zero = (0..<frames).map { index in !bytes[(index * frameBytes)..<((index + 1) * frameBytes)].contains { $0 != 0 } }
        zeroFrames = zero.filter { $0 }.count
        if frames > 2 {
            isolatedZeroFrames = (1..<(frames - 1)).filter { zero[$0] && !zero[$0 - 1] && !zero[$0 + 1] }.count
        }
    }
}

/// Exact-zero stretches inside a raw S16 recording: what a faulty microphone path leaves in the middle of sound.
enum ZeroChops {
    /// Runs of `minRun...maxRun` consecutive zero samples (the very start and end of a recording are skipped).
    static func count(in raw: Data, minRun: Int, maxRun: Int = .max) -> (runs: Int, longest: Int) {
        var runs = 0, longest = 0, current = 0, seenSound = false
        raw.withUnsafeBytes { buffer in
            for sample in buffer.bindMemory(to: Int16.self) {
                if sample == 0 {
                    current += 1
                } else {
                    if seenSound && current >= minRun && current <= maxRun { runs += 1; longest = max(longest, current) }
                    current = 0
                    seenSound = true
                }
            }
        }
        return (runs, longest)
    }
}
