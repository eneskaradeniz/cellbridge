import AVFoundation
import Foundation

/// Microphone -> 16 kHz mono S16 -> UDP, and UDP -> jitter buffer -> speaker, for one call.
/// Works on audio and network threads only; AudioBridge owns it on the main actor.
final class AudioPipeline: @unchecked Sendable {
    enum Failure: Error { case formats }

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
    private var lastArrival: UInt64 = 0, longGaps = 0, backToBack = 0, maxGapMs = 0 // receive thread only
    private var tapCalls = 0
    private var conversionFailures = 0
    private var lastFailure = ""
    private var converter: AVAudioConverter? // capture thread only; rebuilt if the input format changes
    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    /// What the microphone delivers, for the log (voice processing can change the channel count).
    private(set) var inputDescription = ""

    init(host: String) throws {
        socket = try UdpSocket(peerHost: host, peerPort: Self.hostAudioPort)
        localPort = socket.port
    }

    /// The call's audio session must already be active (CallKit's didActivate).
    func start() throws {
        try engine.inputNode.setVoiceProcessingEnabled(true) // echo cancellation, noise suppression, gain control
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        inputDescription = "\(inputFormat.channelCount) ch, \(Int(inputFormat.sampleRate)) Hz"

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.attach(micSink)
        micSink.outputVolume = 0
        engine.connect(input, to: micSink, format: inputFormat)
        engine.connect(micSink, to: engine.mainMixerNode, format: nil)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [self] buffer, _ in
            capture(buffer)
        }
        // A route or format change stops the engine; without a restart both directions would go silent.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [self] _ in
            configChanges += 1
            if !engine.isRunning { try? engine.start() }
            if !player.isPlaying { player.play() }
        }
        engine.prepare()
        try engine.start()
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
        sendTimer?.cancel()
        sendTimer = nil
        timer?.cancel()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let engineWasRunning = engine.isRunning
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        socket.close()
        let s = jitter.currentStats()
        return "audio stopped: sent=\(framesSent) played=\(s.played) concealed=\(s.concealed) late=\(s.late) overflow=\(s.overflow) target=\(s.target)"
            + " | mic taps=\(tapCalls) conversion failures=\(conversionFailures) \(lastFailure) engine running=\(engineWasRunning) config changes=\(configChanges)"
            + " dropped at send=\(droppedFrames)"
            + " | arrival gaps: max=\(maxGapMs) ms, over 60 ms=\(longGaps), under 5 ms=\(backToBack)"
            + String(format: " | tx rms=%.0f rx rms=%.0f scheduled=%d", txSamples > 0 ? (txSumSq / Double(txSamples)).squareRoot() : 0,
                     rxSamples > 0 ? (rxSumSq / Double(rxSamples)).squareRoot() : 0, scheduledFrames)
    }

    // MARK: capture

    private func capture(_ buffer: AVAudioPCMBuffer) {
        tapCalls += 1
        guard !muted else { pending.removeAll(keepingCapacity: true); return }
        guard let mono = firstChannel(of: buffer) else { return fail("unsupported mic format \(buffer.format)") }
        if converter == nil || converter?.inputFormat != mono.format {
            converter = AVAudioConverter(from: mono.format, to: wire)
        }
        guard let converter else { return fail("no converter from \(mono.format)") }

        let capacity = AVAudioFrameCount(Double(mono.frameLength) * 16_000 / mono.format.sampleRate) + 32
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
        guard result != .priming, // nothing to play yet: the player simply stays silent
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frame.count)) else { return }
        if result == .frame {
            rxSumSq += frame.reduce(0) { $0 + Double($1) * Double($1) }
            rxSamples += frame.count
        }
        scheduledFrames += 1
        buffer.frameLength = AVAudioFrameCount(frame.count)
        let out = buffer.floatChannelData![0]
        for i in 0..<frame.count { out[i] = Float(frame[i]) / 32768 }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}
