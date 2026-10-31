import SwiftUI

/// The controls that act on a detected meeting link. The detection itself lives in
/// `MeetingLinkDetection.swift` — split out so it can be unit-tested without dragging
/// `MeetingInfo`/`AppSettings` and their EventKit-backed dependency chain into the test target.

/// The obvious one-tap Join control. Cross-platform (opens via the environment openURL, so it
/// works on Mac too). The app's main-action look; the platform is in its words.
struct JoinButton: View {
    let url: URL
    let platform: MeetingPlatform
    var compact = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            Label(compact ? "Join" : "Join \(platform.label)", systemImage: "video.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.primarySmall)
        .fixedSize()
    }
}

// MapsProvider itself now lives in MapsProvider.swift (needed by AppSettings.Snapshot, which
// BananaTests sources without the rest of this file's EventKit-backed dependency chain). This
// extension keeps the MeetingInfo-typed method here, where MeetingInfo is in scope.
extension MapsProvider {
    /// A directions URL to a meeting's location — the coordinate when we have one (precise), else
    /// the address string (the maps app geocodes it). Google's `?api=1` form opens the app when
    /// installed and falls back to the web otherwise.
    func directionsURL(for meeting: MeetingInfo) -> URL? {
        let dest: String
        if let c = meeting.coordinate { dest = "\(c.latitude),\(c.longitude)" }
        else if let a = meeting.address, !a.isEmpty { dest = a }
        else { return nil }
        let enc = dest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dest
        switch self {
        case .apple:  return URL(string: "http://maps.apple.com/?daddr=\(enc)&dirflg=d")
        case .google: return URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(enc)")
        }
    }
}

/// "Directions" for an in-person meeting — the physical-location counterpart to JoinButton. Opens
/// the user's preferred maps app; the FIRST tap (before a default is set) asks which and remembers
/// it. Cross-platform via the environment openURL.
struct DirectionsButton: View {
    let meeting: MeetingInfo
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL
    @State private var asking = false

    var body: some View {
        Button {
            if let p = settings.mapsProvider { open(p) } else { asking = true }
        } label: {
            Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.secondarySmall)
        .fixedSize()
        .confirmationDialog("Open directions in", isPresented: $asking, titleVisibility: .visible) {
            Button("Apple Maps") { settings.mapsProvider = .apple; open(.apple) }
            Button("Google Maps") { settings.mapsProvider = .google; open(.google) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pick your maps app. You can change this later in Settings.")
        }
    }

    private func open(_ p: MapsProvider) { if let url = p.directionsURL(for: meeting) { openURL(url) } }
}

/// The row's LEADING icon, doubling as the primary action: a tinted, tappable Join for a video
/// meeting; a tappable Directions for an in-person one (first tap asks Apple/Google, then remembers);
/// a plain type icon otherwise. Replaces the separate trailing lozenge — the icon you were already
/// looking at IS the button. Tapping the rest of the row still opens the event details.
struct MeetingActionIcon: View {
    let meeting: MeetingInfo
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL
    @State private var askDirections = false

    var body: some View {
        if let url = meeting.joinURL, let p = meeting.platform {
            Button { openURL(url) } label: {
                Image(systemName: "video.fill").foregroundStyle(p.tint)
            }
            .iconButton()
        } else if meeting.hasPhysicalLocation {
            Button {
                if let mp = settings.mapsProvider { open(mp) } else { askDirections = true }
            } label: {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill").foregroundStyle(DS.Palette.travel)
            }
            .iconButton()
            .confirmationDialog("Open directions in", isPresented: $askDirections, titleVisibility: .visible) {
                Button("Apple Maps") { settings.mapsProvider = .apple; open(.apple) }
                Button("Google Maps") { settings.mapsProvider = .google; open(.google) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pick your maps app. You can change this later in Settings.")
            }
        } else {
            // As wide as the buttons above, so a column of these lines up.
            Image(systemName: meeting.isVirtual ? "video.fill" : "calendar")
                .foregroundStyle(.secondary)
                .frame(minWidth: DS.Row.minHeight, minHeight: DS.Row.minHeight)
        }
    }

    private func open(_ p: MapsProvider) { if let u = p.directionsURL(for: meeting) { openURL(u) } }
}
