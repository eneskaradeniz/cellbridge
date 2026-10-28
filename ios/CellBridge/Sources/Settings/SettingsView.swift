import SwiftUI

/// Where the phone is found and paired. The audio tools and the event log live one level down, under Developer.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    private var status: LinkStatus { LinkStatus(model.client.state) }

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
                    if model.client.state == .idle {
                        Button("Connect") { model.connect() }.disabled(!model.canConnect)
                    } else {
                        Button("Disconnect", role: .destructive) { model.disconnect() }
                    }
                }

                Section {
                    LabeledContent("Address") {
                        TextField(model.gateway.address ?? "192.168.43.1", text: $model.host)
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
                    }
                } header: {
                    Text("Phone")
                } footer: {
                    Text("The phone's address on this Wi-Fi network, and the code its CellBridge app shows.")
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
