import AVKit
import SwiftUI

/// Full-screen call UI while the app is open: the system only takes the screen over on the lock screen.
struct InCallView: View {
    @EnvironmentObject var model: AppModel
    /// The cover animates out after the call is gone; showing the last call keeps that frame from going black.
    @State private var last: ActiveCall?

    var body: some View {
        if let call = model.callScreen ?? last.map({ var ended = $0; ended.isEnded = true; return ended }) {
            InCallScreen(
                call: call, waiting: model.waitingCall, linkLost: !model.canDial, muted: model.muted, speakerOn: model.speakerOn,
                toggleMute: model.toggleMute, toggleSpeaker: model.toggleSpeaker,
                transfer: model.canTransfer ? { model.transferToPhone(call.id) } : nil,
                end: { model.endCall(call.id) }, answer: { model.answerCall(call.id) })
                .onAppear { last = call }
                .onChange(of: call) { _, new in last = new }
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

/// The call screen itself, free of the model so a sample call can be shown without a connection.
struct InCallScreen: View {
    let call: ActiveCall
    /// Another call ringing while this one is on; the system offers to take it, here it is only announced.
    var waiting: ActiveCall?
    /// The link to the phone dropped during the call: the timer would keep running over silence.
    var linkLost = false
    let muted: Bool
    let speakerOn: Bool
    let toggleMute: () -> Void
    let toggleSpeaker: () -> Void
    /// Moves the call to the phone itself; nil when the host cannot.
    var transfer: (() -> Void)?
    let end: () -> Void
    let answer: () -> Void

    private var ringing: Bool { !call.isOutgoing && !call.isAnswered }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                if let waiting {
                    Text("\(waiting.title) is calling")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                }
                VStack(spacing: 14) {
                    Avatar(name: call.title, size: 112)
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                    Text(call.title)
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                    status.font(.title3).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.top, 72)
                .padding(.horizontal)
                Spacer()
                GlassEffectContainer(spacing: 40) {
                    VStack(spacing: 48) {
                        if call.isAnswered && !call.isEnded { controls }
                        if !call.isEnded { buttons }
                    }
                }
                .padding(.bottom, 48)
            }
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .animation(.smooth, value: call.isAnswered)
        .sensoryFeedback(.impact, trigger: call.isAnswered)
        .sensoryFeedback(.selection, trigger: muted)
        .sensoryFeedback(.selection, trigger: speakerOn)
        // The screen stays on during a call; held to the ear (speaker off) it goes dark so the cheek touches nothing.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            UIDevice.current.isProximityMonitoringEnabled = false
        }
        .onChange(of: call.isAnswered) { _, _ in updateProximity() }
        .onChange(of: speakerOn) { _, _ in updateProximity() }
    }

    private func updateProximity() { UIDevice.current.isProximityMonitoringEnabled = call.isAnswered && !speakerOn }

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
        if call.isEnded {
            Text("Call ended")
        } else if linkLost && call.isAnswered {
            Text("Connection lost").foregroundStyle(.orange)
        } else if let answeredAt = call.answeredAt {
            Text(answeredAt, style: .timer).monospacedDigit()
                .accessibilityLabel("Call duration")
        } else if call.isOutgoing {
            Text("Calling…")
        } else {
            Text("Incoming call")
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            toggle(muted ? "mic.slash.fill" : "mic.fill", "Mute", on: muted, action: toggleMute)
            toggle(speakerOn ? "speaker.wave.3.fill" : "speaker.fill", "Speaker", on: speakerOn, action: toggleSpeaker)
            VStack(spacing: 8) {
                RoutePicker()
                    .frame(width: 76, height: 76)
                    .glassEffect(.regular.interactive(), in: .circle)
                Text("Audio").font(.footnote)
            }
            .accessibilityElement(children: .combine)
            if let transfer { toggle("arrow.left.arrow.right", "To Android", on: false, action: transfer) }
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

/// The system's audio route button (AirPods, Bluetooth, the iPhone's own earpiece and speaker).
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}
