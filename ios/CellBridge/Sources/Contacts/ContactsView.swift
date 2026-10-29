import SwiftUI
import UIKit

/// The contact list: the Contacts tab, and (with `onPick`) a chooser that hands one number back.
struct ContactsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onPick: ((String) -> Void)?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(onPick == nil ? "Contacts" : "Choose a Number")
                .toolbarTitleDisplayMode(.inlineLarge)
                .searchable(text: $query, prompt: "Search")
                .toolbar {
                    if onPick != nil { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                }
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
                        .sectionIndexLabel(section.letter)
                    }
                }
                .listStyle(.plain)
                .listSectionIndexVisibility(query.isEmpty ? .visible : .hidden)
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }

    @ViewBuilder
    private func row(for contact: Contact) -> some View {
        if let onPick {
            if contact.numbers.count == 1 {
                Button { choose(contact.numbers[0].value, with: onPick) } label: { label(contact) }
                    .buttonStyle(.plain)
            } else {
                NavigationLink { detail(for: contact) } label: { label(contact) }
            }
        } else {
            NavigationLink { detail(for: contact) } label: { label(contact) }
                .swipeActions(edge: .leading) {
                    if let first = contact.numbers.first {
                        Button { model.openThread(first.value) } label: { Label("Message", systemImage: "message.fill") }.tint(.blue)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if let first = contact.numbers.first {
                        Button { model.dial(first.value) } label: { Label("Call", systemImage: "phone.fill") }.tint(.green)
                    }
                }
                .contextMenu {
                    ForEach(Array(contact.numbers.enumerated()), id: \.offset) { _, number in
                        let suffix = contact.numbers.count > 1 ? " \(number.label)" : ""
                        Button { model.dial(number.value) } label: { Label("Call\(suffix)", systemImage: "phone") }
                        Button { model.openThread(number.value) } label: { Label("Message\(suffix)", systemImage: "message") }
                        Button { UIPasteboard.general.string = number.value } label: { Label("Copy \(number.value)", systemImage: "doc.on.doc") }
                    }
                }
        }
    }

    private func label(_ contact: Contact) -> some View {
        HStack(spacing: 12) {
            Avatar(name: contact.name, size: 36)
            Text(contact.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func detail(for contact: Contact) -> some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Avatar(name: contact.name, size: 96)
                    Text(contact.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    if onPick == nil, contact.numbers.count == 1, let first = contact.numbers.first {
                        GlassEffectContainer(spacing: 16) {
                            HStack(spacing: 16) {
                                quickAction("Message", "message.fill") { model.openThread(first.value) }
                                quickAction("Call", "phone.fill") { model.dial(first.value) }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(Array(contact.numbers.enumerated()), id: \.offset) { _, number in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            if !number.label.isEmpty { Text(number.label).font(.caption).foregroundStyle(.secondary) }
                            Text(number.value).font(.body).textSelection(.enabled)
                        }
                        Spacer()
                        if let onPick {
                            Button("Use") { choose(number.value, with: onPick) }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        } else {
                            Button { model.openThread(number.value) } label: { Image(systemName: "message.fill").frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel("Message \(number.label)")
                            Button { model.dial(number.value) } label: { Image(systemName: "phone.fill").frame(minWidth: 44, minHeight: 44) }
                                .tint(.green)
                                .accessibilityLabel("Call \(number.label)")
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func quickAction(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption)
            }
            .frame(minWidth: 84, minHeight: 60)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func choose(_ number: String, with onPick: (String) -> Void) {
        onPick(number)
        dismiss()
    }
}
