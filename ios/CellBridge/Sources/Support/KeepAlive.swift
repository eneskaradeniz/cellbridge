import AVFoundation

/// An inaudible looping buffer keeps the app running with the screen locked so the WebSocket stays up
/// (Spike B: a free-account app survives hours this way). Restarted whenever the system interrupts audio.
@MainActor
final class KeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private lazy var silence: AVAudioPCMBuffer = {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = i % 2 == 0 ? 0.00003 : -0.00003 }
        return buffer
    }()
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if type == AVAudioSession.InterruptionType.ended.rawValue { Task { @MainActor in self?.start() } }
        }
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            if !engine.attachedNodes.contains(player) {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }
            if !engine.isRunning { try engine.start() }
            player.stop() // a restart must not queue a second loop
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
        } catch {
            log("keep-alive audio failed: \(error.localizedDescription)")
        }
    }
}
