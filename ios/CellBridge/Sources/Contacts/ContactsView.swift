import SwiftUI
import UIKit

/// The contact list: the Contacts tab, and (with `onPick`) a chooser that hands one number back.
struct ContactsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onPick: ((String) -> Void)?
    @State private var query = ""

    private struct MessageTarget: Identifiable {
        let id = UUID()
        let number: String
    }
    @State private var messageTarget: MessageTarget?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(onPick == nil ? "Contacts" : "Choose a number")
                .searchable(text: $query, prompt: "Search")
                .toolbar {
                    if onPick != nil { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                }
                .sheet(item: $messageTarget) { NewMessageView(initialTo: $0.number) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.contactsAuthorized {
            VStack(spacing: 12) {
                ContentUnavailableView("Contacts are not shared", systemImage: "person.crop.circle.badge.xmark",
                                       description: Text("Allow access to see names instead of numbers and to pick who to call."))
                if model.canAskForContacts {
                    Button("Allow access") { model.requestContacts() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.buttonStyle(.bordered)
                }
            }
        } else {
            let sections = model.contactBook.sections(of: model.contactBook.search(query))
            if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(sections, id: \.letter) { section in
                        Section(section.letter) {
                            ForEach(section.contacts) { row(for: $0) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }

    @ViewBuilder
    private func row(for contact: Contact) -> some View {
        if let onPick, contact.numbers.count == 1 {
            Button { choose(contact.numbers[0].value, with: onPick) } label: { Text(contact.name) }
        } else {
            NavigationLink(contact.name) { detail(for: contact) }
        }
    }

    private func detail(for contact: Contact) -> some View {
        List(contact.numbers, id: \.self) { number in
            VStack(alignment: .leading, spacing: 8) {
                Text(number.label).font(.caption).foregroundStyle(.secondary)
                Text(number.value).font(.title3)
                if let onPick {
                    Button("Use this number") { choose(number.value, with: onPick) }.buttonStyle(.borderedProminent)
                } else {
                    HStack {
                        Button { model.dial(number.value) } label: { Label("Call", systemImage: "phone.fill") }
                            .buttonStyle(.borderedProminent).tint(.green).disabled(!model.canDial)
                        Button { messageTarget = MessageTarget(number: number.value) } label: { Label("Message", systemImage: "message.fill") }
                            .buttonStyle(.bordered).disabled(!model.canSendSms)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ number: String, with onPick: (String) -> Void) {
        onPick(number)
        dismiss()
    }
}
