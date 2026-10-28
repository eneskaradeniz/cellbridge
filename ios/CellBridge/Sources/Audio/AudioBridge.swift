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
            let session = AVAudioSession.sharedInstance()
            let route = session.currentRoute.inputs.map(\.portName).joined(separator: ",")
            log("audio started, mic \(pipeline.inputDescription), permission \(Self.permission), input available \(session.isInputAvailable), route [\(route)]")
        } catch {
            log("audio start failed: \(error)")
        }
    }

    /// The call (or its audio session) is over.
    func sessionEnded() {
        endPipeline()
        keepAlive.start()
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
