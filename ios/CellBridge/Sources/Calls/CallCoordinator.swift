import AVFoundation
import CallKit
import Foundation

/// Shows the host's calls in the system call UI and sends the user's answer / decline / hang-up back.
@MainActor
final class CallCoordinator: NSObject, ObservableObject, CXProviderDelegate {
    private let provider: CXProvider
    private let controller = CXCallController()
    private var book = CallBook() { didSet { active = book.active } }

    /// Calls to show on screen; the system call UI is only taken over on the lock screen.
    @Published private(set) var active: [ActiveCall] = []

    /// Why the last attempt to place a call failed, in words for the user; cleared by the next attempt.
    @Published private(set) var dialError: String?

    /// The call that just ended, kept for a moment so the screen can say so instead of vanishing.
    @Published private(set) var ended: ActiveCall?

    /// Loudspeaker on/off for the current call.
    @Published var speaker = false { didSet { audio.speaker = speaker } }

    /// Microphone muted for the current call (set through the system so CallKit's own UI stays in step).
    @Published private(set) var muted = false
    private let audio: AudioBridge
    private let host: () -> String
    private let hostOffersAudio: () -> Bool
    private let send: (ClientMessage) -> Void
    private let log: (String) -> Void
    private let onFinished: (CallRecord) -> Void
    private let nameFor: (String) -> String?

