import SwiftUI

/// Full-screen call UI while the app is open: the system only takes the screen over on the lock screen.
struct InCallView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            if let call = model.activeCalls.first {
                VStack(spacing: 8) {
                    Text(call.title).font(.system(size: 36, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.5)
                    Group {
                        if let answeredAt = call.answeredAt {
                            Text(answeredAt, style: .timer).monospacedDigit()
                        } else {
                            Text(call.isOutgoing ? "calling…" : "CellBridge")
                        }
                    }
                    .font(.title3).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    if call.isAnswered { controls }
                    Spacer()
                    buttons(for: call)
                }
                .padding(.top, 80)
                .padding(.bottom, 50)
                .foregroundStyle(.white)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 40) {
            round(model.muted ? "mic.slash.fill" : "mic.fill", on: model.muted, label: "mute") { model.toggleMute() }
            round(model.speakerOn ? "speaker.wave.3.fill" : "speaker.fill", on: model.speakerOn, label: "speaker") { model.toggleSpeaker() }
        }
    }

    @ViewBuilder
    private func buttons(for call: ActiveCall) -> some View {
        if !call.isOutgoing && !call.isAnswered {
            HStack(spacing: 80) {
                circle("phone.down.fill", .red, label: "Decline") { model.endCall(call.id) }
                circle("phone.fill", .green, label: "Accept") { model.answerCall(call.id) }
            }
        } else {
            circle("phone.down.fill", .red, label: "End") { model.endCall(call.id) }
        }
    }

    private func circle(_ symbol: String, _ color: Color, label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 30)).frame(width: 76, height: 76).background(color, in: Circle())
            }
            Text(label).font(.footnote)
        }
    }

    private func round(_ symbol: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 28)).frame(width: 76, height: 76)
                    .foregroundStyle(on ? Color.black : Color.white)
                    .background(on ? Color.white : Color.white.opacity(0.18), in: Circle())
            }
            Text(label).font(.footnote)
        }
    }
}
