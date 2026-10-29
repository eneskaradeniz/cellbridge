import AppIntents

/// "Call with CellBridge" in Shortcuts, Spotlight, Siri and the Action button. iOS gives a third-party app no way to take over
/// the Phone app's own calls without the paid Default Calling App capability, so this is the way in from outside the app.
struct CallWithCellBridge: AppIntent {
    static let title: LocalizedStringResource = "Call with CellBridge"
    static let description = IntentDescription("Places a call through the connected phone.")
    static let openAppWhenRun = true

    @Parameter(title: "Name or number")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        // Opening the app and reconnecting takes a moment: wait for the model, then for the link, before dialing.
        for _ in 0..<50 where AppModel.current == nil { try await Task.sleep(for: .milliseconds(100)) }
        let model = AppModel.current
        for _ in 0..<50 where model?.canDial != true { try await Task.sleep(for: .milliseconds(100)) }
        model?.dial(query: query)
        return .result()
    }
}

struct CellBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CallWithCellBridge(),
            phrases: ["Call with \(.applicationName)", "Make a call with \(.applicationName)"],
            shortTitle: "Call with CellBridge",
            systemImageName: "phone.fill")
    }
}
