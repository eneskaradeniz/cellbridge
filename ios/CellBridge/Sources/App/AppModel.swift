import ActivityKit
import AVFoundation
import Combine
import Contacts
import Foundation
import UIKit

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
    @Published var tab: AppTab = .recents
    /// The last time the phone and this app were brought in step (a connection, a call log or text history answer, a text).
    @Published private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: "lastSync") as? Date
    /// Still connecting after a while: the phone is probably not on this network.
    @Published private(set) var unreachable = false
    private var unreachableTimer: Task<Void, Never>?
    /// Set by `openThread`; Messages consumes it and pushes the conversation.
    @Published var threadRequest: ThreadRoute?
    /// Missed calls newer than this make the Recents badge; opening Recents moves it to now.
    @Published private(set) var missedSeen = UserDefaults.standard.object(forKey: "missedSeen") as? Date ?? Date()
    @Published private(set) var lastDialed = UserDefaults.standard.string(forKey: "lastDialed") ?? ""
    /// The running model, for App Intents (Shortcuts, Siri), which are created outside the view tree.
    static private(set) weak var current: AppModel?
    private let contactProvider = ContactStoreProvider()
    let permissions = PermissionCenter()
    private let push = PushRegistry()
    private let liveTokens = LiveActivityTokens()
    /// The first-run sheet (pairing and permissions) is on screen.
    @Published var showSetup = false
    /// Why the last pull to refresh had nothing to refresh from; cleared once the phone is reached.
    @Published private(set) var refreshProblem: String?
    /// The calls the phone reports (docs/protocol.md `call_state`); empty while not connected.
    @Published private(set) var phoneCalls: [PhoneCall] = []

    let client = ControlClient()
    private(set) var messages: MessageCoordinator!
    private let notifier = Notifier()
    let gateway = GatewayDiscovery()
    let bonjour = BonjourDiscovery()
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
        let storedToken = TokenStore.load()
        token = storedToken
        tab = storedToken.isEmpty ? .settings : .recents // first run: nothing works until the phone is paired
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
            notify: { [weak self] id, from, body in
                guard let self else { return }
                notifier.notify(id: id, peer: from, kind: nil, title: displayName(for: from), body: body)
            },
            log: { [weak self] in self?.log($0) }
        )
        messages.alreadyAnnounced = { PushedTexts.contains($0) }
        messages.notifyBacklog = { [weak self] count, senders in
            guard let self else { return }
            var names: [String] = []
            for sender in senders { let name = displayName(for: sender); if !names.contains(name) { names.append(name) } }
            let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")
            notifier.notify(id: "backlog", peer: "", kind: "backlog", title: String(localized: "\(count) texts arrived while you were away"), body: shown)
        }
        client.onLog = { [weak self] in self?.log($0) }
        client.onMessage = { [weak self] message in
            self?.log(Self.describe(message))
            self?.calls.handle(message)
            self?.messages.handle(message)
            self?.handleHistory(message)
            self?.handleHostStatus(message)
        }
        // Sends that never got an answer cannot be confirmed once the connection is gone.
        client.$state.removeDuplicates().sink { [weak self] state in
            if case .connected = state { return }
            self?.messages.connectionLost()
        }.store(in: &bag)
        client.$state.removeDuplicates().sink { [weak self] state in
            self?.linkStateChanged(state)
        }.store(in: &bag)
        client.$state.removeDuplicates().sink { [weak self] state in
            guard let self else { return }
            unreachableTimer?.cancel()
            unreachable = false
            if case .connected = state { refreshProblem = nil } else { phoneCalls = []; calls.updateHeld([]) }
            guard state == .connecting else { return }
            unreachableTimer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                if !Task.isCancelled { self?.unreachable = true }
            }
        }.store(in: &bag)
        bonjour.onLog = { [weak self] in self?.log($0) }
        client.onReached = { [weak self] reached in
            guard let self else { return }
            lastGoodHost = reached
            // The phone announced itself, so a typed address is not needed here; one left over from another network only costs timeouts.
            let typed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            if bonjour.address == reached, !typed.isEmpty, typed != reached {
                log("cleared the typed address \(typed): the phone is found by itself")
                host = ""
            }
        }
        // A new gateway means the host is somewhere else now (hotspot toggled, Wi-Fi changed): do not wait for a timeout.
        bonjour.$address.removeDuplicates().sink { [weak self] address in
            guard let self else { return }
            log(address.map { "found the phone at \($0)" } ?? "the phone is no longer announcing itself")
            guard wantsConnection else { return }
            client.restart()
        }.store(in: &bag)
        gateway.$address.removeDuplicates().dropFirst().sink { [weak self] _ in
            guard let self, wantsConnection else { return }
            log("network changed, reconnecting")
            client.restart()
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: .CNContactStoreDidChange).sink { [weak self] _ in
            self?.refreshContacts()
        }.store(in: &bag)
        permissions.onContactsChanged = { [weak self] in self?.refreshContacts() }
        push.onCall = { [weak self] call, done in
            guard let self else { return done() }
            calls.reportPushed(call, completion: done)
            resumeIfNeeded() // the app may have been started by this push: bring the link up so the call can be answered
        }
        push.onToken = { [weak self] in
            if case .connected(let capabilities) = self?.client.state { self?.sendPushToken(offered: capabilities) }
        }
        AppDelegate.onAlertToken = { [weak self] in self?.push.onToken?() }
        liveTokens.send = { [weak self] in self?.client.send($0) }
        liveTokens.log = { [weak self] in self?.log($0) }
        liveTokens.wake = { [weak self] in self?.resumeIfNeeded() }
        liveTokens.isConnected = { [weak self] in if case .connected = self?.client.state { return true } else { return false } }
        liveTokens.displayName = { [weak self] in self?.displayName(for: $0) ?? $0 }
        liveTokens.start()
        push.start() // at launch, always: iOS only delivers a push to a closed app that registers again as it starts
        permissions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        refreshContacts()
        Self.current = self
        bonjour.preferredId = pairedDeviceId
        notifier.onOpen = { [weak self] in self?.openThread($0, focusesComposer: false) }
        messages.$conversations.sink { [weak self] conversations in
            self?.notifier.setBadge(conversations.reduce(0) { $0 + $1.unreadCount })
        }.store(in: &bag)
        #if DEBUG
        if sampling {
            contactsAuthorized = true
            contactBook = ContactBook(contacts: Sample.contacts)
            lastSync = Date().addingTimeInterval(-300)
        }
        #endif
        messages.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        // Forward state changes of the nested object so the main screen refreshes.
        client.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        calls.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        gateway.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        bonjour.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    }

    /// The banner's "Retry": look for the phone from scratch and dial again at once.
    func retryConnection() {
        log("retrying: looking for the phone again")
        bonjour.start()
        client.restart()
    }

    // MARK: pairing notice

    private var linkDownTimer: Task<Void, Never>?

    /// Calls ring through a push and texts catch up when the link returns, so a link that is merely down is not worth a notification
    /// (iOS suspends the app all the time; the banner in the app says it). The one thing that does need the user: the phone refuses
    /// the pairing code. Tell them once, at most every 10 minutes; any other state takes the notice away.
    private func linkStateChanged(_ state: ControlClient.State) {
        linkDownTimer?.cancel()
        guard case .rejected = state, wantsConnection else { return notifier.clearLinkDown() }
        linkDownTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled else { return }
            let last = UserDefaults.standard.object(forKey: "linkDownNoticeAt") as? Date ?? .distantPast
            guard Date().timeIntervalSince(last) > 600 else { return }
            UserDefaults.standard.set(Date(), forKey: "linkDownNoticeAt")
            notifier.linkDown(title: String(localized: "No connection to the phone"),
                              body: String(localized: "The phone did not accept the pairing code. Scan its QR code again."))
        }
    }

    /// The addresses to try, best first: the phone announcing itself, the Wi-Fi gateway (its hotspot), a typed address
    /// (for networks where neither works), the last address that answered. A stale one costs one failed attempt, not a stuck app.
    var candidateHosts: [String] {
        let typed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return [bonjour.address, gateway.address, typed, lastGoodHost]
            .compactMap { $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// What will actually be dialed: the host we are connected to, else the best candidate.
    var effectiveHost: String { client.connectedHost ?? candidateHosts.first ?? "" }

    /// Found without typing: the phone announcing itself on the network, else the Wi-Fi gateway (its hotspot).
    var detectedAddress: String? { bonjour.address ?? gateway.address }

    private var lastGoodHost: String? {
        get { UserDefaults.standard.string(forKey: "lastGoodHost") }
        set { UserDefaults.standard.set(newValue, forKey: "lastGoodHost") }
    }

    /// The phone's installation id from the QR code: when several phones announce themselves, this one is meant.
    private(set) var pairedDeviceId: String? = UserDefaults.standard.string(forKey: "pairedDeviceId")

    /// Takes what a QR code on the phone's screen holds, and connects.
    func pair(with link: PairingLink) {
        token = link.code
        host = ""
        lastGoodHost = link.host // a hint for the first connection only: the QR address goes stale when the subnet changes
        pairedDeviceId = link.deviceId
        UserDefaults.standard.set(link.deviceId, forKey: "pairedDeviceId")
        bonjour.preferredId = link.deviceId
        disconnect()
        connect()
    }

    func forgetPairing() {
        disconnect()
        token = ""
        host = ""
        lastGoodHost = nil
        pairedDeviceId = nil
        UserDefaults.standard.removeObject(forKey: "pairedDeviceId")
        bonjour.preferredId = nil
    }

    var hostLooksValid: Bool { HostAddress.isValid(host) }

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
            await permissions.refresh()
        }
    }

    func refreshContacts() {
        #if DEBUG
        if Sample.enabled { return }
        #endif
        contactsAuthorized = contactProvider.isAuthorized
        guard contactsAuthorized else { return }
        Task {
            contactBook = ContactBook(contacts: await contactProvider.load())
            liveTokens.refreshNames()
        }
    }

    /// A pairing code is stored: the QR code has been scanned (or the code typed).
    var isPaired: Bool { !cleanToken.isEmpty }

    /// Takes the text of a scanned QR code; false when it is not a CellBridge pairing code.
    @discardableResult
    func handleScan(_ text: String) -> Bool {
        guard let link = PairingLink.parse(text) else { return false }
        pair(with: link)
        return true
    }

    var setupDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: "setupDismissed") }
        set { UserDefaults.standard.set(newValue, forKey: "setupDismissed") }
    }

    /// Opens the setup sheet at launch while something is still unpaired or unasked, unless the user already sent it away.
    func presentSetupIfNeeded() {
        #if DEBUG
        if Sample.enabled { return }
        #endif
        guard !setupDismissed, !isPaired || !permissions.pending.isEmpty else { return }
        showSetup = true
    }

    var canConnect: Bool { !effectiveHost.isEmpty && hostLooksValid && !cleanToken.isEmpty }

    /// What was typed or pasted, without stray spaces or line breaks.
    private var cleanToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

    /// Why Connect is not available yet, in words; nil when it is.
    var connectHint: String? {
        if !hostLooksValid { return String(localized: "That does not look like an address. Use numbers like 192.168.43.1.") }
        if effectiveHost.isEmpty { return String(localized: "Enter the phone's address.") }
        if cleanToken.isEmpty { return String(localized: "Scan the QR code shown on the phone.") }
        return nil
    }

    /// True while the user wants to be connected: survives restarts, so the app reconnects on its own when reopened.
    private var wantsConnection: Bool {
        get { UserDefaults.standard.bool(forKey: "wantsConnection") }
        set { UserDefaults.standard.set(newValue, forKey: "wantsConnection") }
    }

    /// Called when the app comes to the front: iOS may have suspended it and left the socket dead.
    func resumeIfNeeded() {
        guard wantsConnection, canConnect else { return }
        if case .connected(let capabilities) = client.state {
            if capabilities.contains("calllog") { requestCallLog() } // calls the phone logged while the socket was quietly dead
            return
        }
        client.restart()
        if client.state == .idle { connect() } // the app was relaunched and nothing is running yet
    }

    func connect() {
        wantsConnection = true
        keepAlive.start()
        client.connect(host: { [weak self] in self?.candidateHosts ?? [] }, token: cleanToken)
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

    var missedUnseen: Int { recents.filter { $0.isMissed && $0.date > missedSeen }.count }

    func markRecentsSeen() {
        missedSeen = Date()
        UserDefaults.standard.set(missedSeen, forKey: "missedSeen")
    }

    var activeCalls: [ActiveCall] { calls.active }

    /// The host can hand a running call back to the phone itself.
    var canTransfer: Bool {
        if case .connected(let capabilities) = client.state { return capabilities.contains("transfer") }
        return false
    }

    func transferToPhone(_ id: UUID) { calls.transferToHost(id) }

    /// The host can put calls on hold.
    var canHold: Bool {
        if case .connected(let capabilities) = client.state { return capabilities.contains("hold") }
        return false
    }

    func isHeld(_ id: UUID) -> Bool { calls.isHeld(id) }

    func toggleHold(_ id: UUID) { calls.setHold(id, on: !calls.isHeld(id)) }

    func sendDigits(_ digits: String, call id: UUID) { calls.sendDigits(digits, for: id) }

    /// What the call screen shows: the running call, else the one that just ended.
    /// A second incoming call while one is running.
    var waitingCall: ActiveCall? {
        calls.active.dropFirst().first { !$0.isOutgoing && !$0.isAnswered }
    }

    var callScreen: ActiveCall? { calls.active.first ?? calls.ended }

    func endCall(_ id: UUID) { calls.end(id) }

    var speakerOn: Bool { calls.speaker }

    var muted: Bool { calls.muted }

    func toggleMute() { calls.setMuted(!calls.muted) }

    func answerCall(_ id: UUID) { calls.answer(id) }

    // MARK: the phone's own state

    /// The phone's battery and signal, as of the last message; kept after a disconnect so the last known state stays visible.
    @Published private(set) var hostInfo: HostInfo?

    private func handleHostStatus(_ message: ServerMessage) {
        guard case .hostStatus(let info) = message else { return }
        hostInfo = info
        let outcome = BatteryAlert.evaluate(level: info.battery, charging: info.charging, warned: UserDefaults.standard.bool(forKey: "batteryWarned"))
        UserDefaults.standard.set(outcome.warned, forKey: "batteryWarned")
        if outcome.warn, let level = info.battery {
            notifier.notify(id: "battery", peer: "", kind: "battery", title: String(localized: "The phone's battery is low"),
                            body: String(localized: "The phone is at \(level)%. Plug it in, or calls and texts stop reaching this iPhone."))
        }
    }

    // MARK: history from the phone (docs/protocol.md)

    private static let historyDays = 90.0
    private var callLogCursor: Int? {
        get { UserDefaults.standard.object(forKey: "callLogCursor") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "callLogCursor") }
    }

    /// "Updated 17:12" for the top of the lists; empty until the first sync.
    var syncSubtitle: String {
        guard let lastSync else { return "" }
        return String(localized: "Updated \(MessageDisplay.timestamp(lastSync))")
    }

    /// Pull to refresh: reconnects if needed, asks the phone for what the call log has that this app does not, and waits
    /// (a few seconds at most) for the answer so the spinner means something.
    func refreshHistory() async {
        let before = lastSync
        if case .connected = client.state {} else {
            guard canConnect else {
                refreshProblem = String(localized: "Not paired with a phone yet. Scan its QR code in Settings.")
                return
            }
            if wantsConnection { client.restart() } else { connect() }
            for _ in 0..<30 {
                if case .connected = client.state { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard case .connected(let capabilities) = client.state else {
            refreshProblem = String(localized: "Could not reach the phone. Join its hotspot or check the address.")
            return
        }
        refreshProblem = nil
        if capabilities.contains("calllog") { requestCallLog() }
        for _ in 0..<50 where lastSync == before { try? await Task.sleep(for: .milliseconds(100)) }
    }

    private func markSynced() {
        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: "lastSync")
    }

    private func handleHistory(_ message: ServerMessage) {
        switch message {
        case .sms:
            markSynced()
        case .helloAck(_, let capabilities):
            markSynced()
            sendPushToken(offered: capabilities)
            if capabilities.contains("live") { liveTokens.resend() }
            if capabilities.contains("transfer") { client.send(.callStateRequest) }
            messages.resendPending()
            if capabilities.contains("calllog") { requestCallLog() }
            if capabilities.contains("smshistory"), !UserDefaults.standard.bool(forKey: "smsHistoryDone") {
                let since = Int64((Date().timeIntervalSince1970 - Self.historyDays * 86_400) * 1000)
                client.send(.smsHistoryRequest(since: since))
            }
        case .callState(let calls):
            phoneCalls = calls
            self.calls.updateHeld(Set(calls.filter { $0.status == .holding && $0.onClient }.map(\.callId)))
            liveTokens.endStale(liveCallIds: Set(calls.filter { ($0.status == .active || $0.status == .holding) && !$0.onClient }.map(\.callId)))
            runPendingTakeOver()
        case .callLog(let entries):
            let added = (try? callLog.merge(host: entries)) ?? 0
            if let newest = entries.compactMap({ Int($0.id) }).max() { callLogCursor = max(callLogCursor ?? 0, newest) } else if callLogCursor == nil { callLogCursor = 0 }
            recents = callLog.entries
            markSynced()
            log("call log: \(entries.count) from the phone, \(added) new")
        case .smsHistory(let items):
            let added = messages.mergeHistory(items)
            UserDefaults.standard.set(true, forKey: "smsHistoryDone")
            markSynced()
            log("text history: \(items.count) from the phone, \(added) new")
        default:
            break
        }
    }

    /// Calls that are running on the phone (answered or dialed in its Phone app, or handed to it) and that this iPhone could take over.
    var callsOnPhone: [PhoneCall] { PhoneCall.takeable(phoneCalls, knows: calls.knows(callId:)) }

    #if DEBUG
    func adoptLiveActivity(_ activity: Activity<CallActivityAttributes>) { liveTokens.adopt(activity) }
    #endif

    /// The Live Activity's button opened the app for this call. The app is only `inactive` for the first moments of a launch, and a call taken
    /// over then is reported as an incoming one that must be answered; so it waits until the app is in front, and until the phone's calls are known.
    func takeOver(callId: String) {
        pendingTakeOver = callId
        resumeIfNeeded()
        runPendingTakeOver()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if self?.pendingTakeOver == callId { self?.pendingTakeOver = nil } // the call is gone or the phone is out of reach
        }
    }

    /// Takes over the call the Live Activity asked for, as soon as the app is in front and the call is known.
    func runPendingTakeOver() {
        guard let id = pendingTakeOver, UIApplication.shared.applicationState == .active,
              let call = callsOnPhone.first(where: { $0.callId == id }) else { return }
        pendingTakeOver = nil
        takeOver(call)
    }

    private var pendingTakeOver: String?

    /// "Take over": the phone offers the call back (`transfer_offer`), which the call coordinator answers like any hand-over.
    func takeOver(_ call: PhoneCall) {
        log("asking the phone for its call")
        client.send(.transferRequest(callId: call.callId))
    }

    /// Tells the phone how to wake this app for a call, when it holds an APNs key (`push`) and Apple has given us a token.
    private func sendPushToken(offered capabilities: [String]) {
        guard capabilities.contains("push"), let message = push.message else { return }
        client.send(message)
        log("push token sent to the phone")
    }

    /// Asks for calls the phone logged that this app has not seen: all of the last 90 days the first time, then newer ones.
    private func requestCallLog() {
        let since = callLogCursor == nil ? Int64((Date().timeIntervalSince1970 - Self.historyDays * 86_400) * 1000) : nil
        client.send(.callLogRequest(after: callLogCursor.map(String.init), since: since))
    }

    private func record(_ record: CallRecord) {
        do {
            try callLog.record(record)
            recents = callLog.entries
            // The phone logs the call a moment later: fetch it so this record gets the phone's id.
            if case .connected(let capabilities) = client.state, capabilities.contains("calllog") {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.requestCallLog()
                }
            }
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

    func dial(_ number: String) {
        guard canDial else { return calls.reportNotConnected() }
        lastDialed = number
        UserDefaults.standard.set(number, forKey: "lastDialed")
        calls.dial(number)
    }

    func clearDialError() { calls.clearDialError() }

    /// Shortcuts and Siri hand over what the person said: a number, or part of a contact's name.
    func dial(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.filter(\.isNumber).count >= 3 { return dial(trimmed) }
        if let number = contactBook.search(trimmed).first?.numbers.first?.value { return dial(number) }
        calls.reportDialError(String(localized: "No contact named \(trimmed) was found."))
    }

    /// Shows the conversation with `number` in the Messages tab, with the keyboard up.
    func openThread(_ number: String, focusesComposer: Bool = true) {
        threadRequest = ThreadRoute(key: MessageStore.key(for: number), peer: number, focusesComposer: focusesComposer)
        tab = .messages
    }

    func deleteRecents(_ ids: Set<UUID>) {
        do {
            try callLog.remove(ids: ids)
            recents = callLog.entries
        } catch {
            log("could not delete from the history: \(error.localizedDescription)")
        }
    }

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
        case .tone(let command): return "tone \(command)"
        case .callList(let callIds): return "live calls on the phone: \(callIds.count)"
        case .capabilities(let capabilities): return "host now offers \(capabilities.joined(separator: ", "))"
        case .ring(let callId, _, _): return "ring \(callId.prefix(8))"
        case .ended(let callId, let reason): return "ended \(callId.prefix(8)) \(reason?.rawValue ?? "")"
        case .dialResult(let clientId, let ok, _, let error): return "dial \(clientId.prefix(8)) \(ok ? "placed" : "refused: \(error ?? "?")")"
        case .answered(let callId): return "answered \(callId.prefix(8))"
        case .sms(let id, _, _, _): return "sms \(id)" // never log the sender or the text
        case .smsResult(let clientId, let ok, _): return "sms result \(clientId.prefix(8)) \(ok ? "sent" : "failed")"
        case .hostStatus: return "phone status"
        case .smsStatus(let clientId, let delivered): return "sms status \(clientId.prefix(8)) \(delivered ? "delivered" : "not delivered")"
        case .transferResult(let callId, let ok): return "transfer to the phone \(callId.prefix(8)) \(ok ? "ok" : "refused")"
        case .transferOffer(let callId, _, _): return "transfer offer \(callId.prefix(8))"
        case .callState(let calls): return "phone calls \(calls.count)"
        case .callLog(let entries): return "call log \(entries.count)"
        case .smsHistory(let items): return "text history \(items.count)"
        case .error(let code, _): return "error \(code)"
        }
    }
}
