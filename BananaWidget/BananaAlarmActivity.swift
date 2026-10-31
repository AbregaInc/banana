import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

/// Live Activity presentation for a Banana alarm. AlarmKit drives this via
/// ActivityKit — the app itself never starts the activity directly.
struct BananaAlarmActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BananaAlarmAttributes.self) { context in
            // Lock Screen / banner presentation.
            HStack(spacing: 12) {
                Image(systemName: "alarm.fill")
                    .font(.title2)
                    .foregroundStyle(context.attributes.tintColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Banana")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(context.attributes.presentation.alert.title)
                        .font(.title3.weight(.semibold))
                }
                Spacer()
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "alarm.fill")
                        .foregroundStyle(context.attributes.tintColor)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.presentation.alert.title)
                        .font(.headline)
                }
            } compactLeading: {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                Text(context.attributes.presentation.alert.title)
                    .font(.caption2)
            } minimal: {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(context.attributes.tintColor)
            }
        }
    }
}
