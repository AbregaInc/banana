import SwiftUI
import MapKit
import CoreLocation

/// Clean up a recorded workout: crop a stationary lead-in / tail-out (e.g. you left
/// the recording running). Drag the handles or take the one-tap suggestion; the map
/// shows what's kept (orange) vs cropped (grey). Trim keeps an undoable original.
struct TrimWorkoutView: View {
    @EnvironmentObject var fitness: FitnessStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    let summary: FitnessSessionSummary

    @State private var located: [(t: TimeInterval, coord: CLLocationCoordinate2D)] = []
    @State private var distances: [(t: TimeInterval, meters: Double)] = []
    @State private var duration: TimeInterval = 1
    @State private var startOffset: TimeInterval = 0
    @State private var endOffset: TimeInterval = 1
    @State private var suggestion: (start: TimeInterval, end: TimeInterval)?
    @State private var loading = true
    @State private var applying = false
    /// Whether this device has the workout's recording. A summary can arrive before it.
    @State private var hasRecording = true

    private struct DisplayData: Sendable {
        var located: [LocatedPoint]
        var distances: [DistancePoint]
        var suggestion: TrimSuggestion?
    }

    private struct LocatedPoint: Sendable {
        var t: TimeInterval
        var lat: Double
        var lon: Double
    }

    private struct DistancePoint: Sendable {
        var t: TimeInterval
        var meters: Double
    }

    private struct TrimSuggestion: Sendable {
        var start: TimeInterval
        var end: TimeInterval
    }

