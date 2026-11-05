import Foundation

/// The sounds Android's `ToneGenerator` makes (the phone plays them itself during a call, so they are not in the relayed
/// audio). Frequencies and cadences are the CEPT/ETSI ones of `ToneGenerator.cpp` (the default region, also Turkey's); the
/// constants are `ToneGenerator.TONE_SUP_*`. A tone that is not listed here is not played.
struct TonePattern: Equatable {
    struct Step: Equatable {
        let frequencies: [Double]
        let onMs: Int
        let offMs: Int
    }
    let steps: [Step]
    /// False for a single beep; true for a cadence that repeats until it is stopped.
    let loops: Bool
    /// A loop is stopped after this long even if the phone's `stop` never arrives (the link may be gone by then).
    let maxSeconds: Int
}

enum ToneSynth {
    static func pattern(for id: Int) -> TonePattern? {
        switch id {
        case 16: return TonePattern(steps: [.init(frequencies: [425], onMs: 1000, offMs: 0)], loops: true, maxSeconds: 8) // dial
        case 17: return TonePattern(steps: [.init(frequencies: [425], onMs: 500, offMs: 500)], loops: true, maxSeconds: 8) // busy
        case 18: return TonePattern(steps: [.init(frequencies: [425], onMs: 200, offMs: 200)], loops: true, maxSeconds: 8) // congestion
        case 19: return TonePattern(steps: [.init(frequencies: [425], onMs: 200, offMs: 0)], loops: false, maxSeconds: 8) // radio ack
        case 21: return TonePattern(steps: [ // error (special information tone)
            .init(frequencies: [950], onMs: 330, offMs: 0), .init(frequencies: [1400], onMs: 330, offMs: 0),
            .init(frequencies: [1800], onMs: 330, offMs: 1000),
        ], loops: true, maxSeconds: 8)
        case 22: return TonePattern(steps: [ // call waiting
            .init(frequencies: [425], onMs: 200, offMs: 600), .init(frequencies: [425], onMs: 200, offMs: 3000),
        ], loops: true, maxSeconds: 20)
        case 23: return TonePattern(steps: [.init(frequencies: [425], onMs: 1000, offMs: 4000)], loops: true, maxSeconds: 120) // ringback
        default: return nil
        }
    }

    /// One cycle of the pattern as 16-bit mono samples, with a short fade on every beep so it does not click.
    static func samples(_ pattern: TonePattern, rate: Int = 8000, amplitude: Double = 0.25) -> [Int16] {
        var out: [Int16] = []
        let fade = max(1, rate * 5 / 1000)
        for step in pattern.steps {
            let on = rate * step.onMs / 1000
            for i in 0..<on {
                let t = Double(i) / Double(rate)
                var v = step.frequencies.reduce(0.0) { $0 + sin(2 * .pi * $1 * t) } / Double(step.frequencies.count)
                let edge = min(i, on - 1 - i)
                if edge < fade { v *= Double(edge) / Double(fade) }
                out.append(Int16(max(-1, min(1, v * amplitude)) * 32767))
            }
            out.append(contentsOf: [Int16](repeating: 0, count: rate * step.offMs / 1000))
        }
        return out
    }

    /// A WAV file (what `AVAudioPlayer` plays from memory).
    static func wav(_ samples: [Int16], rate: Int = 8000) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + samples.count * 2); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(samples.count * 2)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}
