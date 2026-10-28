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

    /// Loudspeaker on/off for the current call.
    @Published var speaker = false { didSet { audio.speaker = speaker } }
    private let audio: AudioBridge
    private let host: () -> String
    private let hostOffersAudio: () -> Bool
    private let send: (ClientMessage) -> Void
    private let log: (String) -> Void

    init(audio: AudioBridge, host: @escaping () -> String, hostOffersAudio: @escaping () -> Bool,
         send: @escaping (ClientMessage) -> Void, log: @escaping (String) -> Void) {
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
    }

    /// Starts an outgoing call through the system, so CallKit and the audio session are set up as for any other call.
    func dial(_ number: String) {
        dialError = nil
        let action = CXStartCallAction(call: UUID(), handle: CXHandle(type: .phoneNumber, value: number))
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.dialError = "Could not start the call: \(error.localizedDescription)" }
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
        case .ended(let callId, let reason):
            // reportCall(endedAt:) does not call back into CXEndCallAction, so nothing is sent to the host.
            guard let uuid = book.end(callId: callId) else { return }
            audio.sessionEnded()
            speaker = false
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
        book.end(uuid: uuid)
        audio.sessionEnded()
        speaker = false
        dialError = Self.message(forDialError: error)
        provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
    }

    nonisolated static func message(forDialError code: String?) -> String {
        switch code {
        case "invalid": return "That is not a valid phone number."
        case "emergency": return "Emergency numbers cannot be dialed through CellBridge. Use the phone itself."
        case "busy": return "Another outgoing call is already in progress."
        default: return "The phone could not start the call."
        }
    }

    private func ring(callId: String, number: String?, name: String?) {
        let title = name ?? number ?? "Unknown caller"
        guard let uuid = book.ring(callId: callId, title: title) else { return }
        let update = CXCallUpdate()
        update.remoteHandle = number.map { CXHandle(type: .phoneNumber, value: $0) } ?? CXHandle(type: .generic, value: "unknown")
        update.localizedCallerName = title
        update.hasVideo = false
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
            self.book.startOutgoing(uuid, title: number)
            // The UDP port goes into the dial so the host can stream to us the moment the far end answers.
            let port = self.hostOffersAudio() ? self.audio.prepare(host: self.host()) : nil
            self.send(.dial(clientId: uuid.uuidString, number: number, udpPort: port.map(Int.init)))
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            let uuid = action.callUUID
            if let callId = self.book.callId(for: uuid) {
                // Only an incoming call that is still ringing is declined; anything we placed or answered is hung up.
                let hangUp = self.book.isOutgoing(uuid) || self.book.isAnswered(uuid)
                self.send(hangUp ? .hangup(callId: callId) : .reject(callId: callId))
                self.book.end(uuid: uuid)
                self.audio.sessionEnded()
            } else if self.book.isOutgoing(uuid) {
                self.book.requestEnd(uuid) // the host has not told us the call id yet; dial_result completes the hang-up
            }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            self.audio.muted = action.isMuted
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
