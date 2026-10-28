import AVFoundation
import Foundation

/// Plays a tone through the same kind of engine graph a call uses and measures what the mixer really renders, with
/// the graph built in different ways. Needs no call and no host: it answers "does this graph make sound at all?".
@MainActor
enum AudioSelfTest {
    /// What the configuration-change handler does after the engine stopped itself.
    enum Recovery {
        case engineOnly        // start the engine, call play() only if the player claims not to play (the old call code)
        case engineAndPlayer   // start the engine, then stop() and play() the player: its isPlaying is not to be trusted
    }

    struct Variant {
        let name: String
        let voiceProcessing: Bool
        let micSink: Bool
        let recovery: Recovery
    }

    static let variants = [
        Variant(name: "VP + sink, engine only (old call code)", voiceProcessing: true, micSink: true, recovery: .engineOnly),
        Variant(name: "VP + sink, engine and player reset", voiceProcessing: true, micSink: true, recovery: .engineAndPlayer),
        Variant(name: "VP, no sink, engine and player reset", voiceProcessing: true, micSink: false, recovery: .engineAndPlayer),
        Variant(name: "no voice processing", voiceProcessing: false, micSink: false, recovery: .engineOnly),
    ]

    static func run(log: @escaping (String) -> Void) async {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
            try session.setActive(true)
        } catch {
            return log("audio test: session failed: \(error.localizedDescription)")
        }
        for variant in variants {
            log(await measure(variant))
        }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func measure(_ variant: Variant) async -> String {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let sink = AVAudioMixerNode()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let meter = Meter()
        var configChanges = 0
        var observer: NSObjectProtocol?
        do {
            if variant.voiceProcessing { try engine.inputNode.setVoiceProcessingEnabled(true) }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            if variant.micSink {
                let inputFormat = engine.inputNode.outputFormat(forBus: 0)
                engine.attach(sink)
                sink.outputVolume = 0
                engine.connect(engine.inputNode, to: sink, format: inputFormat)
                engine.connect(sink, to: engine.mainMixerNode, format: nil)
            }
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
                guard let samples = buffer.floatChannelData?[0] else { return }
                var sum = 0.0
                for i in 0..<Int(buffer.frameLength) { sum += Double(samples[i]) * Double(samples[i]) }
                meter.add(sum, Int(buffer.frameLength))
            }
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
                configChanges += 1
                if !engine.isRunning { try? engine.start() }
                switch variant.recovery {
                case .engineOnly:
                    if !player.isPlaying { player.play() }
                case .engineAndPlayer:
                    player.stop()
                    player.play()
                }
            }
            engine.prepare()
            try engine.start()
            player.play()
            // A 440 Hz tone in 20 ms buffers, queued ahead; re-queued after a restart in the second half.
            for round in 0..<2 {
                for index in 0..<50 {
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320)!
                    buffer.frameLength = 320
                    let out = buffer.floatChannelData![0]
                    for n in 0..<320 { out[n] = 0.3 * Float(sin(2 * Double.pi * 440 * Double((round * 50 + index) * 320 + n) / 16_000)) }
                    player.scheduleBuffer(buffer, completionHandler: nil)
                }
                try? await Task.sleep(for: .seconds(1))
            }
            let (rms, samples) = meter.snapshot()
            let playing = player.isPlaying, running = engine.isRunning
            if let observer { NotificationCenter.default.removeObserver(observer) }
            engine.mainMixerNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
            return String(format: "audio test [%@]: mixer rms=%.4f (%d samples), engine running=%@, player playing=%@, config changes=%d",
                          variant.name, rms, samples, "\(running)", "\(playing)", configChanges)
        } catch {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            return "audio test [\(variant.name)]: failed: \(error.localizedDescription)"
        }
    }

    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var sumSq = 0.0, samples = 0

        func add(_ sum: Double, _ count: Int) {
            lock.lock()
            sumSq += sum
            samples += count
            lock.unlock()
        }

        func snapshot() -> (Double, Int) {
            lock.lock()
            defer { lock.unlock() }
            return (samples > 0 ? (sumSq / Double(samples)).squareRoot() : 0, samples)
        }
    }

    // MARK: microphone test

    private struct MicVariant {
        let name: String
        let voiceProcessing: AudioPipeline.VoiceProcessing
        let mode: AVAudioSession.Mode
        let method: AudioPipeline.CaptureMethod
    }

    // Only setups that are known not to raise an Objective-C exception: an exception inside AVAudioEngine cannot be
    // caught from Swift and ends the app (seen with voice processing bypassed and a tap).
    private static let micVariants = [
        MicVariant(name: "full, tap (old call path)", voiceProcessing: .full, mode: .voiceChat, method: .tap),
        MicVariant(name: "full, sink node (new call path)", voiceProcessing: .full, mode: .voiceChat, method: .sink),
        MicVariant(name: "full, sink node (again)", voiceProcessing: .full, mode: .voiceChat, method: .sink),
    ]
    static let micTestSeconds = 4

    /// Runs the call's real microphone path (AudioPipeline) for a few seconds per setting (about 18 s in all) without a call, keeps each
    /// recording in Caches/mic_<n>.raw and logs how much of it is digital silence. Speak steadily the whole time.
    static func micTest(log: @escaping (String) -> Void) async {
        let session = AVAudioSession.sharedInstance()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for (index, variant) in micVariants.enumerated() {
            do {
                try session.setCategory(.playAndRecord, mode: variant.mode, options: [])
                try session.setActive(true)
                let pipeline = try AudioPipeline(host: "127.0.0.1", voiceProcessing: variant.voiceProcessing, captureMethod: variant.method, sentDumpName: "mic_\(index)")
                pipeline.rawDumpName = "mic_\(index)_raw"
                try pipeline.start()
                try? await Task.sleep(for: .seconds(micTestSeconds))
                let summary = pipeline.stop()
                let taps = summary.components(separatedBy: " | ").first { $0.hasPrefix("mic taps=") } ?? "mic taps=?"
                let raw = (try? Data(contentsOf: caches.appendingPathComponent("mic_\(index).raw"))) ?? Data()
                let stats = FrameStats(raw: raw)
                let rawStream = (try? Data(contentsOf: caches.appendingPathComponent("mic_\(index)_raw.raw"))) ?? Data()
                let artifact = ZeroChops.count(in: rawStream, minRun: 1_000, maxRun: 1_200) // the 1104-frame signature of the fault
                let pauses = ZeroChops.count(in: rawStream, minRun: 1_201) // longer: real pauses in speech
                log("mic test \(index) [\(variant.name)]: \(stats.frames) frames, \(stats.zeroPercent)% silence, raw stream: \(artifact.runs) chops of the fault (1104-frame zeros), \(pauses.runs) longer pauses, \(taps.prefix(40))")
            } catch {
                log("mic test \(index) [\(variant.name)]: failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(2)) // let the audio hardware settle before the next engine
        }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
