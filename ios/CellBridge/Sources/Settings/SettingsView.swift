import SwiftUI

/// Where the phone is found and paired. The audio tools and the event log live one level down, under Developer.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    private var status: LinkStatus { LinkStatus(model.client.state, unreachable: model.unreachable) }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(status.color.gradient, in: .rect(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.title).font(.headline)
                            Text(status.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    switch model.client.state {
                    case .idle, .rejected:
                        Button(status == .refused ? "Try Again" : "Connect") { model.connect() }.disabled(!model.canConnect)
                    default:
                        Button("Disconnect", role: .destructive) { model.disconnect() }
                    }
                } footer: {
                    if let hint = model.connectHint, model.client.state == .idle { Text(hint) }
                }

                Section {
                    LabeledContent("Address") {
                        TextField("Automatic", text: $model.host)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Pairing code") {
                        TextField("From the phone", text: $model.token)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .multilineTextAlignment(.trailing)
                            .monospaced()
                            .submitLabel(.go)
                            .onSubmit { if model.canConnect { model.connect() } }
                    }
                } header: {
                    Text("Phone")
                } footer: {
                    if let detected = model.gateway.address, model.host.isEmpty {
                        Text("Detected \(detected). Leave the address empty to use it, or type the phone's own address. The code is shown in the CellBridge app on the phone.")
                    } else {
                        Text("The phone's address on this Wi-Fi network, and the code its CellBridge app shows.")
                    }
                }

                Section {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    LabeledContent("Version", value: Self.version)
                } header: {
                    Text("About")
                } footer: {
                    Text("Microphone, contacts, notifications and the app's language are set in iOS Settings.")
                }

                Section {
                    NavigationLink {
                        DeveloperView()
                    } label: {
                        Label("Developer", systemImage: "hammer")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inlineLarge)
            .dismissibleKeyboard()
        }
    }
}

/// Audio diagnostics and the event log: for tracking down a problem, not for everyday use.
struct DeveloperView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Button(model.audioTestRunning ? "Testing… (about 10 s)" : "Audio test") { model.runAudioSelfTest() }
                    .disabled(model.audioTestRunning)
                Button(model.audioTestRunning ? "Testing… (about 18 s)" : "Mic test (speak steadily)") { model.runMicTest() }
                    .disabled(model.audioTestRunning)
                Picker("Voice processing", selection: Binding(
                    get: { AudioBridge.storedVoiceProcessing.rawValue },
                    set: { UserDefaults.standard.set($0, forKey: "voiceProcessing") })) {
                    Text("Full (default)").tag("full")
                    Text("Full, no auto gain").tag("fullNoAGC")
                    Text("Bypassed").tag("bypassed")
                    Text("Off").tag("off")
                }
                Toggle("Record the far end", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "recordAudio") },
                    set: { UserDefaults.standard.set($0, forKey: "recordAudio") }))
            } header: {
                Text("Audio")
            } footer: {
                Text("The audio test plays a tone through the call's audio path in four ways and logs what the mixer renders. Turn the volume up; no call needed.")
            }
            Section("Events") {
                Button("Copy all") { UIPasteboard.general.string = model.events.joined(separator: "\n") }
                    .disabled(model.events.isEmpty)
                Text(model.events.joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }
}