    private var keptDistance: Double { max(0, distance(at: endOffset) - distance(at: startOffset)) }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .navigationTitle("Trim workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { apply() }
                        .disabled(applying || !hasRecording || (startOffset == 0 && endOffset >= duration))
                }
            }
            .task { await load() }
        }
    }

    private var content: some View {
        VStack(spacing: 18) {
            if hasRecording {
                map.frame(height: 240).clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))

                if let s = suggestion, !applying { suggestionBanner(s) }

                readouts

                scrubber.frame(height: 44)
            } else {
                ContentUnavailableView("Still arriving", systemImage: "icloud.and.arrow.down",
                                       description: Text("This workout\u{2019}s recording hasn\u{2019}t reached this \(DeviceRole.current.name) yet."))
            }

            // Offered wherever the workout is shown as edited, not only where the edit was made.
            if summary.edit != nil || fitness.hasOriginal(summary.id) {
                Button("Revert to original", role: .destructive) { revert() }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("trim.revert")
            }
            if !DeviceRole.current.isHub {
                // Apple Health is the phone's: say so, where a trim is made somewhere else.
                Text("Your iPhone updates Apple Health the next time Banana is open on it.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("trim.healthNote")
            }
            Spacer(minLength: 0)
        }
        .padding()
    }

    /// Here at once when this device holds the original. Otherwise another of your devices
    /// does: ask it (`WorkoutRevertInbox`).
    private func revert() {
        if !fitness.revertTrim(summary.id) {
            WorkoutRevertInbox.shared.ask(summary)
            ToastCenter.shared.notify("The original is on another of your devices. It comes back when Banana is next open there.")
        }
        dismiss()
    }

    private var map: some View {
        Map {
            if located.count > 1 {
                MapPolyline(coordinates: located.map(\.coord)).stroke(.gray.opacity(0.45), lineWidth: 3)
                let kept = located.filter { $0.t >= startOffset && $0.t <= endOffset }.map(\.coord)
                if kept.count > 1 { MapPolyline(coordinates: kept).stroke(DS.Palette.accent, lineWidth: 5) }
                if let s = located.first(where: { $0.t >= startOffset })?.coord {
                    Marker("Start", systemImage: "flag.fill", coordinate: s).tint(DS.Palette.success)
                }
                if let e = located.last(where: { $0.t <= endOffset })?.coord {
                    Marker("End", systemImage: "flag.checkered", coordinate: e).tint(DS.Palette.danger)
                }
            }
        }
    }

    private func suggestionBanner(_ s: (start: TimeInterval, end: TimeInterval)) -> some View {
        Button {
            withAnimation { startOffset = s.start; endOffset = s.end }
        } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "wand.and.stars").foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Trim \(idleDescription(s)) of no movement").font(.subheadline.weight(.semibold))
                    Text("Tap to set the handles automatically").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.accent.opacity(DS.Tint.soft), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var readouts: some View {
        HStack(alignment: .top) {
            stat("Start", clock(startOffset))
            Spacer()
            stat("Kept", clockDuration(endOffset - startOffset))
            Spacer()
            if keptDistance > 0 { stat("Distance", settings.distanceUnit.format(meters: keptDistance)) }
            Spacer()
            stat("End", clock(endOffset))
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x0 = CGFloat(startOffset / duration) * w
            let x1 = CGFloat(endOffset / duration) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemGray5)).frame(height: 6)
                Capsule().fill(DS.Palette.accent).frame(width: max(0, x1 - x0), height: 6).offset(x: x0)
                handle(x: x0, width: w, isStart: true)
                handle(x: x1, width: w, isStart: false)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
    }

    private func handle(x: CGFloat, width: CGFloat, isStart: Bool) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(DS.Palette.accent, lineWidth: 3))
            .shadow(radius: 2, y: 1)
            .position(x: min(max(14, x), width - 14), y: 22)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let t = min(max(0, g.location.x / width), 1) * duration
                        if isStart { startOffset = min(t, endOffset - 30) }
                        else { endOffset = max(t, startOffset + 30) }
                    }
            )
    }

    // MARK: - Data

    private func load() async {
        let samples = await fitness.samples(for: summary.id)
        let workoutDuration = max(1, summary.duration)
        // Raw sessions are intentionally retained at full fidelity and can hold hundreds of
        // thousands of motion samples. The old view filtered and sorted that entire array several
        // times on the main actor just as the sheet opened. Extract both tiny display series in one
        // off-main pass, then sort only those series.
        let display = await Task.detached(priority: .userInitiated) {
            var located: [LocatedPoint] = []
            var distances: [DistancePoint] = []
            for sample in samples {
                if sample.kind == .location, let lon = sample.v2 {
                    located.append(LocatedPoint(t: sample.t, lat: sample.v1, lon: lon))
                } else if sample.kind == .distance {
                    distances.append(DistancePoint(t: sample.t, meters: sample.v1))
                }
            }
            located.sort { $0.t < $1.t }
            distances.sort { $0.t < $1.t }
            let input = distances.map { (t: $0.t, meters: $0.meters) }
            let suggestion = FitnessStore.suggestedTrim(
                from: input, duration: workoutDuration
            ).map { TrimSuggestion(start: $0.start, end: $0.end) }
            return DisplayData(located: located, distances: distances, suggestion: suggestion)
        }.value

        hasRecording = !samples.isEmpty
        duration = workoutDuration
        located = display.located.map {
            ($0.t, CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon))
        }
        distances = display.distances.map { ($0.t, $0.meters) }
        startOffset = 0
        endOffset = duration
        suggestion = display.suggestion.map { ($0.start, $0.end) }
        loading = false
    }

    private func distance(at t: TimeInterval) -> Double {
        distances.last(where: { $0.t <= t })?.meters ?? 0
    }

    private func apply() {
        applying = true
        Task {
            // The same on every device. Apple Health follows on the phone, at once when the
            // trim is made there and when it arrives otherwise (`WorkoutHealthFollow`).
            await fitness.trim(summary.id, startOffset: startOffset, endOffset: endOffset)
            dismiss()
        }
    }

    // MARK: - Formatting

    private func clock(_ offset: TimeInterval) -> String {
        summary.start.addingTimeInterval(offset).formatted(.dateTime.hour().minute())
    }
    private func clockDuration(_ s: TimeInterval) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return m >= 60 ? String(format: "%d:%02d:%02d", m / 60, m % 60, sec) : String(format: "%d:%02d", m, sec)
    }
    private func idleDescription(_ s: (start: TimeInterval, end: TimeInterval)) -> String {
        let idle = s.start + (duration - s.end)
        let mins = Int((idle / 60).rounded())
        return "\(mins) min"
    }
}
