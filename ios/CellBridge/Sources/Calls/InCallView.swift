import SwiftUI

/// Full-screen call UI while the app is open: the system only takes the screen over on the lock screen.
struct InCallView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let call = model.activeCalls.first {
            InCallScreen(
                call: call, muted: model.muted, speakerOn: model.speakerOn,
                toggleMute: model.toggleMute, toggleSpeaker: model.toggleSpeaker,
                end: { model.endCall(call.id) }, answer: { model.answerCall(call.id) })
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

/// The call screen itself, free of the model so a sample call can be shown without a connection.
struct InCallScreen: View {
    let call: ActiveCall
    let muted: Bool
    let speakerOn: Bool
    let toggleMute: () -> Void
    let toggleSpeaker: () -> Void
    let end: () -> Void
    let answer: () -> Void

    private var ringing: Bool { !call.isOutgoing && !call.isAnswered }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    Avatar(name: call.title, size: 112)
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                    Text(call.title)
                        .font(.system(size: 34, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    status.font(.title3).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.top, 72)
                .padding(.horizontal)
                Spacer()
                GlassEffectContainer(spacing: 40) {
                    VStack(spacing: 48) {
                        if call.isAnswered { controls }
                        buttons
                    }
                }
                .padding(.bottom, 48)
            }
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .animation(.smooth, value: call.isAnswered)
        .sensoryFeedback(.impact, trigger: call.isAnswered)
    }

    private var background: some View {
        let tint = Avatar.palette[Avatar(name: call.title).index].bottom
        return ZStack {
            Color.black
            LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.15), .black], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var status: some View {
        if let answeredAt = call.answeredAt {
            Text(answeredAt, style: .timer).monospacedDigit()
        } else if call.isOutgoing {
            Text("calling…")
        } else {
            Text("CellBridge")
        }
    }

    private var controls: some View {
        HStack(spacing: 36) {
            toggle(muted ? "mic.slash.fill" : "mic.fill", "mute", on: muted, action: toggleMute)
            toggle(speakerOn ? "speaker.wave.3.fill" : "speaker.fill", "speaker", on: speakerOn, action: toggleSpeaker)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    @ViewBuilder
    private var buttons: some View {
        if ringing {
            HStack(spacing: 80) {
                action("phone.down.fill", .red, label: "Decline", perform: end)
                action("phone.fill", .green, label: "Accept", perform: answer)
            }
        } else {
            action("phone.down.fill", .red, label: "End", perform: end)
        }
    }

    private func action(_ symbol: String, _ color: Color, label: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: perform) {
                Image(systemName: symbol).font(.system(size: 30)).frame(width: 76, height: 76)
                    .glassEffect(.regular.tint(color).interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            Text(label).font(.footnote)
        }
        .accessibilityElement(children: .combine)
    }

    private func toggle(_ symbol: String, _ label: LocalizedStringKey, on: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 28)).frame(width: 76, height: 76)
                    .foregroundStyle(on ? Color.black : Color.white)
                    .glassEffect(on ? .regular.tint(.white).interactive() : .regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            Text(label).font(.footnote)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
