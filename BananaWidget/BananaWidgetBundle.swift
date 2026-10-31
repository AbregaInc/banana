import WidgetKit
import SwiftUI

/// Hosts the Live Activity that AlarmKit uses to present a ringing alarm on the
/// Lock Screen and in the Dynamic Island, and the calendar widgets.
@main
struct BananaWidgetBundle: WidgetBundle {
    var body: some Widget {
        BananaAlarmActivity()
        NextMeetingWidget()
        DayGridWidget()
    }
}
