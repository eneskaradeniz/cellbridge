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
    private let send: (ClientMessage) -> Void
    private let log: (String) -> Void

    init(send: @escaping (ClientMessage) -> Void, log: @escaping (String) -> Void) {
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
            provider.reportCall(with: uuid, endedAt: Date(), reason: CallBook.callKitReason(for: reason))
        default:
            break
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
                self.send(.answer(callId: callId, udpPort: nil)) // audio arrives in M3b
            }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            if let callId = self.book.callId(for: action.callUUID) {
                self.send(self.book.isAnswered(action.callUUID) ? .hangup(callId: callId) : .reject(callId: callId))
                self.book.end(uuid: action.callUUID)
            }
            action.fulfill()
        }
    }
}
