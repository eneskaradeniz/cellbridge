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
                .navigationTitle(onPick == nil ? "Contacts" : "Choose a Number")
                .toolbarTitleDisplayMode(.inlineLarge)
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
                ContentUnavailableView("Contacts Are Not Shared", systemImage: "person.crop.circle.badge.xmark",
                                       description: Text("Allow access to see names instead of numbers and to pick who to call."))
                if model.canAskForContacts {
                    Button("Allow Access") { model.requestContacts() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.buttonStyle(.bordered)
                }
            }
        } else {
            let sections = model.contactBook.sections(of: model.contactBook.search(query))
            if sections.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No Contacts", systemImage: "person.crop.circle",
                                           description: Text("Contacts added on this iPhone show up here."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
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
            Button { choose(contact.numbers[0].value, with: onPick) } label: { label(contact) }
                .buttonStyle(.plain)
        } else {
            NavigationLink { detail(for: contact) } label: { label(contact) }
        }
    }

    private func label(_ contact: Contact) -> some View {
        HStack(spacing: 12) {
            Avatar(name: contact.name, size: 36)
            Text(contact.name).lineLimit(1)
        }
    }

    private func detail(for contact: Contact) -> some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Avatar(name: contact.name, size: 96)
                    Text(contact.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    if onPick == nil, let first = contact.numbers.first {
                        GlassEffectContainer(spacing: 16) {
                            HStack(spacing: 16) {
                                quickAction("Message", "message.fill", enabled: model.canSendSms) { messageTarget = MessageTarget(number: first.value) }
                                quickAction("Call", "phone.fill", enabled: model.canDial) { model.dial(first.value) }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(contact.numbers, id: \.self) { number in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(number.label).font(.caption).foregroundStyle(.secondary)
                            Text(number.value).font(.body)
                        }
                        Spacer()
                        if let onPick {
                            Button("Use") { choose(number.value, with: onPick) }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        } else {
                            Button { messageTarget = MessageTarget(number: number.value) } label: { Image(systemName: "message.fill") }
                                .disabled(!model.canSendSms)
                            Button { model.dial(number.value) } label: { Image(systemName: "phone.fill") }
                                .tint(.green)
                                .disabled(!model.canDial)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func quickAction(_ title: LocalizedStringKey, _ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption)
            }
            .frame(width: 84, height: 60)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func choose(_ number: String, with onPick: (String) -> Void) {
        onPick(number)
        dismiss()
    }
}
