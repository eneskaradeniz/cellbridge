import SwiftUI

@main
struct CellBridgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView().tabItem { Label("Connection", systemImage: "antenna.radiowaves.left.and.right") }
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
            if !model.activeCalls.isEmpty {
                Section("Calls") {
                    ForEach(model.activeCalls) { call in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(call.title).font(.headline)
                                if let answeredAt = call.answeredAt {
                                    Text(answeredAt, style: .timer).font(.subheadline).monospacedDigit()
                                } else {
                                    Text("Ringing…").font(.subheadline)
                                }
                            }
                            Spacer()
                            if call.isAnswered {
                                Button { model.toggleSpeaker() } label: {
                                    Image(systemName: model.speakerOn ? "speaker.wave.3.fill" : "speaker.fill")
                                }
                                .buttonStyle(.bordered)
                            }
                            Button(call.isAnswered ? "End" : "Decline", role: .destructive) { model.endCall(call.id) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
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
