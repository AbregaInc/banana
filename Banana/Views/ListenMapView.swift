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

/// A full map of where podcasts get listened to — color-coded by show, filterable by
/// time and show, for spotting behavior patterns.
struct ListenMapView: View {
    @EnvironmentObject var history: ListenHistoryStore
    @State private var hidden: Set<String> = []
    @State private var range: Range = .month
    /// The period Review is showing. With one, this map shows that period and has no switch of
    /// its own (Review's is the app's one span switch).
    var span: TrendSpan? = nil
    @State private var selected: UUID?

    enum Range: String, CaseIterable, Identifiable {
        case week = "Week", month = "Month", all = "All"
        var id: String { rawValue }
        var cutoff: Date? {
            switch self {
            case .week:  return Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
            case .all:   return nil
            }
        }
    }

    private func inRangeEvents() -> [ListenEvent] {
        if let span { return history.events.filter { $0.coordinate != nil && span.contains($0.date) } }
        let cutoff = range.cutoff
        return history.events.filter { $0.coordinate != nil && (cutoff == nil || $0.date >= cutoff!) }
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
                .task(id: range) {
                    let ids = Set(events.map(\.id))
                    history.unloadRoutes(except: ids)
                    await history.loadRoutes(for: ids)
                }
                .safeAreaInset(edge: .top) {
                    if span == nil {
                        PageSwitch(label: "Range", selection: $range, choices: Range.allCases,
                                   title: { $0.rawValue }, fills: true)
                        .padding(DS.Space.s)
                        .background(.ultraThinMaterial)
                    }
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
                ForEach(shows, id: \.name) { show in
                    let off = hidden.contains(show.name)
                    Button {
                        if off { hidden.remove(show.name) } else { hidden.insert(show.name) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(listenColor(show.name)).frame(width: 10, height: 10)
                            Text(show.name).lineLimit(1)
                            Text("\(show.count)").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                        .floatingCapsule()
                        .opacity(off ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .padding(DS.Space.m)
    }
}
