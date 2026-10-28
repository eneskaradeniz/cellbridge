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
            let pipeline = try AudioPipeline(host: host)
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
}
