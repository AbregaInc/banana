import SwiftUI
import MapKit

/// A log of past podcast listens, grouped by day, plus one map of everywhere you've
/// listened (when location recording is on).
struct ListenHistoryView: View {
    @EnvironmentObject var history: ListenHistoryStore
    @ObservedObject private var toasts = ToastCenter.shared
    /// The period Review is showing: what was played in it, and only that.
    var span: TrendSpan? = nil

    private var events: [ListenEvent] {
        // Cleared, and waiting on its Undo (`DeleteUndo.listeningHistory`).
        if toasts.hiddenIDs.contains(DeleteUndo.listeningHistoryID) { return [] }
        guard let span else { return history.events }
        return history.events.filter { span.contains($0.date) }
    }

    var body: some View {
        let events = events
        // Group once. The former `days` + `events(on:)` pair rescanned the full lifetime history
        // once per day on every body evaluation (quadratic after months of listening).
        let grouped = Dictionary(grouping: events) {
            Calendar.current.startOfDay(for: $0.date)
        }.sorted { $0.key > $1.key }
        let located = Array(events.lazy.filter { $0.coordinate != nil }.prefix(100))

        Group {
            if events.isEmpty {
                ContentUnavailableView(span == nil ? "No history yet" : "Nothing played then",
                                       systemImage: "clock.arrow.circlepath",
                                       description: Text("Episodes you play show up here."))
            } else {
                List {
                    if !located.isEmpty {
                        Section("Where you listen") {
                            Map(initialPosition: .automatic, interactionModes: []) {
                                ForEach(located) { event in
                                    if event.route.count > 1 {
                                        MapPolyline(coordinates: event.route.map(\.coordinate))
                                            .stroke(listenColor(event.podcastTitle),
                                                    style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                    }
                                    if let coordinate = event.coordinate {
                                        Marker(event.podcastTitle, coordinate: coordinate)
                                            .tint(listenColor(event.podcastTitle))
                                    }
                                }
                            }
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                            .allowsHitTesting(false)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            NavigationLink {
                                ListenMapView(span: span)
                            } label: {
                                Label("Open full map", systemImage: "map")
                            }
                        }
                    }
                    ForEach(grouped, id: \.key) { day, events in
                        Section(day.formatted(.dateTime.weekday(.wide).month().day())) {
                            ForEach(events) { event in ListenRow(event: event) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Listening")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !history.events.isEmpty, !toasts.hiddenIDs.contains(DeleteUndo.listeningHistoryID) {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("Clear history", systemImage: "trash", role: .destructive) { DeleteUndo.listeningHistory(history) }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
        }
    }

}

private struct ListenRow: View {
    let event: ListenEvent

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: event.artworkURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.episodeTitle).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(event.date, format: .dateTime.hour().minute())
                    if !event.podcastTitle.isEmpty { Text("· \(event.podcastTitle)").lineLimit(1) }
                    if let ended = event.endedAt, ended > event.date {
                        Text("· \(duration(event.duration))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let place = event.place {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
