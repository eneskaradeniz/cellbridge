import SwiftUI

/// The calls in progress and a plain number field to place one; the host does the dialing.
struct CallsView: View {
    @EnvironmentObject var model: AppModel
    @State private var number = ""

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
            Section("Call a number") {
                TextField("Number", text: $number).keyboardType(.phonePad)
                Button("Call") {
                    model.dial(number)
                    number = ""
                }
                .disabled(number.isEmpty || !model.canDial)
                if let error = model.dialError { Text(error).font(.footnote).foregroundStyle(.red) }
                if !model.canDial { Text("Connect to the phone first (Connection tab).").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .dismissibleKeyboard()
    }
}
