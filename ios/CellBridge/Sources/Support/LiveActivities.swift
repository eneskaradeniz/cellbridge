import ActivityKit
import Foundation
import UIKit

/// Tells the host the tokens it needs to run the Live Activity of a call on the phone (docs/protocol.md "Live Activity"): the one for
/// starting an activity by push, which only a push may do while the app is in the background, and, per activity, the one for updating it.
/// Both can change at any time, and the host forgets update tokens when it restarts, so everything is sent again after every `hello_ack`.
@MainActor
final class LiveActivityTokens {
    var send: ((ClientMessage) -> Void)?
    var log: ((String) -> Void)?
    /// The name to show for a number (contact name, else the number as the app prints it).
    var displayName: ((String) -> String)?
    /// Brings the link to the host up (the app is woken for a push-started activity with the link down).
    var wake: (() -> Void)?
    var isConnected: (() -> Bool)?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var startToken: String?
    private var updateTokens: [String: String] = [:]
    private var observed = Set<String>()
    private var activities: [String: Activity<CallActivityAttributes>] = [:]

    func start() {
        log?("live activities \(ActivityAuthorizationInfo().areActivitiesEnabled ? "allowed" : "NOT allowed (Settings > CellBridge > Live Activities)")")
        Task { [weak self] in
            for await data in Activity<CallActivityAttributes>.pushToStartTokenUpdates {
                self?.startToken = Self.hex(data)
                self?.log?("live start token received")
                self?.sendStartToken()
            }
        }
        Task { [weak self] in
            for await activity in Activity<CallActivityAttributes>.activityUpdates { self?.observe(activity) }
        }
        for activity in Activity<CallActivityAttributes>.activities { observe(activity) } // started by a push while the app was not running
    }

    /// The link to the host came up.
    func resend() {
        sendStartToken()
        for (callId, token) in updateTokens { send?(.liveUpdateToken(callId: callId, token: token)) }
        if !updateTokens.isEmpty { releaseBackgroundTime() }
    }

    /// The host can end the activity only once it has this call's update token, and the token exists only after the system has woken the app
    /// for a push-started activity: so the app asks for a little time in the background to bring the link up and hand the token over.
    private func holdBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "live-activity-token") { [weak self] in self?.releaseBackgroundTime() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            self?.releaseBackgroundTime()
        }
    }

    private func releaseBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// The host lists the calls on the phone: an activity for any other call has no reason to stay (its end push may never have gotten through).
    func endStale(liveCallIds: Set<String>) {
        for activity in activities.values {
            let id = activity.attributes.callId
            #if DEBUG
            if id == "sample" { continue }
            #endif
            guard !liveCallIds.contains(id) else { continue }
            log?("live activity for call \(id) outlived its call: ending it")
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func sendStartToken() {
        if let startToken { send?(.liveStartToken(token: startToken)) }
    }

    /// An activity this app started itself: `activityUpdates` reports only the ones a push started.
    func adopt(_ activity: Activity<CallActivityAttributes>) { observe(activity) }

    private func observe(_ activity: Activity<CallActivityAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        activities[activity.id] = activity
        if UIApplication.shared.applicationState != .active {
            holdBackgroundTime()
            wake?()
        }
        let callId = activity.attributes.callId
        log?("live activity for call \(callId) is on screen")
        Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                let token = Self.hex(data)
                self?.updateTokens[callId] = token
                self?.send?(.liveUpdateToken(callId: callId, token: token))
                if self?.isConnected?() == true { self?.releaseBackgroundTime() }
            }
        }
        // A push-started activity carries the number sealed: this process can open it, the widget cannot. A later push (hold, resume)
        // replaces the state without the name, so every update is checked again.
        Task { [weak self] in
            await self?.addName(to: activity, content: activity.content)
            for await content in activity.contentUpdates { await self?.addName(to: activity, content: content) }
        }
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                self?.updateTokens[callId] = nil
                self?.observed.remove(activity.id)
                self?.activities[activity.id] = nil
                return
            }
        }
    }

    /// The contacts finished loading: a name that was only a number (the app can be woken for a push before its contacts are read) may now have one.
    func refreshNames() {
        for activity in activities.values { Task { [weak self] in await self?.addName(to: activity, content: activity.content, replacing: true) } }
    }

    private func addName(to activity: Activity<CallActivityAttributes>, content: ActivityContent<CallActivityAttributes.ContentState>, replacing: Bool = false) async {
        guard replacing || content.state.name == nil else { return }
        guard !content.state.sealed.isEmpty, let key = PushKeyStore.existing() else {
            return log?("live activity: no key or no sealed caller, so no name") ?? ()
        }
        guard let number = PushSeal.openLive(content.state.sealed, key: key)?.number else {
            return log?("live activity: the caller could not be read from the push") ?? ()
        }
        var state = content.state
        let name = displayName?(number) ?? number
        guard name != state.name else { return }
        state.name = name
        await activity.update(ActivityContent(state: state, staleDate: content.staleDate))
        log?("live activity: caller name added")
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
