import SwiftUI

@main
struct CellBridgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView().tabItem { Label("Connection", systemImage: "antenna.radiowaves.left.and.right") }
                CallsView().tabItem { Label("Calls", systemImage: "phone") }
                MessagesView().tabItem { Label("Messages", systemImage: "message") }
            }
            .environmentObject(model)
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
