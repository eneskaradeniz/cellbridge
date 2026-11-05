import SwiftUI

enum AppTab: Int, Hashable {
    case recents, contacts, keypad, messages, settings
}

@main
struct CellBridgeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView(selection: $model.tab) {
                Tab("Recents", systemImage: "clock", value: AppTab.recents) { RecentsView() }.badge(model.missedUnseen)
                Tab("Contacts", systemImage: "person.crop.circle", value: AppTab.contacts) { ContactsView() }
                Tab("Keypad", systemImage: "circle.grid.3x3.fill", value: AppTab.keypad) { KeypadView() }
                Tab("Messages", systemImage: "message", value: AppTab.messages) { MessagesView() }.badge(model.messages.unreadCount)
                Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory(isEnabled: showsAccessory) {
                if let call = model.callsOnPhone.first {
                    PhoneCallBar(name: model.displayName(for: call.number ?? "", fallback: String(localized: "Unknown caller")),
                                 since: call.connectedAt) { model.takeOver(call) }
                } else {
                    ConnectionBanner(status: status) { model.tab = .settings }
                }
            }
            .animation(.smooth, value: status)
            .sensoryFeedback(.success, trigger: isConnected) { _, connected in connected }
            .fullScreenCover(isPresented: Binding(get: { model.callScreen != nil }, set: { _ in })) {
                InCallView().environmentObject(model)
            }
            .alert("Call Failed", isPresented: Binding(
                get: { model.dialError != nil },
                set: { if !$0 { model.clearDialError() } })) {
            } message: {
                Text(model.dialError ?? "")
            }
            .onOpenURL { handle($0) }
            .environmentObject(model)
            .environmentObject(model.permissions)
            .sheet(isPresented: $model.showSetup, onDismiss: { model.setupDismissed = true }) {
                SetupView().environmentObject(model).environmentObject(model.permissions)
            }
            .task {
                await model.permissions.refresh()
                model.presentSetupIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                model.resumeIfNeeded()
                Task { await model.permissions.refresh() }
            }
            #if DEBUG
            .onAppear {
                if let start = Sample.startTab { model.tab = start }
                if let number = Sample.openNumber { model.openThread(number) }
            }
            .overlay { if let call = Sample.activeCall() { InCallScreen(call: call, muted: false, speakerOn: true, toggleMute: {}, toggleSpeaker: {}, end: {}, answer: {}) } }
            #endif
        }
    }

    /// `cellbridge://call?number=…` and `cellbridge://message?number=…`, for Shortcuts, Safari and the Home Screen.
    private func handle(_ url: URL) {
        if url.scheme == "cellbridge", url.host == "pair" { // the QR code scanned with the system Camera app
            _ = model.handleScan(url.absoluteString)
            return
        }
        guard url.scheme == "cellbridge",
              let number = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "number" })?.value
        else { return }
        switch url.host {
        case "call": model.dial(number)
        case "message": model.openThread(number)
        default: break
        }
    }

    private var status: LinkStatus { LinkStatus(model.client.state, unreachable: model.unreachable, paired: model.isPaired) }

    /// The link banner while the phone is out of reach, or the phone's running call with a way to take it over.
    private var showsAccessory: Bool {
        guard !model.threadOpen else { return false }
        return !model.callsOnPhone.isEmpty || (model.tab != .settings && !isConnected)
    }

    private var isConnected: Bool {
        if case .connected = model.client.state { return true }
        return false
    }
}
