import AVFoundation
import UIKit
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

    /// Plays the sounds the phone makes itself during a call: ringback, busy, the beep at the end.
    private let tones = ToneRenderer()

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
        tones.callIsActive = { [weak self] in !(self?.book.active.isEmpty ?? true) }
        tones.log = { [weak self] in self?.log($0) }
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

    /// The iPhone already shows this host call (ringing, dialed from here, or being taken over right now).
    func knows(callId: String) -> Bool {
        book.uuid(forCallId: callId) != nil || adopting.values.contains { $0.callId == callId }
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
        guard let uuid = book.active.first(where: { $0.isAnswered || $0.isOutgoing })?.id else { return }
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

    /// Calls the phone handed over (transfer to the iPhone): CallKit starts them without dialing, under the phone's call id.
    private var adopting: [UUID: (callId: String, number: String?, since: Date?)] = [:]
    /// Taken over while the app was in the background: CallKit refuses every call request an app makes then (start and answer
    /// fail with InvalidAction), so the call is reported as an incoming one and the user taps Accept on the lock screen.
    /// The value is the time the call had already been running.
    private var adoptedIncoming: [UUID: Date?] = [:]
    private var transferringToHost = Set<UUID>()

    /// Keypad tones for a running call (menus of banks and call centres): one digit at a time, spaced so the host can play each.
    func sendDigits(_ digits: String, for uuid: UUID) {
        guard let callId = book.callId(for: uuid), book.isAnswered(uuid) || book.isOutgoing(uuid) else { return }
        let valid = digits.filter { "0123456789*#".contains($0) }
        guard !valid.isEmpty else { return }
        Task { @MainActor in
            for digit in valid {
                send(.dtmf(callId: callId, digit: String(digit)))
                try? await Task.sleep(for: .milliseconds(220))
            }
        }
    }

    /// Moves the call to the phone itself: the host stops the relay, the call goes on there, and ours ends without a hang-up.
    func transferToHost(_ uuid: UUID) {
        guard let callId = book.callId(for: uuid), book.isAnswered(uuid) else { return }
        transferringToHost.insert(uuid)
        send(.transferToHost(callId: callId))
    }

    private func transferResult(callId: String, ok: Bool) {
        // Also arrives unasked, when the phone's user took the call back: then there is nothing to report if it failed.
        guard let uuid = book.uuid(forCallId: callId) else { return }
        let asked = transferringToHost.remove(uuid) != nil
        guard ok else {
            if asked { dialError = String(localized: "The call could not be moved to the phone.") }
            return
        }
        book.end(uuid: uuid) // not logged: the phone's call log has this call
        audio.sessionEnded()
        resetCallSettings()
        provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded) // does not call back into CXEndCallAction: no hang-up
    }

    /// The phone's user pressed "transfer to iPhone": put the running call on this screen.
    private func adopt(callId: String, number: String?, since: Date?) {
        guard book.uuid(forCallId: callId) == nil, !adopting.values.contains(where: { $0.callId == callId }) else { return }
        let handle = number.map { CXHandle(type: .phoneNumber, value: $0) } ?? CXHandle(type: .generic, value: "unknown")
        let state = UIApplication.shared.applicationState
        log("transfer offer: app is \(state == .active ? "in front" : state == .inactive ? "inactive" : "in the background")")
        if state != .active {
            adoptInBackground(callId: callId, number: number, since: since, handle: handle)
            return
        }
        let uuid = UUID()
        adopting[uuid] = (callId, number, since)
        controller.request(CXTransaction(action: CXStartCallAction(call: uuid, handle: handle))) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self else { return }
                self.adopting[uuid] = nil
                let known = self.controller.callObserver.calls.map { "\($0.uuid.uuidString.prefix(4)) out=\($0.isOutgoing) on=\($0.isOnHold) done=\($0.hasConnected) ended=\($0.hasEnded)" }
                self.log("could not take the call over: code \((error as NSError).code) \(error.localizedDescription); calls known to the system: \(known)")
            }
        }
    }

    private func adoptInBackground(callId: String, number: String?, since: Date?, handle: CXHandle) {
        let title = number.flatMap(nameFor) ?? number ?? String(localized: "Unknown caller")
        guard let uuid = book.ring(callId: callId, title: title, number: number ?? "") else { return }
        adoptedIncoming[uuid] = since
        provider.reportNewIncomingCall(with: uuid, update: Self.callUpdate(handle: handle, title: title)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.adoptedIncoming[uuid] = nil
                    self.book.end(uuid: uuid)
                    self.log("could not take the call over in the background: \(error.localizedDescription)")
                }
            }
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
            book.hostConfirmed(callId: callId)
            ring(callId: callId, number: number, name: name)
            send(.ringAck(callId: callId)) // the phone in the pocket may stop ringing now
        case .tone(let command):
            tones.handle(command)
        case .callList(let live):
            book.hostConfirmed()
            // An `ended` sent while the socket was down never arrived: end what the host no longer has.
            for callId in book.vanished(from: live) { handle(.ended(callId: callId, reason: nil)) }
        case .ended(let callId, let reason):
            book.hostConfirmed(callId: callId)
            // reportCall(endedAt:) does not call back into CXEndCallAction, so nothing is sent to the host.
            guard let uuid = book.uuid(forCallId: callId) else { return }
            finish(uuid, by: .host(reason))
            audio.sessionEnded()
            resetCallSettings()
            provider.reportCall(with: uuid, endedAt: Date(), reason: CallBook.callKitReason(for: reason))
        case .dialResult(let clientId, let ok, let callId, let error):
            dialResult(clientId: clientId, ok: ok, callId: callId, error: error)
        case .transferResult(let callId, let ok):
            transferResult(callId: callId, ok: ok)
        case .transferOffer(let callId, let number, let connectedAt):
            adopt(callId: callId, number: number, since: connectedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        case .answered(let callId):
            // Answered on the phone itself while ours was still ringing: stop ringing, like iOS does for a call taken on another device.
            if let uuid = book.uuid(forCallId: callId), !book.isOutgoing(uuid), !book.isAnswered(uuid) {
                book.end(uuid: uuid) // not logged: the phone's call log has the call
                resetCallSettings()
                provider.reportCall(with: uuid, endedAt: Date(), reason: .answeredElsewhere)
                return
            }
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
        update.supportsDTMF = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        return update
    }

    /// Writes the call to the history (once) and forgets it.
    private func finish(_ uuid: UUID, by ender: CallRecord.Ender) {
        tones.stopLoop() // a ringback or busy tone does not outlive its call (the end-of-call beep is not a loop)
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

    /// How long a pushed call may ring without the host confirming it over the connection.
    var pushConfirmTimeout: Duration = .seconds(30)

    /// The push woke the app, but the iPhone may never reach the phone (another network, the hotspot off): then nothing would ever end
    /// the call, and an answered one would sit on "connecting". When the wait is over and the host has still said nothing, end it.
    private func watchPushedCall(callId: String) {
        book.pushed(callId: callId)
        Task { @MainActor [weak self, timeout = pushConfirmTimeout] in
            try? await Task.sleep(for: timeout)
            guard let self, self.book.isStalePush(callId: callId), let uuid = self.book.uuid(forCallId: callId) else { return }
            self.log("push: the phone never confirmed the call, ending it")
            self.book.hostConfirmed(callId: callId)
            self.book.end(uuid: uuid) // not logged: the phone's call log has the call
            self.resetCallSettings()
            self.provider.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
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

    /// A VoIP push woke the app for a call. CallKit must hear about a call for every push, so even an unreadable push is shown and ended
    /// at once; the connection that follows tells whether the host still has the call ringing (`call_list` ends it if not).
    func reportPushed(_ pushed: PushSeal.Call?, completion: @escaping () -> Void) {
        guard let pushed else {
            log("push could not be read")
            let uuid = UUID()
            provider.reportNewIncomingCall(with: uuid, update: Self.callUpdate(handle: CXHandle(type: .generic, value: "unknown"), title: String(localized: "Unknown caller"))) { [weak self] _ in
                Task { @MainActor in
                    self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                    completion()
                }
            }
            return
        }
        let title = pushed.name ?? pushed.number.flatMap(nameFor) ?? pushed.number ?? String(localized: "Unknown caller")
        let registered = book.ring(callId: pushed.callId, title: title, number: pushed.number ?? "") != nil
        let uuid = CallBook.incomingUUID(forCallId: pushed.callId)
        let handle = pushed.number.map { CXHandle(type: .phoneNumber, value: $0) } ?? CXHandle(type: .generic, value: "unknown")
        log("push: call ringing (\(registered ? "new" : "already shown"))")
        if registered { watchPushedCall(callId: pushed.callId) }
        provider.reportNewIncomingCall(with: uuid, update: Self.callUpdate(handle: handle, title: title)) { [weak self] error in
            Task { @MainActor in
                if let error, registered {
                    self?.log("callkit refused the pushed call: \(error.localizedDescription)")
                    _ = self?.book.end(callId: pushed.callId)
                }
                completion()
            }
        }
    }

    // MARK: CXProviderDelegate

    nonisolated func providerDidReset(_ provider: CXProvider) {}

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            if let since = self.adoptedIncoming.removeValue(forKey: action.callUUID), let callId = self.book.callId(for: action.callUUID) {
                // A call already running on the phone: no answer to send, just take the audio and tell the host where to send it.
                self.book.markAnswered(action.callUUID, now: since ?? Date())
                let port = self.hostOffersAudio() ? self.audio.prepare(host: self.host()) : nil
                self.send(.transferAccept(callId: callId, udpPort: port.map(Int.init)))
                action.fulfill()
                return
            }
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
            if let adopted = self.adopting.removeValue(forKey: uuid) {
                // A call that is already running on the phone: no dial, just take the audio and tell the host where to send it.
                self.book.startOutgoing(uuid, title: adopted.number.flatMap(self.nameFor) ?? adopted.number ?? String(localized: "Unknown caller"),
                                        number: adopted.number)
                _ = self.book.attach(callId: adopted.callId, to: uuid)
                self.book.markAnswered(uuid, now: adopted.since ?? Date())
                let port = self.hostOffersAudio() ? self.audio.prepare(host: self.host()) : nil
                self.send(.transferAccept(callId: adopted.callId, udpPort: port.map(Int.init)))
                action.fulfill()
                self.provider.reportCall(with: uuid, updated: Self.callUpdate(handle: action.handle, title: title))
                self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
                self.provider.reportOutgoingCall(with: uuid, connectedAt: adopted.since ?? Date())
                return
            }
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
            if self.adoptedIncoming.removeValue(forKey: uuid) != nil {
                // Declined the call handed over from the phone: it is running there, so only our side goes away.
                self.book.end(uuid: uuid)
                action.fulfill()
                return
            }
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

    nonisolated func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        Task { @MainActor in
            self.sendDigits(action.digits, for: action.callUUID)
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
