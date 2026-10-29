import SwiftUI

/// "Updated 17:12" under a list: when the phone's data last reached this app.
struct SyncFooter: View {
    let date: Date?

    var body: some View {
        if let date {
            Text("Updated \(MessageDisplay.timestamp(date))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }
}
