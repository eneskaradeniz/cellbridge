import SwiftUI

@main
struct CellBridgeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                RecentsView().tabItem { Label("Recents", systemImage: "clock") }
                ContactsView().tabItem { Label("Contacts", systemImage: "person.crop.circle") }
                KeypadView().tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }
                MessagesView().tabItem { Label("Messages", systemImage: "message") }
                ContentView().tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .fullScreenCover(isPresented: Binding(get: { !model.activeCalls.isEmpty }, set: { _ in })) {
                InCallView().environmentObject(model)
            }
            .environmentObject(model)
            .onChange(of: scenePhase) { _, phase in if phase == .active { model.resumeIfNeeded() } }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Host") {
                TextField(model.gateway.address.map { "Detected: \($0)" } ?? "Host address", text: $model.host)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Pairing code (shown on the phone)", text: $model.token)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }
            Section("Connection") {
                Text(statusText)
                if model.client.state == .idle {
                    Button("Connect") { model.connect() }.disabled(!model.canConnect)
                } else {
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                }
            }
            Section("Audio") {
                Button(model.audioTestRunning ? "Testing… (about 10 s)" : "Audio test") { model.runAudioSelfTest() }
                    .disabled(model.audioTestRunning)
                Picker("Voice processing", selection: Binding(
                    get: { AudioBridge.storedVoiceProcessing.rawValue },
                    set: { UserDefaults.standard.set($0, forKey: "voiceProcessing") })) {
                    Text("Full (default)").tag("full")
                    Text("Full, no auto gain").tag("fullNoAGC")
                    Text("Bypassed").tag("bypassed")
                    Text("Off").tag("off")
                }
                Button(model.audioTestRunning ? "Testing… (about 18 s)" : "Mic test (speak steadily)") { model.runMicTest() }
                    .disabled(model.audioTestRunning)
                Toggle("Record the far end (debug)", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "recordAudio") },
                    set: { UserDefaults.standard.set($0, forKey: "recordAudio") }))
                Text("Plays a tone through the call's audio path in four ways and logs what the mixer renders. Turn the volume up; no call needed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Events") {
                Button("Copy all") { UIPasteboard.general.string = model.events.joined(separator: "\n") }
                    .disabled(model.events.isEmpty)
                Text(model.events.joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .dismissibleKeyboard()
    }

    private var statusText: String {
        switch model.client.state {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected(let capabilities): return "Connected (\(capabilities.joined(separator: ", ")))"
        case .rejected(let code): return "Host refused: \(code) — check the pairing code"
        }
    }
}
