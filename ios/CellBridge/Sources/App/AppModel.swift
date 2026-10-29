import AVFoundation
import Combine
import Contacts
import Foundation

/// Wires the pieces together and owns the settings the user edits on the main screen.
@MainActor
final class AppModel: ObservableObject {
    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "host") } }
    @Published var token: String { didSet { TokenStore.save(token) } }
    @Published private(set) var events: [String] = []
    @Published private(set) var recents: [CallRecord] = []
    @Published private(set) var audioTestRunning = false
    @Published private(set) var contactBook = ContactBook()
    @Published private(set) var contactsAuthorized = false
    /// A conversation is open and owns the bottom edge, so the link banner stays out of its way.
    @Published var threadOpen = false
    private let contactProvider = ContactStoreProvider()

    let client = ControlClient()
    private(set) var messages: MessageCoordinator!
    private let notifier = Notifier()
    let gateway = GatewayDiscovery()
    private var calls: CallCoordinator!
    private let callLog: CallLog
    private let eventLog: EventLog
    private var keepAlive: KeepAlive!
    private var bag = Set<AnyCancellable>()
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        host = UserDefaults.standard.string(forKey: "host") ?? ""
        token = TokenStore.load()
        var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        let sampling = Sample.enabled
        if sampling { support = FileManager.default.temporaryDirectory.appendingPathComponent("CellBridgeSample-\(UUID().uuidString)") }
        #endif
        callLog = CallLog(url: support.appendingPathComponent("CellBridge/calls.json"))
        #if DEBUG
        if sampling { Sample.seed(messages: MessageStore(url: support.appendingPathComponent("CellBridge/messages.json")), calls: callLog) }
        #endif
        recents = callLog.entries
        contactsAuthorized = contactProvider.isAuthorized
        eventLog = EventLog(url: support.appendingPathComponent("CellBridge/events.log"))
        events = eventLog.recent(40).reversed()
        keepAlive = KeepAlive(log: { [weak self] in self?.log($0) })
        let audio = AudioBridge(keepAlive: keepAlive, log: { [weak self] in self?.log($0) })
        calls = CallCoordinator(
            audio: audio,
            host: { [weak self] in self?.effectiveHost ?? "" },
            hostOffersAudio: { [weak self] in
                if case .connected(let capabilities) = self?.client.state { return capabilities.contains("audio") }
                return false
            },
            nameFor: { [weak self] in self?.contactBook.name(for: $0) },
            send: { [weak self] in self?.client.send($0) },
            onFinished: { [weak self] in self?.record($0) },
            log: { [weak self] in self?.log($0) }
        )
        messages = MessageCoordinator(
            store: MessageStore(url: support.appendingPathComponent("CellBridge/messages.json")),
            transmit: { [weak self] in self?.client.send($0) },
            notify: { [weak self] in self?.notifier.notify(id: $0, title: $1, body: $2) },
            log: { [weak self] in self?.log($0) }
        )
        client.onLog = { [weak self] in self?.log($0) }
        client.onMessage = { [weak self] message in
            self?.log(Self.describe(message))
            self?.calls.handle(message)
            self?.messages.handle(message)
        }
        // Sends that never got an answer cannot be confirmed once the connection is gone.
        client.$state.removeDuplicates().sink { [weak self] state in
            if case .connected = state { return }
            self?.messages.connectionLost()
        }.store(in: &bag)
        // A new gateway means the host is somewhere else now (hotspot toggled, Wi-Fi changed): do not wait for a timeout.
        gateway.$address.removeDuplicates().dropFirst().sink { [weak self] _ in
            guard let self, wantsConnection else { return }
            log("network changed, reconnecting")
            client.restart()
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: .CNContactStoreDidChange).sink { [weak self] _ in
            self?.refreshContacts()
        }.store(in: &bag)
        refreshContacts()
        #if DEBUG
        if sampling {
            contactsAuthorized = true
            contactBook = ContactBook(contacts: Sample.contacts)
        }
        #endif
        messages.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        // Forward state changes of the nested object so the main screen refreshes.
        client.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        calls.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        gateway.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    }

    /// What will actually be dialed: the typed host, else the detected gateway.
    var effectiveHost: String { host.isEmpty ? (gateway.address ?? "") : host }

    /// Texts can be sent while connected to a host that is the default SMS app.
    var canSendSms: Bool {
        if case .connected(let capabilities) = client.state { return capabilities.contains("sms") }
        return false
    }

    /// The contact's name for a number, else `fallback`, else the number itself.
    func displayName(for number: String, fallback: String = "") -> String {
        contactBook.name(for: number) ?? (fallback.isEmpty ? number : fallback)
    }

    /// False once the user said no: the system asks only once, after that it is a Settings switch.
    var canAskForContacts: Bool { contactProvider.status == .notDetermined }

    func requestContacts() {
        Task {
            _ = await contactProvider.requestAccess()
            refreshContacts()
        }
    }

    func refreshContacts() {
        #if DEBUG
        if Sample.enabled { return }
        #endif
        contactsAuthorized = contactProvider.isAuthorized
        guard contactsAuthorized else { return }
        Task { contactBook = ContactBook(contacts: await contactProvider.load()) }
    }

    var canConnect: Bool { !effectiveHost.isEmpty && !token.isEmpty }

    /// True while the user wants to be connected: survives restarts, so the app reconnects on its own when reopened.
    private var wantsConnection: Bool {
        get { UserDefaults.standard.bool(forKey: "wantsConnection") }
        set { UserDefaults.standard.set(newValue, forKey: "wantsConnection") }
    }

    /// Called when the app comes to the front: iOS may have suspended it and left the socket dead.
    func resumeIfNeeded() {
        guard wantsConnection, canConnect else { return }
        if case .connected = client.state { return }
        client.restart()
        if client.state == .idle { connect() } // the app was relaunched and nothing is running yet
    }

    func connect() {
        wantsConnection = true
        Task { _ = await AVAudioApplication.requestRecordPermission() } // ask now, not in the middle of a call
        notifier.requestPermission()
        if canAskForContacts { requestContacts() }
        keepAlive.start()
        client.connect(host: { [weak self] in self?.effectiveHost ?? "" }, token: token.uppercased())
    }

    /// Settings → Audio test: tries the call's audio graph in a few shapes and logs what the mixer renders.
    func runAudioSelfTest() {
        guard !audioTestRunning else { return }
        audioTestRunning = true
        keepAlive.stop() // its playback-only session would get in the way
        Task {
            await AudioSelfTest.run(log: { [weak self] in self?.log($0) })
            keepAlive.start()
            audioTestRunning = false
        }
    }

    /// Settings → Mic test: the call's microphone path with several voice-processing settings, 6 s each.
    func runMicTest() {
        guard !audioTestRunning else { return }
        audioTestRunning = true
        keepAlive.stop()
        Task {
            await AudioSelfTest.micTest(log: { [weak self] in self?.log($0) })
            keepAlive.start()
            audioTestRunning = false
        }
    }

    func disconnect() {
        wantsConnection = false
        client.disconnect()
    }

    var activeCalls: [ActiveCall] { calls.active }

    func endCall(_ id: UUID) { calls.end(id) }

    var speakerOn: Bool { calls.speaker }

    var muted: Bool { calls.muted }

    func toggleMute() { calls.setMuted(!calls.muted) }

    func answerCall(_ id: UUID) { calls.answer(id) }

    private func record(_ record: CallRecord) {
        do {
            try callLog.record(record)
            recents = callLog.entries
        } catch {
            log("could not save the call to the history: \(error.localizedDescription)")
        }
    }

    func clearRecents() {
        do {
            try callLog.clear()
            recents = []
        } catch {
            log("could not clear the history: \(error.localizedDescription)")
        }
    }

    var dialError: String? { calls.dialError }

    /// Calls can be placed while connected to the host.
    var canDial: Bool {
        if case .connected = client.state { return true }
        return false
    }

    func dial(_ number: String) { calls.dial(number) }

    func toggleSpeaker() { calls.speaker.toggle() }

    private func log(_ text: String) {
        events = Array(([stamp.string(from: Date()) + " " + text] + events).prefix(40))
        eventLog.append(Self.fileStamp.string(from: Date()) + " " + text)
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    private static func describe(_ message: ServerMessage) -> String {
        switch message {
        case .helloAck(_, let capabilities): return "connected, host offers \(capabilities.joined(separator: ", "))"
        case .ring(let callId, _, _): return "ring \(callId.prefix(8))"
        case .ended(let callId, let reason): return "ended \(callId.prefix(8)) \(reason?.rawValue ?? "")"
        case .dialResult(let clientId, let ok, _, let error): return "dial \(clientId.prefix(8)) \(ok ? "placed" : "refused: \(error ?? "?")")"
        case .answered(let callId): return "answered \(callId.prefix(8))"
        case .sms(let id, _, _, _): return "sms \(id)" // never log the sender or the text
        case .smsResult(let clientId, let ok, _): return "sms result \(clientId.prefix(8)) \(ok ? "sent" : "failed")"
        case .error(let code, _): return "error \(code)"
        }
    }
}
