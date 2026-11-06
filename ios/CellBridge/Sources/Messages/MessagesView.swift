import SwiftUI

struct MessagesView: View {
    @EnvironmentObject var model: AppModel
    @State private var composing = false
    @State private var path: [ThreadRoute] = []
    @State private var deleting: Conversation?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let problem = model.refreshProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .listRowSeparator(.hidden)
                        .onTapGesture { model.tab = .settings }
                        .accessibilityAddTraits(.isButton)
                }
                if model.spam.supported {
                    NavigationLink { SpamView() } label: {
                        HStack {
                            Label("Blocked", systemImage: "shield.lefthalf.filled").foregroundStyle(.red)
                            Spacer()
                            if model.spam.unseen > 0 { Text("\(model.spam.unseen)").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
                ForEach(model.messages.conversations) { conversation in
                NavigationLink(value: ThreadRoute(key: conversation.key, peer: conversation.peer)) {
                    Row(conversation: conversation, name: model.displayName(for: conversation.peer))
                }
                .avatarRowSeparator()
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = conversation } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions(edge: .leading) {
                    if conversation.unreadCount > 0 {
                        Button { model.messages.markRead(key: conversation.key) } label: { Label("Read", systemImage: "message") }.tint(.blue)
                    } else {
                        Button { model.messages.markUnread(key: conversation.key) } label: { Label("Unread", systemImage: "message.badge") }.tint(.blue)
                    }
                }
                .contextMenu {
                    Button { model.dial(conversation.peer) } label: { Label("Call", systemImage: "phone") }
                    Button { UIPasteboard.general.string = conversation.peer } label: { Label("Copy Number", systemImage: "doc.on.doc") }
                    if conversation.unreadCount > 0 {
                        Button { model.messages.markRead(key: conversation.key) } label: { Label("Mark as Read", systemImage: "message") }
                    } else {
                        Button { model.messages.markUnread(key: conversation.key) } label: { Label("Mark as Unread", systemImage: "message.badge") }
                    }
                    if model.spam.supported {
                        Button(role: .destructive) { model.reportSpam(conversation: conversation) } label: { Label("Report Spam", systemImage: "hand.raised") }
                    }
                    Button(role: .destructive) { deleting = conversation } label: { Label("Delete", systemImage: "trash") }
                }
                }
            }
            .listStyle(.plain)
            .refreshable { await model.refreshHistory() }
            .navigationSubtitle(model.syncSubtitle)
            .overlay {
                if model.messages.conversations.isEmpty {
                    ContentUnavailableView("No Messages", systemImage: "message",
                                           description: Text("Texts sent to the phone's number show up here."))
                }
            }
            .navigationTitle("Messages")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: ThreadRoute.self) { ThreadView(route: $0) }
            .toolbar {
                Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New message")
            }
            .sheet(isPresented: $composing) { NewMessageView() }
            .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let key = deleting?.key { model.messages.delete(conversation: key) } }
            } message: {
                Text("The texts are removed from this iPhone only.")
            }
            .onChange(of: model.threadRequest) { _, _ in openRequestedThread() }
            .onAppear {
                openRequestedThread() // the tab is built lazily: a request made before it existed is waiting
                #if DEBUG
                if Sample.opensThread, let first = model.messages.conversations.first { path = [ThreadRoute(key: first.key, peer: first.peer)] }
                #endif
            }
        }
    }

    private func openRequestedThread() {
        guard let route = model.threadRequest else { return }
        path = [route]
        model.threadRequest = nil
    }

    private struct Row: View {
        let conversation: Conversation
        let name: String

        var body: some View {
            HStack(spacing: ListRow.spacing) {
                Avatar(name: name, size: ListRow.avatar)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(name).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        if conversation.hasFailed { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
                        Text(MessageDisplay.timestamp(conversation.last.date)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(conversation.last.body).lineLimit(2).font(.subheadline)
                        .foregroundStyle(conversation.unreadCount > 0 ? Color.primary : Color.secondary)
                }
            }
            .padding(.vertical, 2)
            // The unread dot lives in the margin to the left of the gutter, so a read and an unread row start at the same place.
            .overlay(alignment: .leading) {
                if conversation.unreadCount > 0 {
                    Circle().fill(Color.accentColor).frame(width: 9, height: 9).offset(x: -13).accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(conversation.unreadCount > 0 ? String(localized: "Unread") : "")
        }
    }
}

struct ThreadView: View {
    @EnvironmentObject var model: AppModel
    let route: ThreadRoute
    @State private var draft = ""
    @FocusState private var composing: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var conversation: Conversation? { model.messages.conversations.first { $0.key == route.key } }
    private var peer: String { conversation?.peer ?? route.peer }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.canSendSms }

    private static let bottom = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(MessageDisplay.days(conversation?.messages ?? []), id: \.day) { day in
                        Text(MessageDisplay.dayTitle(day.day))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Array(day.messages.enumerated()), id: \.element.id) { index, message in
                            Bubble(message: message, showsStatus: showsStatus(index, in: day.messages),
                                   retry: { model.messages.retry(message) }, delete: { model.messages.delete(message: message.id) })
                                .padding(.bottom, showsStatus(index, in: day.messages) ? 8 : 0)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                Color.clear.frame(height: 1).id(Self.bottom) // what "the end" means, even while rows further up are not built yet
            }
            // Open at the newest text and stay there while the content grows (a text sent, the keyboard, a status line appearing).
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .onAppear { DispatchQueue.main.async { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            .onChange(of: conversation?.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onChange(of: conversation?.last.status) { _, _ in proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: conversation?.unreadCount) { _, unread in
                if (unread ?? 0) > 0, scenePhase == .active { model.messages.markRead(key: route.key) }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(model.displayName(for: peer))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { model.dial(peer) } label: { Image(systemName: "phone") }
                .accessibilityLabel("Call")
        }
        .toolbarVisibility(.hidden, for: .tabBar)
        .onAppear {
            model.threadOpen = true
            model.messages.viewingKey = route.key
            model.messages.markRead(key: route.key)
            if route.focusesComposer { composing = true }
        }
        .onDisappear {
            model.threadOpen = false
            model.messages.viewingKey = nil
        }
        .onChange(of: scenePhase) { _, phase in
            model.messages.viewingKey = phase == .active ? route.key : nil
            if phase == .active { model.messages.markRead(key: route.key) }
        }
        // A number in a text dials through the bridge; web links open as usual.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "tel" else { return .systemAction }
            model.dial(url.absoluteString.replacingOccurrences(of: "tel:", with: ""))
            return .handled
        })
        .sensoryFeedback(.impact(weight: .light), trigger: conversation?.messages.count) { old, new in
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
        VStack(alignment: .trailing, spacing: 2) {
            counter(for: draft)
            composerRow
        }
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(model.canSendSms ? "Message" : "Connect to the phone to send", text: $draft, axis: .vertical)
                .focused($composing)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            Button {
                model.messages.send(to: peer, body: draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.tint(.accentColor.opacity(canSend ? 1 : 0.3)).interactive(canSend), in: .circle)
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
    let delete: () -> Void

    var body: some View {
        let outgoing = message.direction == .outgoing
        let line = MessageDisplay.statusLine(for: message)
        VStack(alignment: outgoing ? .trailing : .leading, spacing: 3) {
            Text(MessageLinks.attributed(message.body))
                .tint(outgoing ? Color.white : Color.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(outgoing ? Color.white : Color.primary)
                .background(outgoing ? Color.accentColor : Color(.systemGray5), in: shape(outgoing))
                .opacity(message.status == .sending ? 0.7 : 1)
                .frame(maxWidth: 300, alignment: outgoing ? .trailing : .leading)
                .contextMenu {
                    Button { UIPasteboard.general.string = message.body } label: { Label("Copy", systemImage: "doc.on.doc") }
                    if line.failed { Button(action: retry) { Label("Try Again", systemImage: "arrow.clockwise") } }
                    Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
                }
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

/// "58 / 70 · 2 texts" once a draft gets long enough that its cost in SMS matters.
@ViewBuilder
private func counter(for text: String) -> some View {
    let measure = SmsLength.measure(text)
    if measure.units * 2 >= measure.perMessage {
        let parts = measure.parts
        Text(parts > 1 ? "\(measure.units) · \(parts) texts" : "\(measure.units) / \(measure.perMessage)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
    }
}

/// Who a new message goes to: a number, and the contact's name when it is one.
private struct Recipient: Equatable, Identifiable {
    let number: String
    let name: String?
    var id: String { MessageStore.key(for: number) }
    var title: String { name ?? number }
}

/// New message in the system Messages' layout: a "To:" field that suggests contacts as you type, the chosen people as name
/// chips, and the composer at the bottom. SMS has no group chat here (that would be MMS), so several people each get their own text.
struct NewMessageView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var recipients: [Recipient]
    @State private var query = ""
    @State private var body_ = ""
    @State private var choosing = false
    @FocusState private var focus: Field?
    private enum Field { case to, message }

    init(initialTo: String = "") {
        _recipients = State(initialValue: initialTo.isEmpty ? [] : [Recipient(number: initialTo, name: nil)])
    }

    private var canSend: Bool {
        (!recipients.isEmpty || typedNumber != nil) && !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.canSendSms
    }

    /// Contacts matching what is typed, one row per number.
    private var suggestions: [(contact: Contact, number: LabeledNumber)] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return model.contactBook.search(query).flatMap { contact in contact.numbers.map { (contact, $0) } }
    }

    /// The typed text, if it can be a phone number.
    private var typedNumber: String? {
        let text = query.trimmingCharacters(in: .whitespaces)
        let allowed = text.allSatisfy { $0.isNumber || "+ ()-".contains($0) }
        return allowed && text.filter(\.isNumber).count >= 3 ? text : nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                toField.padding(.horizontal, 16).padding(.top, 8)
                if query.trimmingCharacters(in: .whitespaces).isEmpty { Spacer(minLength: 0) } else { suggestionList }
                composer
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(role: .close) { dismiss() } } }
            .sheet(isPresented: $choosing) { ContactsView(onPick: { add(number: $0) }) }
            .onAppear {
                recipients = recipients.map { Recipient(number: $0.number, name: $0.name ?? model.contactBook.name(for: $0.number)) }
                focus = recipients.isEmpty ? .to : .message
            }
        }
    }

    private var toField: some View {
        HStack(spacing: 8) {
            Text("To:").foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(recipients) { person in
                        Button { recipients.removeAll { $0.id == person.id } } label: {
                            HStack(spacing: 4) {
                                Text(person.title).lineLimit(1)
                                Image(systemName: "xmark.circle.fill").imageScale(.small).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.22), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(person.title)
                        .accessibilityHint("Remove")
                    }
                    TextField("", text: $query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focus, equals: .to)
                        .submitLabel(.next)
                        .onSubmit { if let typedNumber { add(number: typedNumber) } }
                        .frame(minWidth: 80)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Button { choosing = true } label: {
                Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 34, height: 34)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Choose from contacts")
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
    }

    private var suggestionList: some View {
        List {
            if let typedNumber, !suggestions.contains(where: { MessageStore.key(for: $0.number.value) == MessageStore.key(for: typedNumber) }) {
                row(title: Text("Send to \(typedNumber)"), subtitle: nil, avatar: "") { add(number: typedNumber) }
            }
            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, item in
                row(title: Text(item.contact.name), subtitle: item.number.value, avatar: item.contact.name) { add(number: item.number.value) }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    /// The whole row is the button, not just the words in it.
    private func row(title: Text, subtitle: String?, avatar: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: ListRow.spacing) {
                Avatar(name: avatar, size: ListRow.avatar)
                VStack(alignment: .leading, spacing: 1) {
                    title.font(.body.weight(.semibold)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .avatarRowSeparator()
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if recipients.count > 1 { Text("Each person gets a separate text.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20) }
            counter(for: body_)
            if !model.canSendSms { Text("Connect to the phone to send.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $body_, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focus, equals: .message)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 38, height: 38)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .animation(.default, value: canSend)
    }

    private func add(number: String) {
        let person = Recipient(number: number, name: model.contactBook.name(for: number))
        if !recipients.contains(where: { $0.id == person.id }) { recipients.append(person) }
        query = ""
        focus = .to
    }

    private func send() {
        if let typedNumber { add(number: typedNumber) }
        let targets = recipients
        for person in targets { model.messages.send(to: person.number, body: body_) }
        dismiss()
        if targets.count == 1 { model.openThread(targets[0].number) } // land in the conversation, like the Messages app
    }
}
