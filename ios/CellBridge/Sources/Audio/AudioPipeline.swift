import AVFoundation
import Foundation

/// Microphone -> 16 kHz mono S16 -> UDP, and UDP -> jitter buffer -> speaker, for one call.
/// Works on audio and network threads only; AudioBridge owns it on the main actor.
final class AudioPipeline: @unchecked Sendable {
    enum Failure: Error { case formats }

    /// How much of iOS's voice processing the microphone path uses. `full` is echo cancellation + noise suppression +
    /// automatic gain; the others exist to find which part makes the voice sound robotic.
    enum VoiceProcessing: String, CaseIterable {
        case full, fullNoAGC, bypassed, off
    }

    /// How microphone audio leaves the engine: an installed tap (whose buffers turned out to contain exact-zero
    /// chunks of 1104 frames) or an AVAudioSinkNode fed straight from the render cycle.
    enum CaptureMethod: String {
        case tap, sink
    }

    static let hostAudioPort: UInt16 = 8767

    let localPort: UInt16
    var muted = false // read on the capture thread; a stale read costs at most one frame

    private let socket: UdpSocket
    private let jitter = JitterBuffer(frameSamples: AudioPacket.samplesPerFrame)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var timer: DispatchSourceTimer?
    private var pending: [Int16] = [] // capture thread only
    // The microphone delivers 100 ms blocks (5 frames at once); frames wait here and leave one per 20 ms so the host
    // sees an even stream instead of bursts its jitter buffer cannot absorb.
    private let outboxLock = NSLock()
    private var outbox: [[Int16]] = []
    private var droppedFrames = 0
    private var sendTimer: DispatchSourceTimer?
    private var sequence: UInt16 = 0   // send timer only
    private var framesSent = 0         // send timer only
    private let micSink = AVAudioMixerNode() // keeps the input unit connected; muted so the mic never loops back
    private var configChanges = 0
    private var observer: NSObjectProtocol?
    private var txSumSq = 0.0, txSamples = 0 // capture thread only
    private var rxSumSq = 0.0, rxSamples = 0, scheduledFrames = 0 // playout queue only
    /// Debug (Settings > record): the audio as it is played, raw 16 kHz S16 mono, to compare with the daemon's capture.
    private let dumpLock = NSLock() // the handles are used by the capture, send and playout threads and closed by stop()
    private var playoutDump: FileHandle?
    private var sentDump: FileHandle? // what the microphone path hands to the network (after voice processing)
    private var lastArrival: UInt64 = 0, longGaps = 0, backToBack = 0, maxGapMs = 0 // receive thread only
    // Playout queue: how many frames sit in the player ahead of the speaker. The timer that feeds it is not exact, so a
    // small cushion of silence keeps the player from running dry between two ticks (which sounds like clicks).
    private static let cushionFrames = 2
    private var playoutStarted = false
    private var minQueueDepth = Int.max, queueUnderruns = 0 // playout queue only
    // Playback evidence: frames the player reports as really played, and the level the mixer actually renders.
    private let meterLock = NSLock()
    private var playedBack = 0
    private var mixSumSq = 0.0, mixSamples = 0
    private var lastSend: UInt64 = 0, maxSendGapMs = 0, longSendGaps = 0 // send timer only
    private var tapCalls = 0
    private var conversionFailures = 0
    private var lastFailure = ""
    private var converter: AVAudioConverter? // capture thread only; rebuilt if the input format changes
    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    /// What the microphone delivers, for the log (voice processing can change the channel count).
    private(set) var inputDescription = ""

    private let voiceProcessing: VoiceProcessing
    private let captureMethod: CaptureMethod
    private let rateLock = NSLock()
    private var inputSampleRate = 48_000.0 // refreshed once the engine runs and the hardware format has settled
    private var sinkNode: AVAudioSinkNode?
    private let captureQueue = DispatchQueue(label: "cellbridge.capture", qos: .userInteractive)
    private let sentDumpName: String?
    /// Debug: the microphone exactly as the engine's tap delivers it (native rate, channel 0, S16), before our
    /// conversion; tells a faulty microphone stream from a faulty conversion.
    var rawDumpName: String?
    private var rawDump: FileHandle?

