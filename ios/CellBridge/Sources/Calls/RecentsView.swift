import SwiftUI

/// The call history, like the system Phone app's Recents.
struct RecentsView: View {
    @EnvironmentObject var model: AppModel
    @State private var missedOnly = false
    @State private var confirmingClear = false

    private var shown: [CallRecord] { missedOnly ? model.recents.filter(\.isMissed) : model.recents }

    var body: some View {
        NavigationStack {
            List {
                Picker("Filter", selection: $missedOnly) {
                    Text("All").tag(false)
                    Text("Missed").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                ForEach(shown) { record in
                    Button { model.dial(record.number) } label: {
                        Row(record: record, name: model.displayName(for: record.number, fallback: record.title))
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(model.canDial && !record.number.isEmpty)
                }
            }
            .listStyle(.plain)
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView(
                        missedOnly ? "No Missed Calls" : "No Recent Calls",
                        systemImage: missedOnly ? "phone.arrow.down.left" : "phone",
                        description: Text(missedOnly ? "Calls you did not answer show up here." : "Calls made and received through the phone show up here."))
                }
            }
            .navigationTitle("Recents")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { confirmingClear = true }.disabled(model.recents.isEmpty)
                }
            }
            .confirmationDialog("Clear all recent calls?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear All Recents", role: .destructive) { model.clearRecents() }
            }
        }
    }

    private struct Row: View {
        let record: CallRecord
        let name: String

        var body: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(record.isMissed ? Color.red : Color.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if record.direction == .outgoing { Image(systemName: "phone.fill").imageScale(.small) }
                        Text(detail)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(Self.when(record.date)).font(.subheadline).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }

        private var detail: String {
            switch record.outcome {
            case .answered: return Self.duration(record.duration)
            case .missed: return String(localized: "Missed")
            case .declined: return String(localized: "Declined")
            case .noAnswer: return String(localized: "No answer")
            case .failed: return String(localized: "Failed")
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
