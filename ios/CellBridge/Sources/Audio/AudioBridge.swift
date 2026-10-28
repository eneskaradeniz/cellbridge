import AVFoundation
import Foundation

/// Owns the audio of the current call: prepared when the user answers (so the UDP port can go into `answer`),
/// started when CallKit activates the session, stopped when the session ends.
@MainActor
final class AudioBridge {
    private var pipeline: AudioPipeline?
    private let keepAlive: KeepAlive
    private let log: (String) -> Void

    var muted = false { didSet { pipeline?.muted = muted } }

    /// Voice-chat audio comes out of the earpiece by default; this switches to the loudspeaker.
    var speaker = false { didSet { applyOutputRoute() } }

    init(keepAlive: KeepAlive, log: @escaping (String) -> Void) {
        self.keepAlive = keepAlive
        self.log = log
    }

    /// Opens the UDP socket towards the host and returns its local port, nil if audio cannot be set up
    /// (the call then simply stays control-only).
    func prepare(host: String) -> UInt16? {
        endPipeline()
        do {
            keepAlive.stop() // its playback-only session would fight the call's voice-chat session
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [])
            let pipeline = try AudioPipeline(
                host: host,
                voiceProcessing: Self.storedVoiceProcessing,
                sentDumpName: UserDefaults.standard.bool(forKey: "recordAudio") ? "tx_capture" : nil
            )
            pipeline.muted = muted
            self.pipeline = pipeline
            return pipeline.localPort
        } catch {
            log("audio unavailable: \(error)")
            keepAlive.start()
            return nil
        }
    }

    /// CallKit has activated the audio session.
    func start() {
        guard let pipeline else { return }
        do {
            try pipeline.start()
            applyOutputRoute()
            let session = AVAudioSession.sharedInstance()
            let input = session.currentRoute.inputs.map(\.portName).joined(separator: ",")
            let output = session.currentRoute.outputs.map(\.portName).joined(separator: ",")
            log("audio started, mic \(pipeline.inputDescription), permission \(Self.permission), input [\(input)], output [\(output)]")
            // The route can change once the call settles (speaker button, Bluetooth), and the call volume is separate
            // from the media volume: both are worth seeing a moment into the call.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.pipeline != nil else { return }
                let s = AVAudioSession.sharedInstance()
                self.log("audio 3 s in: output [\(s.currentRoute.outputs.map(\.portName).joined(separator: ","))], volume \(String(format: "%.2f", s.outputVolume)), speaker \(self.speaker)")
            }
        } catch {
            log("audio start failed: \(error)")
        }
    }

    /// The call (or its audio session) is over.
    func sessionEnded() {
        speaker = false // the next call starts on the earpiece again
        endPipeline()
        keepAlive.start()
    }

    private func applyOutputRoute() {
        guard pipeline != nil else { return }
        do { try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none) } catch {
            log("could not switch the output: \(error.localizedDescription)")
        }
    }

    private func endPipeline() {
        guard let pipeline else { return }
        log(pipeline.stop())
        self.pipeline = nil
    }

    private static var permission: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "granted"
        case .denied: return "DENIED"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    /// Settings > Voice processing; `full` unless the user picked another one to compare.
    static var storedVoiceProcessing: AudioPipeline.VoiceProcessing {
        UserDefaults.standard.string(forKey: "voiceProcessing").flatMap(AudioPipeline.VoiceProcessing.init(rawValue:)) ?? .full
    }
}
