import SwiftUI
import MapKit

/// Stable color per podcast (same show → same color across launches). Swift's
/// String.hashValue is per-process-randomized, so use a fixed djb2 hash.
func listenColor(_ title: String) -> Color {
    let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .red, .indigo, .mint, .brown, .cyan, .yellow]
    var hash = 5381
    for byte in title.utf8 { hash = (hash &* 33) &+ Int(byte) }
    return palette[abs(hash) % palette.count]
}

/// A full map of where podcasts get listened to — color-coded by show, filterable by show, for
/// spotting behavior patterns. The period is Review's (the app's one span switch): with one,
/// this shows that period; without one, everything.
struct ListenMapView: View {
    @EnvironmentObject var history: ListenHistoryStore
    @State private var hidden: Set<String> = []
    /// The period Review is showing.
    var span: TrendSpan? = nil
    @State private var selected: UUID?

    private func inRangeEvents() -> [ListenEvent] {
        history.events.filter { $0.coordinate != nil && (span?.contains($0.date) ?? true) }
    }
    private var selectedEvent: ListenEvent? { selected.flatMap { id in history.events.first { $0.id == id } } }

    var body: some View {
        // One pass over the history per render. As chained computed vars, every marker-selection
        // re-render filtered the full event list three times and re-grouped the legend.
        let events = inRangeEvents()
        let visible = events.filter { !hidden.contains($0.podcastTitle) }
        let shows: [(name: String, count: Int)] = Dictionary(grouping: events, by: \.podcastTitle)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.count > $1.count }

        return Group {
            if events.isEmpty {
                ContentUnavailableView("No mapped listens", systemImage: "map",
                                       description: Text("Turn on “Record where I listen” in Settings \u{203A} Podcasts and play some episodes."))
            } else {
                Map(selection: $selected) {
                    ForEach(visible) { event in
                        if event.route.count > 1 {
                            MapPolyline(coordinates: event.route.map(\.coordinate))
                                .stroke(listenColor(event.podcastTitle),
                                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        }
                        if let coordinate = event.coordinate {
                            Marker(event.podcastTitle, coordinate: coordinate)
                                .tint(listenColor(event.podcastTitle))
                                .tag(event.id)
                        }
                    }
                }
                .task {
                    let ids = Set(events.map(\.id))
                    history.unloadRoutes(except: ids)
                    await history.loadRoutes(for: ids)
                }
                .safeAreaInset(edge: .bottom) {
                    if let event = selectedEvent { selectionCard(event) } else { legend(shows) }
                }
            }
        }
        .navigationTitle("Listening map")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func legend(_ shows: [(name: String, count: Int)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s) {
                // A filter per show, on or off: the system's toggle button on a solid backing
                // (content controls sit on solid surfaces; glass is the navigation layer).
                ForEach(shows, id: \.name) { show in
                    ChoiceChip(isOn: Binding(get: { !hidden.contains(show.name) },
                                             set: { on in
                                                 if on { hidden.remove(show.name) } else { hidden.insert(show.name) }
                                             })) {
                        HStack(spacing: 6) {
                            Circle().fill(listenColor(show.name)).frame(width: 10, height: 10)
                            // The name alone: a count beside it read as a total, not a filter.
                            Text(show.name).lineLimit(1)
                        }
                    }
                    .background(.background, in: Capsule())
                }
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        }
    }

    private func selectionCard(_ event: ListenEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.episodeTitle).font(.subheadline.weight(.medium)).lineLimit(2)
            HStack(spacing: 6) {
                Circle().fill(listenColor(event.podcastTitle)).frame(width: 8, height: 8)
                Text(event.podcastTitle).lineLimit(1)
                Text("· \(event.date.formatted(.dateTime.month().day().hour().minute()))")
            }
            .font(.caption).foregroundStyle(.secondary)
            if let place = event.place {
                Label(place, systemImage: "mappin.and.ellipse").font(.caption2).foregroundStyle(.secondary)
            }
            if event.routePointCount > 1 {
                Label("\(event.routePointCount) route points", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .padding(DS.Space.m)
    }
}
