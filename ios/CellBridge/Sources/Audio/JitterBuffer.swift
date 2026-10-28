import Foundation

/// Adaptive playout buffer for fixed-size audio frames numbered by a wrapping u16 sequence. A port of the
/// daemon's jitter.c with the same constants (docs/protocol.md): target 60-160 ms, starting at 60 ms.
/// push() may run on the network thread while pop() runs on the playout timer.
final class JitterBuffer {
    enum Result { case frame, concealed, priming }

    struct Stats: Equatable {
        var played = 0, concealed = 0, late = 0, duplicate = 0, overflow = 0
        var target = 0
    }

    private static let slots = 32 // also the largest sequence gap bridged before resyncing
    private static let minTarget = 3 // 60 ms: below that a phone's Wi-Fi power saving (100 ms bursts) starves it
    private static let startTarget = 3
    private static let maxTarget = 8 // 160 ms
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

    /// Call once per frame period. Missing and priming frames come back as silence.
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
            calm += 1
            if calm >= Self.calmFramesToShrink && target > Self.minTarget {
                target -= 1
                calm = 0
            }
            return (.frame, frame)
        }

        stats.concealed += 1
        if buffered == 0 {
            // Starved, not just a lost packet: re-prime with a deeper buffer.
            started = false
            if target < Self.maxTarget { target += 1 }
            calm = 0
        }
        return (.concealed, silence)
    }

    func currentStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        var copy = stats
        copy.target = target
        return copy
    }

    // MARK: private (lock held)

    private func store(_ seq: UInt16, _ frame: [Int16]) {
        let index = Int(seq) % Self.slots
        if slots[index].valid && slots[index].seq == seq {
            stats.duplicate += 1
            return
        }
        if slots[index].valid { buffered -= 1 } // an old frame of a previous lap is overwritten
        slots[index] = Slot(valid: true, seq: seq, frame: frame)
        buffered += 1
    }

    private func dropAll() {
        for i in slots.indices { slots[i].valid = false }
        buffered = 0
    }

    /// Signed distance from `from` to `to` on the wrapping sequence circle.
    private func distance(_ from: UInt16, _ to: UInt16) -> Int { Int(Int16(bitPattern: to &- from)) }
}
