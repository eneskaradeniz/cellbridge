import AVFoundation
import CallKit
import Foundation

/// Spike B: does a free-account app survive a locked screen with a local WebSocket
/// kept up by a silent audio loop, and can CallKit ring from a WS message?
@MainActor
final class Model: NSObject, ObservableObject, CXProviderDelegate, URLSessionWebSocketDelegate {
    @Published var logText = ""
    @Published var status = "idle"

    private var url: URL?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var pingTimer: Timer?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var provider: CXProvider!
    private let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("spike.log")
    private let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.supportedHandleTypes = [.phoneNumber]
        provider = CXProvider(configuration: cfg)
        provider.setDelegate(self, queue: nil)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] n in
            Task { @MainActor in self?.onInterruption(n) }
        }
    }

    func log(_ s: String) {
        let line = "\(stamp.string(from: Date())) \(s)\n"
        logText = String((line + logText).prefix(6000))
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    func start(url: String) {
        guard let u = URL(string: url) else { return log("bad url") }
        self.url = u
        startKeepAlive()
        connect()
    }

    // MARK: keep-alive audio

    private func startKeepAlive() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, options: [.mixWithOthers])
            try s.setActive(true)
            if !engine.attachedNodes.contains(player) {
                let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: fmt)
                let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100)!
                buf.frameLength = 44100
                for i in 0..<Int(buf.frameLength) { buf.floatChannelData![0][i] = i % 2 == 0 ? 0.00003 : -0.00003 }
                player.scheduleBuffer(buf, at: nil, options: .loops)
            }
            if !engine.isRunning { try engine.start() }
            player.play()
            log("keepalive on")
        } catch { log("keepalive error \(error)") }
    }

    private func onInterruption(_ n: Notification) {
        let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
        log("audio interruption \(type == 1 ? "began" : "ended")")
        if type == 0 { startKeepAlive() }
    }

    // MARK: websocket

    private func connect() {
        guard let url else { return }
        task = session.webSocketTask(with: url)
        task?.resume()
        status = "connecting"
        receive()
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ping() }
        }
    }

    private func ping() {
        task?.sendPing { [weak self] err in
            if let err { Task { @MainActor in self?.log("ping fail: \(err.localizedDescription)") } }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let msg):
                    if case .string(let s) = msg { self.handle(s) }
                    self.receive()
                case .failure(let err):
                    self.status = "down"
                    self.log("ws closed: \(err.localizedDescription) — retry in 2s")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.connect()
                }
            }
        }
    }

    nonisolated func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        Task { @MainActor in
            self.status = "connected"
            self.log("ws open")
            self.task?.send(.string("{\"type\":\"hello\"}")) { _ in }
        }
    }

    private func handle(_ s: String) {
        log("rx \(s.prefix(80))")
        guard s.contains("\"ring\"") else { return }
        let u = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: "+905550000000")
        update.localizedCallerName = "CB Spike"
        update.hasVideo = false
        provider.reportNewIncomingCall(with: u, update: update) { [weak self] err in
            Task { @MainActor in self?.log(err == nil ? "callkit ringing" : "callkit error \(err!)") }
        }
    }

    // MARK: CXProviderDelegate

    nonisolated func providerDidReset(_ provider: CXProvider) {}

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in self.log("call answered") }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in self.log("call ended") }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in self.log("callkit audio active") }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in
            self.log("callkit audio deactivated")
            self.startKeepAlive()
        }
    }
}
