import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LiveBundle: WidgetBundle {
    var body: some Widget { CallLiveActivity() }
}

/// A call on the phone, on the lock screen and in the Dynamic Island, with a button that takes it over (docs/protocol.md "Live Activity").
struct CallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let who = Who(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Badge(state: context.state, size: 40) }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(state: context.state).font(.title3.weight(.medium).monospacedDigit()).padding(.top, 6)
                }
                // The bottom region has the full width: the name goes here, not beside the camera where it is cut short.
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(who.title).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !context.state.isHolding { TakeOver(url: context.attributes.takeOverURL, height: 36) }
                    }
                }
            } compactLeading: {
                Image(systemName: "phone.fill").foregroundStyle(.green).padding(.leading, 2)
            } compactTrailing: {
                if context.state.isHolding {
                    Image(systemName: "pause.fill").foregroundStyle(.orange) // a word would be cut off in the small island
                } else {
                    Text(context.state.connectedAt, style: .timer).font(.footnote.weight(.medium).monospacedDigit())
                        .multilineTextAlignment(.trailing).frame(width: 46, alignment: .trailing)
                }
            } minimal: {
                Image(systemName: context.state.isHolding ? "pause.fill" : "phone.fill").foregroundStyle(context.state.isHolding ? .orange : .green)
            }
        }
    }
}

/// The caller as the app wrote it into the state; until it has, only that the call is on the phone.
private struct Who {
    let title: String
    let subtitle: String?

    init(_ state: CallActivityAttributes.ContentState) {
        if let name = state.name, !name.isEmpty {
            title = name
            subtitle = String(localized: "On the phone")
        } else {
            title = String(localized: "On the phone")
            subtitle = nil
        }
    }
}

private struct Badge: View {
    let state: CallActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        Image(systemName: state.isHolding ? "pause.fill" : "phone.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.green, in: Circle())
    }
}

private struct Elapsed: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        if state.isHolding {
            Text("On hold").foregroundStyle(.orange)
        } else {
            Text(state.connectedAt, style: .timer).multilineTextAlignment(.trailing)
        }
    }
}

private struct TakeOver: View {
    let url: URL
    var height: CGFloat = 44

    var body: some View {
        Link(destination: url) {
            Text("Take Over")
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(.green, in: Capsule())
        }
    }
}

private struct LockScreenView: View {
    let attributes: CallActivityAttributes
    let state: CallActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Badge(state: state, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    let who = Who(state)
                    Text(who.title).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    if let subtitle = who.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                Elapsed(state: state).font(.title2.weight(.medium).monospacedDigit()).frame(minWidth: 70, alignment: .trailing)
            }
            // A held call stays on the phone: the iPhone could not resume it.
            if !state.isHolding { TakeOver(url: attributes.takeOverURL) }
        }
    }
}
