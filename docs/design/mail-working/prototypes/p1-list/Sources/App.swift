import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()
    let args = LaunchArgs.current
    let model = InboxModel()
    /// The app's background discard, as state outside the tree: false replaces the whole host with a blank view.
    @Published var showContent = true
    lazy var runner = ScenarioRunner(app: self)

    var title: String { "p1 \(args.host.rawValue)\(args.host == .native ? "" : "/\(args.variant.rawValue)") \(args.scenario ?? "")" }

    func launch() async {
        guard let name = args.scenario else { return }
        try? await Task.sleep(for: .seconds(1.5))      // the first frame settles
        await runner.run(name)
    }
}

struct RootView: View {
    @ObservedObject var app: AppController

    var body: some View {
        VStack(spacing: 0) {
            Text(app.title).font(.caption2).foregroundStyle(.secondary).frame(height: 18)
            if app.args.uitest { SwipeOverlay() }
            ZStack {
                if app.showContent {
                    HostView(app: app)
                } else {
                    Color.gray.opacity(0.35)
                }
            }
        }
        .task { await app.launch() }
    }
}

struct HostView: View {
    let app: AppController
    var body: some View {
        switch app.args.host {
        case .list: ListHost(model: app.model, variant: app.args.variant)
        case .lazy: LazyHost(model: app.model, variant: app.args.variant, diySwipe: app.args.diySwipe)
        case .native: NativeHostView(model: app.model)
        }
    }
}

/// UI test only: swipe counters outside the list.
struct SwipeOverlay: View {
    @ObservedObject private var log = SwipeLog.shared
    var body: some View {
        Text("lead=\(log.leading) trail=\(log.trailing) last=\(log.last)")
            .font(.caption).frame(height: 22)
            .accessibilityIdentifier("swipe.counts")
    }
}

@main
struct P1App: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacDelegate.self) private var delegate
    #else
    @StateObject private var app = AppController.shared
    #endif

    var body: some Scene {
        #if os(macOS)
        // No SwiftUI window on the Mac: `MacDelegate` builds one non-activating panel (see below).
        Settings { EmptyView() }
        #else
        WindowGroup { RootView(app: app) }
        #endif
    }
}

#if os(macOS)
/// A window that can never become key or main, so showing it can never take focus from what the
/// person is typing in.
final class MeasurementPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A throwaway measurement app that must be safe to run while someone is working:
/// - agent (`LSUIElement` in the plist + `.accessory`): no Dock icon, no menu bar, never activated;
/// - one borderless non-activating panel: never key or main, ignores the mouse (a trackpad scroll
///   over it passes through to whatever is underneath), not in the window cycle / Mission Control /
///   Windows menu, fixed small size, bottom-right corner of the main screen (override with
///   `--mac-window x,y,w,h`, y measured from the bottom of the screen, as AppKit does);
/// - ordered front *without* activating, floating, so it stays unoccluded: a covered window gets
///   no display-link callbacks and its frame timings would mean nothing.
final class MacDelegate: NSObject, NSApplicationDelegate {
    private var panel: MeasurementPanel?
    static var screen: NSScreen?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        Self.screen = screen
        var frame = NSRect(x: screen.visibleFrame.maxX - 380 - 16, y: screen.visibleFrame.minY + 16, width: 380, height: 520)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--mac-window"), i + 1 < args.count {
            let v = args[i + 1].split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { frame = NSRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
        }
        let p = MeasurementPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        p.isExcludedFromWindowsMenu = true
        p.hasShadow = false
        p.backgroundColor = .windowBackgroundColor
        p.contentView = NSHostingView(rootView: RootView(app: AppController.shared))
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()                 // never `activate`
        panel = p
    }
}
#endif