    private func write(_ data: Data, to handle: KeyPath<AudioPipeline, FileHandle?>) {
        dumpLock.lock()
        defer { dumpLock.unlock() }
        try? self[keyPath: handle]?.write(contentsOf: data)
    }

    /// `sentDumpName` (debug): file name in Caches that receives what the microphone path sends, raw 16 kHz S16 mono.
    init(host: String, voiceProcessing: VoiceProcessing = .full, captureMethod: CaptureMethod = .sink,
         sentDumpName: String? = nil) throws {
        socket = try UdpSocket(peerHost: host, peerPort: Self.hostAudioPort)
        localPort = socket.port
        self.voiceProcessing = voiceProcessing
        self.captureMethod = captureMethod
        self.sentDumpName = sentDumpName
    }

    /// The call's audio session must already be active (CallKit's didActivate).
    func start() throws {
        if voiceProcessing != .off {
            try engine.inputNode.setVoiceProcessingEnabled(true) // echo cancellation, noise suppression, gain control
            if voiceProcessing == .fullNoAGC { engine.inputNode.isVoiceProcessingAGCEnabled = false }
            if voiceProcessing == .bypassed { engine.inputNode.isVoiceProcessingBypassed = true }
        }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        inputDescription = "\(inputFormat.channelCount) ch, \(Int(inputFormat.sampleRate)) Hz"

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        if UserDefaults.standard.bool(forKey: "recordAudio") {
            let url = caches.appendingPathComponent("rx_playout.raw")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            playoutDump = try? FileHandle(forWritingTo: url)
        }
        if let rawDumpName {
            let raw = caches.appendingPathComponent(rawDumpName + ".raw")
            FileManager.default.createFile(atPath: raw.path, contents: nil)
            rawDump = try? FileHandle(forWritingTo: raw)
        }
        if let sentDumpName {
            let sent = caches.appendingPathComponent(sentDumpName + ".raw")
            FileManager.default.createFile(atPath: sent.path, contents: nil)
            sentDump = try? FileHandle(forWritingTo: sent)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        switch captureMethod {
        case .tap:
            engine.attach(micSink)
            micSink.outputVolume = 0
            engine.connect(input, to: micSink, format: inputFormat)
            engine.connect(micSink, to: engine.mainMixerNode, format: nil)
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [self] buffer, _ in
                capture(buffer)
            }
        case .sink:
            // Straight from the render cycle (an installed tap delivered exact-zero chunks of 1104 frames every few
            // slices): copy the samples out and do the heavy work off the real-time thread.
            let sink = AVAudioSinkNode { [self] _, frameCount, audioBufferList in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
                guard let data = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                let samples = Array(UnsafeBufferPointer(start: data, count: Int(frameCount)))
                captureQueue.async { [self] in
                    rateLock.lock()
                    let rate = inputSampleRate
                    rateLock.unlock()
                    guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
                          let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
                    buffer.frameLength = AVAudioFrameCount(samples.count)
                    buffer.floatChannelData![0].update(from: samples, count: samples.count)
                    capture(buffer)
                }
                return noErr
            }
            sinkNode = sink
            engine.attach(sink)
            // The engine picks the format: one guessed from before the voice-processing unit settled raised an
            // Objective-C exception (uncatchable from Swift) when pipelines were started in quick succession.
            engine.connect(input, to: sink, format: nil)
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            var sum = 0.0
            for i in 0..<Int(buffer.frameLength) { sum += Double(samples[i]) * Double(samples[i]) }
            meterLock.lock()
            mixSumSq += sum
            mixSamples += Int(buffer.frameLength)
            meterLock.unlock()
        }
        // A route or format change stops the engine; without a restart both directions would go silent.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [self] _ in
            configChanges += 1
            if !engine.isRunning { try? engine.start() }
            // After the restart the player's isPlaying cannot be trusted: it stays true while the node renders only
            // silence (measured: mixer level 0.0000 with voice processing on). stop() + play() is what revives it.
            player.stop()
            player.play()
        }
        engine.prepare()
        try engine.start()
        // The rate the samples really have: the sink's own input format first; a pipeline started right after another
        // one saw 0 from the input node here, and an unusable rate must never reach the conversion code.
        let candidates = [sinkNode?.inputFormat(forBus: 0).sampleRate, engine.inputNode.outputFormat(forBus: 0).sampleRate,
                          AVAudioSession.sharedInstance().sampleRate]
        let settled = candidates.compactMap { $0 }.first { $0.isFinite && $0 >= 8_000 && $0 <= 192_000 } ?? 48_000
        rateLock.lock()
        inputSampleRate = settled
        rateLock.unlock()
        player.play()

