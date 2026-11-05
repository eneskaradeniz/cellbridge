import LocalAuthentication
import SwiftUI

/// The pairing code and the typed address, behind Face ID (or the passcode): the code is the key to the phone's calls and texts.
/// Nothing is hidden while nothing is paired yet, so a first manual entry needs no unlocking.
struct PhoneDetailsView: View {
    @EnvironmentObject var model: AppModel
    @State private var unlocked = false
    @State private var failed = false
    @State private var confirmingForget = false

    private var visible: Bool { unlocked || model.token.isEmpty }

    var body: some View {
        Form {
            if visible {
                Section {
                    LabeledContent("Address") {
                        TextField(model.detectedAddress ?? String(localized: "Automatic"), text: $model.host)
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
                } footer: {
                    Text("Normally the phone is found by itself. Type an address only on a network where that does not work.")
                }
                if !model.token.isEmpty {
                    Section {
                        Button("Forget this phone", role: .destructive) { confirmingForget = true }
                    }
                }
            } else {
                Section {
                    Button { Task { await unlock() } } label: { Label("Unlock with Face ID", systemImage: "faceid") }
                } footer: {
                    Text(failed ? "Could not unlock. Try again." : "The pairing details are hidden.")
                }
            }
        }
        .navigationTitle("Phone Details")
        .navigationBarTitleDisplayMode(.inline)
        .task { await unlock() }
        .dismissibleKeyboard()
        .confirmationDialog("Forget this phone?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { model.forgetPairing() }
        } message: {
            Text("You will have to scan its QR code again.")
        }
    }

    private func unlock() async {
        guard !unlocked else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if error?.code == LAError.passcodeNotSet.rawValue {
                unlocked = true // no passcode on this iPhone: nothing to ask for
            } else {
                failed = true // anything else (e.g. biometry locked out and no fallback): stay hidden, offer a retry
            }
            return
        }
        do {
            unlocked = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Show the pairing details"))
            failed = !unlocked
        } catch {
            failed = true
        }
    }
}
