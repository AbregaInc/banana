import SwiftUI
import MapKit
import CoreLocation

/// Wraps `MKLocalSearchCompleter` to power address autocomplete.
@MainActor
final class LocationSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()
    private var searchTask: Task<Void, Never>?
    private var suppressNextSearch = false

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}

    private func scheduleSearch() {
        if suppressNextSearch {
            suppressNextSearch = false
            return
        }
        searchTask?.cancel()
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else {
            completer.queryFragment = ""
            results = []
            return
        }
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.completer.queryFragment = clean
        }
    }

    /// Resolve a completion to coordinates + a short label.
    func resolve(_ completion: MKLocalSearchCompletion) async -> (CLLocationCoordinate2D, String)? {
        guard let item = await resolveItem(completion) else { return nil }
        return (item.location.coordinate, completion.title)
    }

    func resolveItem(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        return item
    }

    func finish(with value: String) {
        searchTask?.cancel()
        completer.queryFragment = ""
        results = []
        suppressNextSearch = true
        query = value
    }
}

@MainActor
final class EventLocationRecents: ObservableObject {
    static let shared = EventLocationRecents()

    @Published private(set) var locations: [CalendarEventLocation] = []
    private let key = "eventLocationRecents.v1"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CalendarEventLocation].self, from: data)
        else { return }
        locations = decoded
    }

    func record(_ location: CalendarEventLocation) {
        locations.removeAll {
            if let placeID = location.placeID, !placeID.isEmpty {
                return $0.placeID == placeID
            }
            return $0.title.caseInsensitiveCompare(location.title) == .orderedSame
        }
        locations.insert(location, at: 0)
        if locations.count > 20 { locations.removeLast(locations.count - 20) }
        if let data = try? JSONEncoder().encode(locations) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Inline, local-first event location authoring. Recent chosen places appear without network;
/// MapKit joins only after a short typing debounce, and a chosen completion retains coordinates.
struct EventLocationField: View {
    @Binding var location: String
    @Binding var structuredLocation: CalendarEventLocation?
    @StateObject private var model = LocationSearchModel()
    @ObservedObject private var recents = EventLocationRecents.shared
    @State private var resolving = false

    private var cleanQuery: String {
        model.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingRecents: [CalendarEventLocation] {
        let candidates = cleanQuery.isEmpty
            ? Array(recents.locations.prefix(3))
            : recents.locations.filter {
                $0.title.localizedCaseInsensitiveContains(cleanQuery)
            }
        return Array(candidates.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Location or room", text: $model.query)
                    .accessibilityIdentifier("event.location")
                if resolving { ProgressView().controlSize(.small) }
            }

            ForEach(matchingRecents, id: \.self) { recent in
                Button {
                    select(recent)
                } label: {
                    Label(recent.title, systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(model.results.prefix(5)), id: \.self) { result in
                Button {
                    resolve(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).foregroundStyle(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(resolving)
            }
        }
        .onAppear {
            if model.query.isEmpty { model.finish(with: location) }
            #if DEBUG
            // `--location-query <text>`: show the suggestions for a typed place in a snapshot.
            let args = ProcessInfo.processInfo.arguments
            if let flag = args.firstIndex(of: "--location-query"), args.indices.contains(flag + 1) {
                model.query = args[flag + 1]
            }
            #endif
        }
        .onChange(of: model.query) {
            location = model.query
            if structuredLocation?.title != model.query {
                structuredLocation = nil
            }
        }
        // A value set from outside (an event that finished loading after the field appeared)
        // shows in the field, without opening suggestions for text nobody just typed.
        .onChange(of: location) {
            if location != model.query { model.finish(with: location) }
        }
    }

    private func select(_ selected: CalendarEventLocation) {
        structuredLocation = selected
        location = selected.title
        model.finish(with: selected.title)
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        resolving = true
        Task {
            let trace = Signpost.begin("eventLocationResolve")
            defer { Signpost.end(trace) }
            defer { resolving = false }
            guard let item = await model.resolveItem(completion) else { return }
            let label = [completion.title, completion.subtitle]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            let selected = CalendarEventLocation(
                title: label,
                latitude: item.location.coordinate.latitude,
                longitude: item.location.coordinate.longitude,
                placeID: item.identifier?.rawValue
            )
            EventLocationRecents.shared.record(selected)
            select(selected)
        }
    }
}

/// Reuses the same on-device MapKit autocomplete for event locations, while still allowing
/// private rooms or dial-in instructions that are not map results.
struct EventLocationPicker: View {
    @Binding var location: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LocationSearchModel()

    private var cleanQuery: String {
        model.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if !cleanQuery.isEmpty {
                Section {
                    Button {
                        location = cleanQuery
                        dismiss()
                    } label: {
                        Label("Use “\(cleanQuery)”", systemImage: "text.cursor")
                            .foregroundStyle(.primary)
                    }
                }
            }

            if !model.results.isEmpty {
                Section("Places") {
                    ForEach(model.results, id: \.self) { result in
                        Button {
                            location = [result.title, result.subtitle]
                                .filter { !$0.isEmpty }
                                .joined(separator: ", ")
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(text: $model.query, prompt: "Address, place, or room")
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model.query.isEmpty { model.query = location }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }
}

/// Which saved place a picker edits.
enum LocationKind { case home, work }

/// Sheet to pick a home or work location by search or current location.
struct HomeLocationPicker: View {
    var kind: LocationKind = .home
    @EnvironmentObject var smart: SmartScheduleStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LocationSearchModel()
    @State private var working = false
    @State private var lookupError: String?

    private var noun: String { kind == .work ? "work" : "home" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task {
                            working = true
                            lookupError = nil
                            let ok = await smart.useCurrentLocation(for: kind)
                            working = false
                            // Only leave on success — a silent dismiss on failure looked
                            // like the sheet ate the tap.
                            if ok {
                                dismiss()
                            } else {
                                lookupError = smart.errorMessage
                                    ?? "Couldn't get your current location. Check Location Services in Privacy & Security, or search instead."
                            }
                        }
                    } label: {
                        Label("Use current location", systemImage: "location.fill")
                    }
                    .tint(DS.Palette.accent)
                    if let lookupError {
                        Text(lookupError)
                            .font(.footnote)
                            .foregroundStyle(DS.Palette.danger)
                    }
                }

                if !model.results.isEmpty {
                    Section("Results") {
                        ForEach(model.results, id: \.self) { result in
                            Button { pick(result) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title).foregroundStyle(.primary)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $model.query, prompt: "Search your \(noun) address")
            .navigationTitle(kind == .work ? "Work location" : "Home location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay {
                if working { ProgressView().controlSize(.large) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }

    private func pick(_ result: MKLocalSearchCompletion) {
        Task {
            working = true
            if let (coord, label) = await model.resolve(result) {
                switch kind {
                case .home: smart.setHome(latitude: coord.latitude, longitude: coord.longitude, label: label)
                case .work: smart.setWork(latitude: coord.latitude, longitude: coord.longitude, label: label)
                }
            }
            working = false
            dismiss()
        }
    }
}
