import WidgetKit
import SwiftUI
import OSLog

private let complicationLog = Logger(
    subsystem: "com.boris.banana.watchkitapp.watchface",
    category: "timeline"
)

/// A watch-face complication that shows the next one or two calendar events in the rectangular
/// slot and retains Banana's compact launcher treatment in the other accessory families.
@main
struct BananaComplicationBundle: WidgetBundle {
    var body: some Widget { BananaComplication() }
}

struct BananaEntry: TimelineEntry {
    let date: Date
    let items: [WatchCalendarItem]
}

struct BananaProvider: TimelineProvider {
    private static func previewItems(at date: Date) -> [WatchCalendarItem] {
        [
            WatchCalendarItem(
                id: "preview-1", title: "Design review",
                start: date.addingTimeInterval(12 * 60),
                end: date.addingTimeInterval(42 * 60),
                location: "Studio 4"),
            WatchCalendarItem(
                id: "preview-2", title: "Lunch with Ana",
                start: date.addingTimeInterval(75 * 60),
                end: date.addingTimeInterval(135 * 60),
                location: nil),
        ]
    }

    func placeholder(in context: Context) -> BananaEntry {
        let date = Date.now
        return BananaEntry(date: date, items: Self.previewItems(at: date))
    }

    func getSnapshot(in context: Context, completion: @escaping (BananaEntry) -> Void) {
        complicationLog.notice("snapshot requested preview=\(context.isPreview)")
        let date = Date.now
        let stored = WatchCalendarSnapshotStore.load()
        let source = context.isPreview && stored.isEmpty ? Self.previewItems(at: date) : stored
        completion(BananaEntry(
            date: date,
            items: WatchCalendarSnapshotStore.upcoming(from: source, at: date)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BananaEntry>) -> Void) {
        let date = Date.now
        let stored = WatchCalendarSnapshotStore.load()
        let entry = BananaEntry(
            date: date,
            items: WatchCalendarSnapshotStore.upcoming(from: stored, at: date))
        let nextBoundary = stored
            .flatMap { [$0.start, $0.end] }
            .filter { $0 > date }
            .min()
        let hourly = date.addingTimeInterval(3_600)
        let refresh = min(nextBoundary ?? hourly, hourly)
        complicationLog.notice("live timeline requested; next refresh=\(refresh, privacy: .public)")
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

struct BananaComplication: Widget {
    /// Version the kind when the archived view itself changes. The original kind had a `.never`
    /// timeline and can remain blank on the live face even after the extension is replaced.
    private static let kind = WatchCalendarSnapshotStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: BananaProvider()) { entry in
            BananaComplicationView(entry: entry)
        }
        .configurationDisplayName("Next events")
        .description("See your next one or two calendar events.")
        #if os(watchOS)
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
        #else
        // Xcode also type-checks embedded extensions against the iOS simulator SDK when it
        // builds the phone host. `accessoryCorner` only exists on watchOS.
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
        #endif
    }
}

struct BananaComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BananaEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    BananaLogo().padding(4)
                }
            #if os(watchOS)
            case .accessoryCorner:
                BananaLogo().padding(3)
                    .widgetLabel("Banana")
            #endif
            case .accessoryInline:
                if let item = entry.items.first {
                    HStack(spacing: 4) {
                        Text(item.start, style: .time)
                        Text(item.title).lineLimit(1)
                    }
                } else {
                    Label {
                        Text("No upcoming events")
                    } icon: {
                        BananaLogo().frame(width: 14, height: 14)
                    }
                }
            case .accessoryRectangular:
                if entry.items.isEmpty {
                    HStack(spacing: 7) {
                        BananaLogo().frame(width: 24, height: 24)
                        Text("No upcoming events")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        if let item = entry.items.first {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                if item.start <= entry.date && item.end > entry.date {
                                    Text("NOW")
                                        .foregroundStyle(.orange)
                                } else {
                                    Text(item.start, style: .time)
                                        .foregroundStyle(.orange)
                                }
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        if entry.items.count > 1 {
                            let item = entry.items[1]
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(item.start, style: .time)
                                Text(item.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            default:
                BananaLogo()
            }
        }
        .widgetURL(URL(string: "bananawatch://agenda"))
        .containerBackground(for: .widget) { Color.clear }
    }
}

/// The brand mark, per rendering mode. The live face's hard-won constraints: rasters over
/// ~120px are dropped (grey disc), opaque bitmaps flatten to their alpha mask when tinted
/// (grey blob), and symbols always render. So full-color faces get the real logo as a 100px
/// circular RGBA raster — small enough to render, transparent corners so nothing can blob —
/// and tinted/monochrome faces get a feature-shaped alpha template that takes the face color.
struct BananaLogo: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    @ViewBuilder
    var body: some View {
        if renderingMode == .fullColor {
            Image("ComplicationIcon")
                .resizable()
                .scaledToFit()
        } else {
            Image("BananaMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
                .widgetAccentable()
        }
    }
}
