import AVFoundation

/// Plays what the phone says it is playing (docs/protocol.md `tone`): ringback, busy, the beep at the end of a call.
/// During a call it plays through the call's audio session; for the beep that comes with the end of a call it brings
/// the session up itself and lets go again afterwards.
@MainActor
final class ToneRenderer: NSObject, AVAudioPlayerDelegate {
    /// True while a call is on screen (CallKit owns the audio session then).
    var callIsActive: () -> Bool = { false }
    var log: (String) -> Void = { _ in }

    private var looping: AVAudioPlayer?
    private var oneShots: [AVAudioPlayer] = []
    private var sessionBorrowed = false

    func handle(_ command: ToneCommand) {
        switch command {
        case .generator(let id):
            guard let pattern = ToneSynth.pattern(for: id) else { return log("tone \(id) is not supported") }
            play(data: ToneSynth.wav(ToneSynth.samples(pattern)), loops: pattern.loops, maxSeconds: pattern.maxSeconds)
        case .media(let name):
            guard let url = Bundle.main.url(forResource: name, withExtension: "caf"), let data = try? Data(contentsOf: url) else {
                return log("no sound for the tone \(name)")
            }
            play(data: data, loops: false, maxSeconds: 0)
        case .stop:
            stopLoop()
        }
    }

    /// Ends a repeating tone; a beep that is playing finishes.
    func stopLoop() {
        looping?.stop()
        looping = nil
        releaseSessionIfIdle()
    }

    private func releaseSessionIfIdle() {
        guard sessionBorrowed, oneShots.isEmpty, looping == nil else { return }
        sessionBorrowed = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func play(data: Data, loops: Bool, maxSeconds: Int) {
        borrowSessionIfNoCall()
        guard let player = try? AVAudioPlayer(data: data) else { return log("tone could not be loaded") }
        player.delegate = self
        player.numberOfLoops = loops ? -1 : 0
        player.prepareToPlay()
        guard player.play() else { return log("tone could not be played") }
        if loops {
            looping?.stop()
            looping = player
            // The phone's `stop` may never arrive (the link is gone, the connection to its daemon closed): do not play forever.
            Task { @MainActor [weak self, weak player] in
                try? await Task.sleep(for: .seconds(maxSeconds))
                if let player, self?.looping === player { self?.stopLoop() }
            }
        } else {
            oneShots.append(player)
        }
    }

    /// With no call there is no CallKit session: take one for the beep (the call has just ended).
    private func borrowSessionIfNoCall() {
        guard !callIsActive(), !sessionBorrowed else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            sessionBorrowed = true
        } catch {
            log("tone: no audio session (\(error.localizedDescription))")
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.oneShots.removeAll { $0 === player }
            self.releaseSessionIfIdle()
        }
    }
}
