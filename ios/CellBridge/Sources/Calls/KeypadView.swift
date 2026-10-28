import SwiftUI

/// The dial pad, laid out like the system Phone app's.
struct KeypadView: View {
    @EnvironmentObject var model: AppModel
    @State private var number = ""
    @State private var choosing = false

    private struct Key: Identifiable {
        let digit: String
        let letters: String
        var id: String { digit }
    }

    private let rows: [[Key]] = [
        [Key(digit: "1", letters: ""), Key(digit: "2", letters: "ABC"), Key(digit: "3", letters: "DEF")],
        [Key(digit: "4", letters: "GHI"), Key(digit: "5", letters: "JKL"), Key(digit: "6", letters: "MNO")],
        [Key(digit: "7", letters: "PQRS"), Key(digit: "8", letters: "TUV"), Key(digit: "9", letters: "WXYZ")],
        [Key(digit: "*", letters: ""), Key(digit: "0", letters: "+"), Key(digit: "#", letters: "")],
    ]

    private let keySize: CGFloat = 78

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Text(number.isEmpty ? " " : number)
                    .font(.system(size: 40, weight: .light))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                Text(hint ?? " ")
                    .font(.footnote)
                    .foregroundStyle(model.dialError == nil ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            GlassEffectContainer(spacing: 20) {
                VStack(spacing: 16) {
                    ForEach(rows.indices, id: \.self) { row in
                        HStack(spacing: 24) {
                            ForEach(rows[row]) { key in keyView(key) }
                        }
                    }
                    HStack(spacing: 24) {
                        Button { choosing = true } label: {
                            Image(systemName: "person.crop.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                                .frame(width: keySize, height: keySize)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose from contacts")
                        Button {
                            model.dial(number)
                            number = ""
                        } label: {
                            Image(systemName: "phone.fill").font(.system(size: 30)).foregroundStyle(.white)
                                .frame(width: keySize, height: keySize)
                                .glassEffect(.regular.tint(.green.opacity(canCall ? 1 : 0.4)).interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canCall)
                        .accessibilityLabel("Call")
                        Button { if !number.isEmpty { number.removeLast() } } label: {
                            Image(systemName: "delete.left").font(.system(size: 26)).foregroundStyle(.secondary)
                                .frame(width: keySize, height: keySize)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in number = "" })
                        .opacity(number.isEmpty ? 0 : 1)
                        .accessibilityLabel("Delete")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
        .sensoryFeedback(.selection, trigger: number)
        .sheet(isPresented: $choosing) { ContactsView(onPick: { number = $0 }) }
    }

    private var canCall: Bool { !number.isEmpty && model.canDial }

    private var hint: String? {
        if let error = model.dialError { return error }
        return model.canDial ? nil : String(localized: "Not connected. Open Settings to connect.")
    }

    /// `*` and `#` are shown for the familiar layout but stay inactive: the host refuses service codes.
    private func keyView(_ key: Key) -> some View {
        let enabled = key.digit != "*" && key.digit != "#"
        return VStack(spacing: 0) {
            Text(key.digit).font(.system(size: 34, weight: .regular))
            Text(key.letters.isEmpty ? " " : key.letters).font(.system(size: 11, weight: .semibold)).tracking(2)
        }
        .frame(width: keySize, height: keySize)
        .glassEffect(enabled ? .regular.interactive() : .regular, in: .circle)
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Circle())
        .onTapGesture { if enabled { number += key.digit } }
        .onLongPressGesture(minimumDuration: 0.5) { if key.digit == "0" { number += "+" } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key.digit)
        .accessibilityAddTraits(.isButton)
    }
}
