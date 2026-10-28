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

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Text(number.isEmpty ? " " : number)
                .font(.system(size: 36, weight: .light))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
            if let error = model.dialError {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            } else if !model.canDial {
                Text("Not connected. Open Settings to connect.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(rows[row]) { key in keyView(key) }
                }
            }
            HStack(spacing: 24) {
                Color.clear.frame(width: 78, height: 78)
                Button {
                    model.dial(number)
                    number = ""
                } label: {
                    Image(systemName: "phone.fill").font(.system(size: 30)).foregroundStyle(.white)
                        .frame(width: 78, height: 78)
                        .background(canCall ? Color.green : Color.green.opacity(0.35), in: Circle())
                }
                .disabled(!canCall)
                Button { if !number.isEmpty { number.removeLast() } } label: {
                    Image(systemName: "delete.left").font(.system(size: 26)).foregroundStyle(.secondary)
                        .frame(width: 78, height: 78)
                }
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in number = "" })
                .opacity(number.isEmpty ? 0 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
    }

    private var canCall: Bool { !number.isEmpty && model.canDial }

    /// `*` and `#` are shown for the familiar layout but stay inactive: the host refuses service codes.
    private func keyView(_ key: Key) -> some View {
        let enabled = key.digit != "*" && key.digit != "#"
        return VStack(spacing: 0) {
            Text(key.digit).font(.system(size: 34, weight: .regular))
            Text(key.letters.isEmpty ? " " : key.letters).font(.system(size: 11, weight: .semibold)).tracking(2)
        }
        .frame(width: 78, height: 78)
        .background(Color(.systemGray5), in: Circle())
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Circle())
        .onTapGesture { if enabled { number += key.digit } }
        .onLongPressGesture(minimumDuration: 0.5) { if key.digit == "0" { number += "+" } }
        .accessibilityLabel(key.digit)
    }
}
