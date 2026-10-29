import Foundation

/// Adaptive playout buffer for fixed-size audio frames numbered by a wrapping u16 sequence. A port of the
/// daemon's jitter.c with the same constants (docs/protocol.md): target 60-280 ms, starting at 60 ms.
/// push() may run on the network thread while pop() runs on the playout timer.
final class JitterBuffer {
    enum Result { case frame, concealed, priming }

    struct Stats: Equatable {
        var played = 0, concealed = 0, late = 0, duplicate = 0, overflow = 0
        /// Frames that arrived only as the redundant copy in the next packet.
        var recovered = 0
        var target = 0
    }

    private static let slots = 32 // also the largest sequence gap bridged before resyncing
    private static let minTarget = 3 // 60 ms: below that a phone's Wi-Fi power saving (100 ms bursts) starves it
    private static let startTarget = 3
    private static let maxTarget = 14 // 280 ms: Wi-Fi power saving was measured delivering audio after gaps of 260 ms
    private static let growStep = 2 // a starvation deepens the buffer by 40 ms
    private static let fadeFrames = 3 // concealed frames that still repeat the last one, quieter each time
    private static let extraBeforeDrop = 10 // a burst after a gap must not be thrown away
    private static let calmFramesToShrink = 250 // 5 s

    private struct Slot {
        var valid = false
        var seq: UInt16 = 0
        var frame: [Int16] = []
    }

    private let lock = NSLock()
    private let frameSamples: Int
    private var slots = [Slot](repeating: Slot(), count: JitterBuffer.slots)
    private var started = false
    private var next: UInt16 = 0
    private var buffered = 0
    private var target = JitterBuffer.startTarget
    private var calm = 0
    private var last: [Int16]?
    private var lostRun = 0
    private var stats = Stats()

    init(frameSamples: Int) { self.frameSamples = frameSamples }

    func push(seq: UInt16, frame: [Int16]) {
        lock.lock()
        defer { lock.unlock() }
        if !started {
            if buffered == 0 || distance(next, seq) < 0 { next = seq } // earliest sequence seen while priming
            if distance(next, seq) < Self.slots {
                store(seq, frame)
                if buffered >= target { started = true }
            }
            return
        }

        let d = distance(next, seq)
        if d < 0 {
            stats.late += 1
        } else if d >= Self.slots {
            // The sender jumped far ahead (outage, restart): start over from here.
            dropAll()
            started = false
            stats.overflow += 1
            next = seq
            store(seq, frame)
        } else {
            store(seq, frame)
            // Too far ahead of the playout clock: discard the oldest so latency stays bounded.
            while buffered > target + Self.extraBeforeDrop {
                let index = Int(next) % Self.slots
                if slots[index].valid && slots[index].seq == next {
                    slots[index].valid = false
                    buffered -= 1
                }
                next &+= 1
                stats.overflow += 1
            }
        }
    }

    /// The previous frame carried along with a packet: used only if that frame has not arrived, never counted as late or duplicate.
    func pushRedundant(seq: UInt16, frame: [Int16]) {
        lock.lock()
        defer { lock.unlock() }
        if !started {
            if buffered == 0 || distance(next, seq) < 0 { next = seq }
            if distance(next, seq) < Self.slots {
                _ = store(seq, frame, quiet: true)
                if buffered >= target { started = true }
            }
            return
        }
        let d = distance(next, seq)
        // Already played or concealed (d < 0), or implausibly far ahead: nothing to repair.
        if d >= 0 && d < Self.slots && store(seq, frame, quiet: true) { stats.recovered += 1 }
    }

    /// Call once per frame period. Priming frames come back as silence; a missing frame repeats the last played one,
    /// fading out over three frames and then silence, which sounds far less broken than a hole.
    func pop() -> (result: Result, frame: [Int16]) {
        lock.lock()
        defer { lock.unlock() }
        let silence = [Int16](repeating: 0, count: frameSamples)
        guard started else { return (.priming, silence) }

        let index = Int(next) % Self.slots
        defer { next &+= 1 }
        if slots[index].valid && slots[index].seq == next {
            let frame = slots[index].frame
            slots[index].valid = false
            buffered -= 1
            stats.played += 1
            last = frame
            lostRun = 0
            calm += 1
            if calm >= Self.calmFramesToShrink && target > Self.minTarget {
                target -= 1
                calm = 0
            }
            return (.frame, frame)
        }

        stats.concealed += 1
        lostRun += 1
        let concealed = conceal(silence)
        if buffered == 0 {
            // Starved, not just a lost packet: re-prime with a deeper buffer.
            started = false
            target = min(Self.maxTarget, target + Self.growStep)
            calm = 0
            last = nil // what follows the wait is not a continuation of that sound
        }
        return (.concealed, concealed)
    }

    func currentStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        var copy = stats
        copy.target = target
        return copy
    }

    // MARK: private (lock held)

    /// False (and a duplicate counted unless `quiet`) when the frame is already held.
    @discardableResult
    private func store(_ seq: UInt16, _ frame: [Int16], quiet: Bool = false) -> Bool {
        let index = Int(seq) % Self.slots
        if slots[index].valid && slots[index].seq == seq {
            if !quiet { stats.duplicate += 1 }
            return false
        }
        if slots[index].valid { buffered -= 1 } // an old frame of a previous lap is overwritten
        slots[index] = Slot(valid: true, seq: seq, frame: frame)
        buffered += 1
        return true
    }

    /// The last played frame, quieter for each frame in a row that is missing: 3/4, 2/4, 1/4, then silence.
    private func conceal(_ silence: [Int16]) -> [Int16] {
        guard let last, lostRun <= Self.fadeFrames else { return silence }
        let gain = Self.fadeFrames + 1 - lostRun // out of 4
        return last.map { Int16(Int($0) * gain / 4) }
    }

    private func dropAll() {
        for i in slots.indices { slots[i].valid = false }
        buffered = 0
    }

    /// Signed distance from `from` to `to` on the wrapping sequence circle.
    private func distance(_ from: UInt16, _ to: UInt16) -> Int { Int(Int16(bitPattern: to &- from)) }
}
