import SwiftUI

enum AppTab: Int, Hashable {
    case recents, contacts, keypad, messages, settings
}

@main
struct CellBridgeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .recents

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                Tab("Recents", systemImage: "clock", value: AppTab.recents) { RecentsView() }
                Tab("Contacts", systemImage: "person.crop.circle", value: AppTab.contacts) { ContactsView() }
                Tab("Keypad", systemImage: "circle.grid.3x3.fill", value: AppTab.keypad) { KeypadView() }
                Tab("Messages", systemImage: "message", value: AppTab.messages) { MessagesView() }
                Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory(isEnabled: tab != .settings && !isConnected && !model.threadOpen) {
                ConnectionBanner(status: status) { tab = .settings }
            }
            .animation(.smooth, value: status)
            .sensoryFeedback(.success, trigger: isConnected) { _, connected in connected }
            .fullScreenCover(isPresented: Binding(get: { !model.activeCalls.isEmpty }, set: { _ in })) {
                InCallView().environmentObject(model)
            }
            .environmentObject(model)
            .onChange(of: scenePhase) { _, phase in if phase == .active { model.resumeIfNeeded() } }
            #if DEBUG
            .onAppear { if let start = Sample.startTab { tab = start } }
            .overlay { if let call = Sample.activeCall() { InCallScreen(call: call, muted: false, speakerOn: true, toggleMute: {}, toggleSpeaker: {}, end: {}, answer: {}) } }
            #endif
        }
    }

    private var status: LinkStatus { LinkStatus(model.client.state) }

    private var isConnected: Bool {
        if case .connected = model.client.state { return true }
        return false
    }
}