    init(audio: AudioBridge, host: @escaping () -> String, hostOffersAudio: @escaping () -> Bool,
         nameFor: @escaping (String) -> String?, send: @escaping (ClientMessage) -> Void,
         onFinished: @escaping (CallRecord) -> Void, log: @escaping (String) -> Void) {
        self.nameFor = nameFor
        self.onFinished = onFinished
        self.audio = audio
        self.host = host
        self.hostOffersAudio = hostOffersAudio
        self.send = send
        self.log = log
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber, .generic]
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            Task { @MainActor in self?.routeChanged(reason: reason) }
        }
    }

    /// The route picker (AirPods, the earpiece, the speaker) changes the route behind our speaker button's back.
    private func routeChanged(reason: AVAudioSession.RouteChangeReason?) {
        guard !active.isEmpty else { return }
        let onSpeaker = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        // Only an explicit choice (override) may switch the speaker on: before a call settles the route can pass through it.
        if (reason == .override && onSpeaker != speaker) || (speaker && !onSpeaker) { speaker = onSpeaker }
    }

    /// Starts an outgoing call through the system, so CallKit and the audio session are set up as for any other call.
    func dial(_ number: String) {
        dialError = nil
        let action = CXStartCallAction(call: UUID(), handle: CXHandle(type: .phoneNumber, value: number))
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.dialError = String(localized: "Could not start the call: \(error.localizedDescription)") }
        }
    }

    /// A call was asked for while the phone cannot be reached.
    func reportNotConnected() { dialError = String(localized: "Not connected. Open Settings to connect.") }

    func clearDialError() { dialError = nil }

    func reportDialError(_ text: String) { dialError = text }

    func setMuted(_ muted: Bool) {
        guard let uuid = book.active.first(where: \.isAnswered)?.id else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) { [weak self] error in
            if let error { Task { @MainActor in self?.log("mute failed: \(error.localizedDescription)") } }
        }
    }

    /// Answers a ringing call from our own screen.
    func answer(_ uuid: UUID) {
        controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { [weak self] error in
            if let error { Task { @MainActor in self?.log("answer failed: \(error.localizedDescription)") } }
        }
    }

    /// Ends a call from our own screen through the system, so CallKit and the host stay in step.
    func end(_ uuid: UUID) {
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
            if let error { Task { @MainActor in self?.log("end call failed: \(error.localizedDescription)") } }
        }
    }

    func handle(_ message: ServerMessage) {
        switch message {
        case .ring(let callId, let number, let name):
            ring(callId: callId, number: number, name: name)
            send(.ringAck(callId: callId)) // the phone in the pocket may stop ringing now
        case .ended(let callId, let reason):
            // reportCall(endedAt:) does not call back into CXEndCallAction, so nothing is sent to the host.
            guard let uuid = book.uuid(forCallId: callId) else { return }
            finish(uuid, by: .host(reason))
            audio.sessionEnded()
            resetCallSettings()
            provider.reportCall(with: uuid, endedAt: Date(), reason: CallBook.callKitReason(for: reason))
        case .dialResult(let clientId, let ok, let callId, let error):
            dialResult(clientId: clientId, ok: ok, callId: callId, error: error)
        case .answered(let callId):
            // Incoming calls are answered by us; only an outgoing call needs to be told that the far end picked up.
            guard let uuid = book.uuid(forCallId: callId), book.isOutgoing(uuid) else { return }
            book.markAnswered(uuid)
            provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        default:
            break
        }
    }

    private func dialResult(clientId: String, ok: Bool, callId: String?, error: String?) {
        guard let uuid = UUID(uuidString: clientId) else { return }
        if ok, let callId {
            if book.attach(callId: callId, to: uuid) {
                // The user hung up while the host was still placing the call.
                send(.hangup(callId: callId))
                book.end(uuid: uuid)
                audio.sessionEnded()
            } else {
                provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
            }
            return
        }
        if !book.isEndRequested(uuid) { finish(uuid, by: .dialRefused) } else { book.end(uuid: uuid) } // already logged when the user hung up
        audio.sessionEnded()
        resetCallSettings()
        dialError = Self.message(forDialError: error)
        provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
    }

    /// Only what the bridge can do: no hold, no tones, no conference. A control the system shows for a call that cannot
    /// do it leads to an action nobody handles.
    private static func callUpdate(handle: CXHandle, title: String) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = handle
        update.localizedCallerName = title
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        return update
    }

    /// Writes the call to the history (once) and forgets it.
    private func finish(_ uuid: UUID, by ender: CallRecord.Ender) {
        logFinished(uuid, by: ender)
        let shown = book.active.first { $0.id == uuid }
        book.end(uuid: uuid)
        guard var shown else { return }
        shown.isEnded = true
        ended = shown
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            if self.ended?.id == shown.id { self.ended = nil }
        }
    }

    private func logFinished(_ uuid: UUID, by ender: CallRecord.Ender) {
        guard let detail = book.detail(for: uuid) else { return }
        onFinished(CallRecord.make(detail, endedBy: ender))
    }

    private func resetCallSettings() {
        speaker = false
        muted = false
        audio.muted = false
    }

    nonisolated static func message(forDialError code: String?) -> String {
        switch code {
        case "invalid": return String(localized: "That is not a valid phone number.")
        case "emergency": return String(localized: "Emergency numbers cannot be dialed through CellBridge. Use the phone itself.")
        case "busy": return String(localized: "Another outgoing call is already in progress.")
        default: return String(localized: "The phone could not start the call.")
        }
    }

    private func ring(callId: String, number: String?, name: String?) {
        let title = name ?? number.flatMap(nameFor) ?? number ?? String(localized: "Unknown caller")
        guard let uuid = book.ring(callId: callId, title: title, number: number ?? "") else { return }
        let update = Self.callUpdate(handle: number.map { CXHandle(type: .phoneNumber, value: $0) } ?? CXHandle(type: .generic, value: "unknown"), title: title)
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.log("callkit refused the call: \(error.localizedDescription)")
                _ = self?.book.end(callId: callId)
                self?.send(.reject(callId: callId)) // do not leave it ringing on the phone
            }
        }
    }

    // MARK: CXProviderDelegate

    nonisolated func providerDidReset(_ provider: CXProvider) {}

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            if let callId = self.book.callId(for: action.callUUID) {
                self.book.markAnswered(action.callUUID)
                // The UDP port goes into the answer so the host can stream to us the moment the call is active.
                let port = self.hostOffersAudio() ? self.audio.prepare(host: self.host()) : nil
                self.send(.answer(callId: callId, udpPort: port.map(Int.init)))
            }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            let uuid = action.callUUID
            let number = action.handle.value
            let title = self.nameFor(number) ?? number
            self.book.startOutgoing(uuid, title: title, number: number)
            // The UDP port goes into the dial so the host can stream to us the moment the far end answers.
            let port = self.hostOffersAudio() ? self.audio.prepare(host: self.host()) : nil
            self.send(.dial(clientId: uuid.uuidString, number: number, udpPort: port.map(Int.init)))
            action.fulfill()
            self.provider.reportCall(with: uuid, updated: Self.callUpdate(handle: action.handle, title: title))
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            let uuid = action.callUUID
            if let callId = self.book.callId(for: uuid) {
                // Only an incoming call that is still ringing is declined; anything we placed or answered is hung up.
                let hangUp = self.book.isOutgoing(uuid) || self.book.isAnswered(uuid)
                self.send(hangUp ? .hangup(callId: callId) : .reject(callId: callId))
                self.finish(uuid, by: .local)
                self.audio.sessionEnded()
                self.resetCallSettings()
            } else if self.book.isOutgoing(uuid) {
                self.logFinished(uuid, by: .local)
                self.book.requestEnd(uuid) // the host has not told us the call id yet; dial_result completes the hang-up
            }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            self.audio.muted = action.isMuted
            self.muted = action.isMuted
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in self.audio.start() }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in self.audio.sessionEnded() }
    }
}
