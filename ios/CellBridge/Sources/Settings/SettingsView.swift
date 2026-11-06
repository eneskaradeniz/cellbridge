import SwiftUI

/// Where the phone is found and paired. The audio tools and the event log live one level down, under Developer.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var scanning = false
    @State private var scanFailed = false
    @State private var typing = false

    private var status: LinkStatus { LinkStatus(model.client.state, unreachable: model.unreachable, paired: model.isPaired) }

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
                        if model.isPaired {
                            Button(status == .refused ? "Try Again" : "Connect") { model.connect() }.disabled(!model.canConnect)
                        } else {
                            Button { scanning = true } label: { Label("Scan the QR code", systemImage: "qrcode.viewfinder").fontWeight(.semibold) }
                        }
                    case .connected:
                        Button("Disconnect", role: .destructive) { model.disconnect() }
                    case .connecting:
                        // It keeps trying on its own; only when that has gone on for a while is there something to press.
                        if model.unreachable { Button("Retry") { model.retryConnection() } }
                    }
                    if case .connected = model.client.state, let info = model.hostInfo {
                        LabeledContent("Phone") { Text(info.summary).foregroundStyle(info.isLow ? Color.orange : Color.secondary) }
                    }
                    if let synced = model.lastSync {
                        LabeledContent("Last sync", value: MessageDisplay.timestamp(synced))
                    }
                } footer: {
                    if let hint = model.connectHint, model.client.state == .idle { Text(hint) }
                }

                Section {
                    if model.isPaired { Button { scanning = true } label: { Label("Scan the QR code", systemImage: "qrcode.viewfinder") } }
                    NavigationLink { PhoneDetailsView() } label: { Label("Phone Details", systemImage: "lock") }
                } header: {
                    Text("Phone")
                } footer: {
                    if scanFailed { Text("That is not a CellBridge QR code.").foregroundStyle(.red) } else {
                        Text("Open CellBridge on the Android phone and scan the QR code shown there, once. After that this iPhone finds the phone by itself.")
                    }
                }

                if model.spam.supported {
                    Section {
                        NavigationLink { SpamView() } label: { Label("Blocked", systemImage: "shield.lefthalf.filled") }
                        Toggle("Block unknown numbers", isOn: Binding(get: { model.spam.strict }, set: { model.spam.setStrict($0) }))
                    } header: {
                        Text("Spam")
                    } footer: {
                        Text("Calls and texts from numbers that are not in your contacts are blocked. Contacts always get through.")
                    }
                }

                Section {
                    ForEach(PermissionKind.allCases) { PermissionRow(kind: $0) }
                } header: {
                    Text("Permissions")
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
            .sheet(isPresented: $scanning) {
                ScanSheet(
                    onCode: { text in
                        scanning = false
                        scanFailed = !model.handleScan(text)
                    },
                    cancel: { scanning = false },
                    enterByHand: { scanning = false; typing = true })
            }
            .navigationDestination(isPresented: $typing) { PhoneDetailsView() }
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inlineLarge)
            .dismissibleKeyboard()
        }
    }
}

/// Audio diagnostics and the event log: for tracking down a problem, not for everyday use.
struct DeveloperView: View {
    @EnvironmentObject var model: AppModel
    @State private var code = ""

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
            Section {
                TextField("123456", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
            } header: {
                Text("Code AutoFill")
            } footer: {
                Text("Send a text with a code to the phone, then tap this field: the keyboard should offer the code.")
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
