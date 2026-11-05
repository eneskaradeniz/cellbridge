import SwiftUI

/// Sits in the glass accessory above the tab bar while a call runs on the phone itself: who, for how long, and a way to take it over.
struct PhoneCallBar: View {
    let name: String
    let since: Date?
    let take: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.connection.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 0) {
                Text("On the phone").font(.caption2).foregroundStyle(.secondary)
                Text(name).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let since { Text(since, style: .timer).font(.footnote.monospacedDigit()).foregroundStyle(.secondary) }
            Button("Take Over", action: take)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.green)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}
