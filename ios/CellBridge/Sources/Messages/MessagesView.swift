import SwiftUI

struct MessagesView: View {
    @EnvironmentObject var model: AppModel
    @State private var composing = false

    var body: some View {
        NavigationStack {
            List(model.messages.conversations) { conversation in
                NavigationLink(value: conversation.key) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(model.displayName(for: conversation.peer)).font(.headline)
                            Spacer()
                            Text(MessageDisplay.timestamp(conversation.last.date)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(conversation.last.body).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if model.messages.conversations.isEmpty {
                    ContentUnavailableView("No messages yet", systemImage: "message")
                }
            }
            .navigationTitle("Messages")
            .navigationDestination(for: String.self) { ThreadView(key: $0) }
            .toolbar {
                Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                    .disabled(!model.canSendSms)
            }
            .sheet(isPresented: $composing) { NewMessageView() }
        }
    }
}

struct ThreadView: View {
    @EnvironmentObject var model: AppModel
    let key: String
    @State private var draft = ""

    private var conversation: Conversation? { model.messages.conversations.first { $0.key == key } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(MessageDisplay.days(conversation?.messages ?? []), id: \.day) { day in
                        Text(MessageDisplay.dayTitle(day.day)).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(day.messages) { message in
                            Bubble(message: message) { model.messages.retry(message) }
                        }
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            Divider()
            HStack {
                TextField("Message", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button("Send") {
                    if let peer = conversation?.peer {
                        model.messages.send(to: peer, body: draft)
                        draft = ""
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canSendSms)
            }
            .padding(8)
        }
        .navigationTitle(model.displayName(for: conversation?.peer ?? ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Bubble: View {
    let message: TextMessage
    let retry: () -> Void

    var body: some View {
        let outgoing = message.direction == .outgoing
        VStack(alignment: outgoing ? .trailing : .leading, spacing: 2) {
            Text(message.body)
                .padding(10)
                .background(outgoing ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(outgoing ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            let line = MessageDisplay.statusLine(for: message)
            Text(line.text).font(.caption2).foregroundStyle(line.failed ? Color.red : Color.secondary)
            if line.failed { Button("Try again", action: retry).font(.caption) }
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }
}

struct NewMessageView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var to: String
    @State private var body_ = ""
    @State private var choosing = false

    init(initialTo: String = "") { _to = State(initialValue: initialTo) }

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField("Number", text: $to).keyboardType(.phonePad)
                    Button { choosing = true } label: { Image(systemName: "person.crop.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Choose from contacts")
                }
                TextField("Message", text: $body_, axis: .vertical).lineLimit(3...8)
            }
            .navigationTitle("New message")
            .sheet(isPresented: $choosing) { ContactsView(onPick: { to = $0 }) }
            .dismissibleKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        model.messages.send(to: to, body: body_)
                        dismiss()
                    }
                    .disabled(to.isEmpty || body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canSendSms)
                }
            }
        }
    }
}
