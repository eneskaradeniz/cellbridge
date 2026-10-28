import SwiftUI

/// The call history, like the system Phone app's Recents.
struct RecentsView: View {
    @EnvironmentObject var model: AppModel
    @State private var missedOnly = false
    @State private var confirmingClear = false

    private var shown: [CallRecord] { missedOnly ? model.recents.filter(\.isMissed) : model.recents }

    var body: some View {
        NavigationStack {
            List(shown) { record in
                Button { model.dial(record.number) } label: { Row(record: record) }
                    .disabled(!model.canDial || record.number.isEmpty)
            }
            .listStyle(.plain)
            .overlay {
                if shown.isEmpty { ContentUnavailableView(missedOnly ? "No missed calls" : "No recent calls", systemImage: "phone") }
            }
            .navigationTitle("Recents")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Filter", selection: $missedOnly) {
                        Text("All").tag(false)
                        Text("Missed").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { confirmingClear = true }.disabled(model.recents.isEmpty)
                }
            }
            .confirmationDialog("Clear all recent calls?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) { model.clearRecents() }
            }
        }
    }

    private struct Row: View {
        let record: CallRecord

        var body: some View {
            HStack {
                Image(systemName: record.direction == .outgoing ? "phone.arrow.up.right" : "phone.arrow.down.left")
                    .foregroundStyle(record.isMissed ? .red : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title.isEmpty ? record.number : record.title)
                        .font(.headline)
                        .foregroundStyle(record.isMissed ? .red : .primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.when(record.date)).font(.subheadline).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }

        private var detail: String {
            switch record.outcome {
            case .answered: return Self.duration(record.duration)
            case .missed: return "Missed"
            case .declined: return "Declined"
            case .noAnswer: return "No answer"
            case .failed: return "Failed"
            }
        }

        static func when(_ date: Date) -> String {
            Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .numeric, time: .omitted)
        }

        static func duration(_ seconds: TimeInterval) -> String {
            let total = Int(seconds.rounded())
            return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
                                 : String(format: "%d:%02d", total / 60, total % 60)
        }
    }
}