        socket.startReceiving { [self] data in
            noteArrival()
            if let packet = AudioPacket.decode(data) { jitter.push(seq: packet.seq, frame: packet.pcm) }
        }
        let sender = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "cellbridge.send", qos: .userInteractive))
        sender.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(1))
        sender.setEventHandler { [self] in sendOneFrame() }
        sender.resume()
        sendTimer = sender

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "cellbridge.playout", qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(1))
        timer.setEventHandler { [self] in playOneFrame() }
        timer.resume()
        self.timer = timer
    }

    /// Stops everything and returns a one-line summary for the log.
    func stop() -> String {
        // Order matters: stop everything that produces audio, wait for the capture work already queued, and only
        // then close the files and the socket those threads write to.
        sendTimer?.cancel()
        sendTimer = nil
        timer?.cancel()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let engineWasRunning = engine.isRunning
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        captureQueue.sync {}
        dumpLock.lock()
        try? playoutDump?.close()
        playoutDump = nil
        try? sentDump?.close()
        sentDump = nil
        try? rawDump?.close()
        rawDump = nil
        dumpLock.unlock()
        socket.close()
        let s = jitter.currentStats()
        return "audio stopped: sent=\(framesSent) played=\(s.played) concealed=\(s.concealed) late=\(s.late) overflow=\(s.overflow) target=\(s.target)"
            + " | mic taps=\(tapCalls) conversion failures=\(conversionFailures) \(lastFailure) engine running=\(engineWasRunning) config changes=\(configChanges)"
            + " dropped at send=\(droppedFrames)"
            + " | play queue: min depth=\(minQueueDepth == Int.max ? 0 : minQueueDepth), ran dry=\(queueUnderruns)"
            + " | arrival gaps: max=\(maxGapMs) ms, over 60 ms=\(longGaps), under 5 ms=\(backToBack)"
            + " | send gaps: max=\(maxSendGapMs) ms, over 40 ms=\(longSendGaps)"
            + String(format: " | played back=%d mixer rms=%.4f", meterSnapshot().playedBack, meterSnapshot().rms)
            + String(format: " | tx rms=%.0f rx rms=%.0f scheduled=%d", txSamples > 0 ? (txSumSq / Double(txSamples)).squareRoot() : 0,
                     rxSamples > 0 ? (rxSumSq / Double(rxSamples)).squareRoot() : 0, scheduledFrames)
    }

    private func meterSnapshot() -> (playedBack: Int, rms: Double) {
        meterLock.lock()
        defer { meterLock.unlock() }
        return (playedBack, mixSamples > 0 ? (mixSumSq / Double(mixSamples)).squareRoot() : 0)
    }

    // MARK: capture

    private func capture(_ buffer: AVAudioPCMBuffer) {
        tapCalls += 1
        if let channel = buffer.floatChannelData?[0] {
            var ints = [Int16](repeating: 0, count: Int(buffer.frameLength))
            for i in 0..<ints.count {
                let value = channel[i]
                ints[i] = value.isFinite ? Int16(max(-1, min(1, value)) * 32767) : 0 // a NaN would trap in the conversion
            }
            ints.withUnsafeBytes { write(Data($0), to: \.rawDump) }
        }
        guard !muted else { pending.removeAll(keepingCapacity: true); return }
        guard let mono = firstChannel(of: buffer) else { return fail("unsupported mic format \(buffer.format)") }
        if converter == nil || converter?.inputFormat != mono.format {
            converter = AVAudioConverter(from: mono.format, to: wire)
        }
        guard let converter else { return fail("no converter from \(mono.format)") }

        let sourceRate = mono.format.sampleRate
        guard sourceRate.isFinite, sourceRate >= 8_000, sourceRate <= 192_000 else { return fail("odd input rate \(sourceRate)") }
        let capacity = AVAudioFrameCount(min(Double(mono.frameLength) * 16_000 / sourceRate, 1_000_000)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return fail("no output buffer") }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return mono
        }
        if let error { return fail("convert: \(error.localizedDescription)") }
        guard let samples = converted.int16ChannelData?[0] else { return fail("no int16 data") }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))

        while pending.count >= AudioPacket.samplesPerFrame {
            let frame = Array(pending.prefix(AudioPacket.samplesPerFrame))
            pending.removeFirst(AudioPacket.samplesPerFrame)
            txSumSq += frame.reduce(0) { $0 + Double($1) * Double($1) }
            txSamples += frame.count
            enqueue(frame)
        }
    }

    /// Bounded: if the clocks drift apart, the oldest audio goes instead of the delay growing.
    private func enqueue(_ frame: [Int16]) {
        outboxLock.lock()
        outbox.append(frame)
        if outbox.count > Self.maxQueuedFrames {
            let excess = outbox.count - Self.keepQueuedFrames
            outbox.removeFirst(excess)
            droppedFrames += excess
        }
        outboxLock.unlock()
    }

    private func sendOneFrame() {
        outboxLock.lock()
        let frame = outbox.isEmpty ? nil : outbox.removeFirst()
        outboxLock.unlock()
        guard let frame else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if lastSend != 0 {
            let gapMs = Int((now - lastSend) / 1_000_000)
            maxSendGapMs = max(maxSendGapMs, gapMs)
            if gapMs > 40 { longSendGaps += 1 }
        }
        lastSend = now
        frame.withUnsafeBytes { write(Data($0), to: \.sentDump) }
        socket.send(AudioPacket.encode(seq: sequence, pcm: frame))
        sequence &+= 1
        framesSent += 1
    }

    private static let maxQueuedFrames = 12 // 240 ms
    private static let keepQueuedFrames = 6

    /// Voice processing may deliver several channels; the call needs one, so take the first and convert only that.
    private func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let channels = buffer.floatChannelData else { return nil }
        if buffer.format.channelCount == 1 { return buffer }
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else { return nil }
        mono.frameLength = buffer.frameLength
        mono.floatChannelData![0].update(from: channels[0], count: Int(buffer.frameLength))
        return mono
    }

    private func fail(_ reason: String) {
        conversionFailures += 1
        lastFailure = reason
    }

    /// Spacing of arriving packets: tells network batching (long gap, then a burst) from an even stream.
    private func noteArrival() {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { lastArrival = now }
        guard lastArrival != 0 else { return }
        let gapMs = Int((now - lastArrival) / 1_000_000)
        if gapMs > 60 { longGaps += 1 }
        if gapMs < 5 { backToBack += 1 }
        maxGapMs = max(maxGapMs, gapMs)
    }

    // MARK: playback

    private func playOneFrame() {
        let (result, frame) = jitter.pop()
        guard result != .priming else { return } // nothing to play yet: the player simply stays silent
        if !playoutStarted {
            playoutStarted = true
            addCushion()
        }
        let queued = scheduledFrames - meterSnapshot().playedBack
        if queued <= 0 {
            queueUnderruns += 1 // the player ran dry before this tick
            addCushion()
        } else {
            minQueueDepth = min(minQueueDepth, queued)
        }
        if result == .frame {
            rxSumSq += frame.reduce(0) { $0 + Double($1) * Double($1) }
            rxSamples += frame.count
        }
        frame.withUnsafeBytes { write(Data($0), to: \.playoutDump) }
        schedule(frame)
    }

    private func addCushion() {
        for _ in 0..<Self.cushionFrames { schedule([Int16](repeating: 0, count: AudioPacket.samplesPerFrame)) }
    }

    private func schedule(_ frame: [Int16]) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frame.count)) else { return }
        scheduledFrames += 1
        buffer.frameLength = AVAudioFrameCount(frame.count)
        let out = buffer.floatChannelData![0]
        for i in 0..<frame.count { out[i] = Float(frame[i]) / 32768 }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [self] _ in
            meterLock.lock()
            playedBack += 1
            meterLock.unlock()
        }
    }
}
