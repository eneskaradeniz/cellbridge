import SwiftUI

struct MessagesView: View {
    @EnvironmentObject var model: AppModel
    @State private var composing = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List(model.messages.conversations) { conversation in
                NavigationLink(value: conversation.key) {
                    Row(conversation: conversation, name: model.displayName(for: conversation.peer))
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.messages.conversations.isEmpty {
                    ContentUnavailableView("No Messages", systemImage: "message",
                                           description: Text("Texts sent to the phone's number show up here."))
                }
            }
            .navigationTitle("Messages")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: String.self) { ThreadView(key: $0) }
            .toolbar {
                Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                    .disabled(!model.canSendSms)
                    .accessibilityLabel("New message")
            }
            .sheet(isPresented: $composing) { NewMessageView() }
            #if DEBUG
            .onAppear { if Sample.opensThread, let first = model.messages.conversations.first { path = [first.key] } }
            #endif
        }
    }

    private struct Row: View {
        let conversation: Conversation
        let name: String

        var body: some View {
            HStack(spacing: 12) {
                Avatar(name: name, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(name).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(MessageDisplay.timestamp(conversation.last.date)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(conversation.last.body).lineLimit(2).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct ThreadView: View {
    @EnvironmentObject var model: AppModel
    let key: String
    @State private var draft = ""

    private var conversation: Conversation? { model.messages.conversations.first { $0.key == key } }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.canSendSms }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(MessageDisplay.days(conversation?.messages ?? []), id: \.day) { day in
                    Text(MessageDisplay.dayTitle(day.day))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                    ForEach(Array(day.messages.enumerated()), id: \.element.id) { index, message in
                        Bubble(message: message, showsStatus: showsStatus(index, in: day.messages)) { model.messages.retry(message) }
                            .padding(.bottom, showsStatus(index, in: day.messages) ? 8 : 0)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(model.displayName(for: conversation?.peer ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .onAppear { model.threadOpen = true }
        .onDisappear { model.threadOpen = false }
        .sensoryFeedback(.success, trigger: conversation?.messages.count) { old, new in
            (new ?? 0) > (old ?? 0) && conversation?.last.direction == .outgoing
        }
    }

    /// The time (and delivery state) goes under the last text of a run, and always under one still sending or failed.
    private func showsStatus(_ index: Int, in messages: [TextMessage]) -> Bool {
        let message = messages[index]
        switch message.status {
        case .failed, .sending: return true
        default: break
        }
        guard index + 1 < messages.count else { return true }
        let next = messages[index + 1]
        return next.direction != message.direction || next.date.timeIntervalSince(message.date) > 300
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            Button {
                if let peer = conversation?.peer {
                    model.messages.send(to: peer, body: draft)
                    draft = ""
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.tint(.accentColor.opacity(canSend ? 1 : 0.3)).interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

private struct Bubble: View {
    let message: TextMessage
    let showsStatus: Bool
    let retry: () -> Void

    var body: some View {
        let outgoing = message.direction == .outgoing
        let line = MessageDisplay.statusLine(for: message)
        VStack(alignment: outgoing ? .trailing : .leading, spacing: 3) {
            Text(message.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(outgoing ? Color.white : Color.primary)
                .background(outgoing ? Color.accentColor : Color(.systemGray5), in: shape(outgoing))
                .opacity(message.status == .sending ? 0.7 : 1)
                .frame(maxWidth: 300, alignment: outgoing ? .trailing : .leading)
                .textSelection(.enabled)
            if showsStatus {
                Text(line.text).font(.caption2).foregroundStyle(line.failed ? Color.red : Color.secondary)
            }
            if line.failed {
                Button("Try Again", action: retry).font(.caption.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }

    /// The corner at the speaker's side is tighter, a hint of the tail in the system Messages.
    private func shape(_ outgoing: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 19, bottomLeadingRadius: outgoing ? 19 : 5,
                               bottomTrailingRadius: outgoing ? 5 : 19, topTrailingRadius: 19, style: .continuous)
    }
}

struct NewMessageView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var to: String
    @State private var body_ = ""
    @State private var choosing = false

    init(initialTo: String = "") { _to = State(initialValue: initialTo) }

    private var canSend: Bool {
        !to.isEmpty && !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.canSendSms
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("To").foregroundStyle(.secondary)
                        TextField("Number", text: $to).keyboardType(.phonePad)
                        Button { choosing = true } label: { Image(systemName: "person.crop.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Choose from contacts")
                    }
                }
                Section {
                    TextField("Message", text: $body_, axis: .vertical).lineLimit(4...10)
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $choosing) { ContactsView(onPick: { to = $0 }) }
            .dismissibleKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", systemImage: "arrow.up") {
                        model.messages.send(to: to, body: body_)
                        dismiss()
                    }
                    .disabled(!canSend)
                }
            }
        }
    }
}
