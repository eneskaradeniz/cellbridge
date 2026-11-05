import SwiftUI

/// The dial pad, laid out like the system Phone app's.
struct KeypadView: View {
    @EnvironmentObject var model: AppModel
    @State private var number = ""

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

    /// Shrinks on short screens (iPhone SE) so the five rows always fit.
    @State private var keySize: CGFloat = 84

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Text(number.isEmpty ? " " : number)
                    .font(.system(size: 44, weight: .light))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .accessibilityLabel(number.isEmpty ? String(localized: "No number entered") : number)
                    .contextMenu {
                        if UIPasteboard.general.hasStrings {
                            Button { number = DialInput.sanitize(UIPasteboard.general.string ?? "") } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                        }
                        if !number.isEmpty {
                            Button { UIPasteboard.general.string = number } label: { Label("Copy", systemImage: "doc.on.doc") }
                        }
                    }
                Text(hint ?? " ")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            GlassEffectContainer(spacing: 20) {
                VStack(spacing: 14) {
                    ForEach(rows.indices, id: \.self) { row in
                        HStack(spacing: 24) {
                            ForEach(rows[row]) { key in keyView(key) }
                        }
                    }
                    HStack(spacing: 24) {
                        Color.clear.frame(width: keySize, height: keySize) // keeps the call button centred
                        Button(action: call) {
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
                        .allowsHitTesting(!number.isEmpty)
                        .accessibilityHidden(number.isEmpty)
                        .accessibilityHint(String(localized: "Touch and hold to clear"))
                        .accessibilityLabel("Delete")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { keySize = min(84, max(58, ($0 - 190) / 5.6)) }
        .sensoryFeedback(.selection, trigger: number)
        .onChange(of: model.activeCalls.isEmpty) { _, idle in if !idle { number = "" } } // kept until the call really starts, so a refused dial loses nothing
    }

    private var canCall: Bool { !number.isEmpty || !model.lastDialed.isEmpty }

    private var hint: String? { model.canDial ? nil : String(localized: "Not connected. Open Settings to connect.") }

    /// Like the Phone app: with nothing typed, Call brings back the last number instead of dialing.
    private func call() {
        if number.isEmpty { number = model.lastDialed } else { model.dial(number) }
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
        .onLongPressGesture(minimumDuration: 0.5) { if key.digit == "0", number.isEmpty { number = "+" } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key.letters.isEmpty ? key.digit : "\(key.digit), \(key.letters.map(String.init).joined(separator: " "))")
        .accessibilityAddTraits(.isButton)
    }
}

/// What may be dialed: digits, `*`, `#`, and a `+` only in front. Pasted numbers arrive with spaces, dashes and brackets.
enum DialInput {
    static func sanitize(_ text: String) -> String {
        let kept = text.filter { $0.isASCII && ($0.isNumber || "*#+".contains($0)) }
        guard let first = kept.first else { return "" }
        let rest = kept.dropFirst().filter { $0 != "+" }
        return String(first) + rest
    }
}
