import SwiftUI

/// Calls and texts the phone blocked, newest first; "Not Spam" lets that number through again.
struct SpamView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            if !model.spam.screening {
                Label("The phone is not screening calls yet. Texts are filtered; give CellBridge the call screening role on the Android phone.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(model.spam.items) { item in
                Row(item: item, name: model.displayName(for: item.number))
                    .swipeActions(edge: .trailing) {
                        Button { model.spam.notSpam(item) } label: { Label("Not Spam", systemImage: "checkmark.shield") }.tint(.green)
                    }
                    .contextMenu {
                        Button { model.spam.notSpam(item) } label: { Label("Not Spam", systemImage: "checkmark.shield") }
                        Button { UIPasteboard.general.string = item.number } label: { Label("Copy Number", systemImage: "doc.on.doc") }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.spam.items.isEmpty {
                ContentUnavailableView("Nothing Blocked", systemImage: "checkmark.shield",
                                       description: Text("Spam calls and texts the phone stops show up here."))
            }
        }
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.spam.markSeen() }
    }

    private struct Row: View {
        let item: SpamItem
        let name: String

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: item.kind == "call" ? "phone.down.fill" : "message.badge.filled.fill").foregroundStyle(.red)
                    Text(name).font(.headline).lineLimit(1)
                    Spacer()
                    Text(MessageDisplay.timestamp(Date(timeIntervalSince1970: Double(item.ts) / 1000)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let body = item.body { Text(body).font(.subheadline).lineLimit(2).foregroundStyle(.secondary) }
                Text(SpamCenter.reasonText(item.reason)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }
}
