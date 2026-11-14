#if os(macOS)
import AppKit
import SwiftUI
import Combine

enum MacPermissionState: Equatable, Sendable {
    case checking, allowed, requestable, settings, restricted
}

struct MacPermissionEntry: Identifiable, Sendable {
    let id: SystemSettingsLink
    let title: String
    let symbol: String
    let read: @MainActor @Sendable () async -> MacPermissionState
    let request: @MainActor @Sendable () async -> Void
}

@MainActor
final class MacPermissionGuideModel: ObservableObject {
    let entries: [MacPermissionEntry]
    @Published private(set) var states: [SystemSettingsLink: MacPermissionState] = [:]
    @Published private(set) var busy: SystemSettingsLink?
    @Published var selected: SystemSettingsLink?
    @Published private(set) var visible = false
    var openSettings: (MacPermissionEntry) -> Void = { _ in }
    var prepareRequest: () -> Void = {}
    @Published var error: String?
    private var refreshing: Set<SystemSettingsLink> = []
    private var revision = 0
    private var stopped = false

    init(entries: [MacPermissionEntry]) { self.entries = entries }

    func refresh() async {
        guard !stopped else { return }
        await withTaskGroup(of: Void.self) { group in
            for entry in entries where !refreshing.contains(entry.id) {
                refreshing.insert(entry.id)
                let revision = revision
                group.addTask { @MainActor [weak self] in
                    let status = await entry.read()
                    guard let self else { return }
                    defer { self.refreshing.remove(entry.id) }
                    guard !self.stopped, revision == self.revision else { return }
                    self.publish(status, for: entry.id)
                }
            }
        }
    }

    private func publish(_ status: MacPermissionState, for id: SystemSettingsLink) {
        if states[id] != status { states[id] = status }
    }

    func activate(_ entry: MacPermissionEntry) async {
        guard !stopped, busy == nil else { return }
        revision += 1
        let revision = revision
        busy = entry.id
        error = nil
        defer { if !stopped { busy = nil } }
        let status = await entry.read()
        guard !stopped, revision == self.revision else { return }
        publish(status, for: entry.id)
        switch status {
        case .requestable:
            prepareRequest()
            await entry.request()
            let current = await entry.read()
            guard !stopped, revision == self.revision else { return }
            publish(current, for: entry.id)
        case .settings:
            selected = entry.id
            openSettings(entry)
        case .checking, .allowed, .restricted: break
        }
    }

    func setVisible(_ value: Bool) {
        if visible != value { visible = value }
    }

    func stop() {
        stopped = true
        revision += 1
        setVisible(false)
    }

}

enum MacPermissionGuidePlacement {
    /// Window-server coordinates start at the primary screen's top left; AppKit's
    /// global coordinates start at its bottom left, including on secondary displays.
    static func appKitFrame(_ bounds: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryTop - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// Stay beside the settings controls. If neither side fits, leave Settings
    /// unobstructed rather than covering it with a floating guide.
    static func frame(beside settings: CGRect, size: CGSize, visible: CGRect) -> CGRect? {
        let y = min(max(settings.maxY - size.height, visible.minY), visible.maxY - size.height)
        guard size.height <= visible.height else { return nil }
        for x in [settings.maxX + 12, settings.minX - size.width - 12] {
            let candidate = CGRect(origin: CGPoint(x: x, y: y), size: size)
            if visible.contains(candidate) { return candidate }
        }
        return nil
    }
}

enum MacPermissionFollowSchedule {
    static func shouldRead(now: TimeInterval, lastRead: TimeInterval,
                           hasWindow: Bool, recentInput: Bool) -> Bool {
        hasWindow && recentInput || now - lastRead >= 0.25
    }
}

private actor MacSettingsWindowReader {
    func bounds(pid: pid_t, windowID: CGWindowID?) -> (CGWindowID, CGRect)? {
        guard !Task.isCancelled else { return nil }
        let options: CGWindowListOption = windowID == nil ? [.optionOnScreenOnly, .excludeDesktopElements] : .optionIncludingWindow
        guard let windows = CGWindowListCopyWindowInfo(options, windowID ?? kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.compactMap { item -> (CGWindowID, CGRect)? in
            guard item[kCGWindowOwnerPID as String] as? Int32 == pid,
                  item[kCGWindowLayer as String] as? Int == 0,
                  item[kCGWindowIsOnscreen as String] as? Bool == true,
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = item[kCGWindowNumber as String] as? CGWindowID,
                  let dictionary = item[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  frame.width >= 300, frame.height >= 300 else { return nil }
            return (id, frame)
        }.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
    }
}

/// A normal AppKit panel owned by Banana. It observes only Settings' public window
/// metadata; it never moves another app, captures its contents, or injects input.
@MainActor
final class MacPermissionGuide: NSObject, NSWindowDelegate {
    static let shared = MacPermissionGuide()
    private var panel: NSPanel?
    private var model: MacPermissionGuideModel?
    private var displayLink: CADisplayLink?
    private var refreshTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private let reader = MacSettingsWindowReader()
    private var settingsWindowID: CGWindowID?
    private var settingsPID: pid_t?
    private var generation = 0
    private var lastWindowRead: TimeInterval = -.infinity

    func show(entries: [MacPermissionEntry], selected: SystemSettingsLink? = nil) {
        close()
        let model = MacPermissionGuideModel(entries: entries)
        model.selected = selected
        self.model = model
        model.openSettings = { [weak self] entry in self?.open(entry) }
        model.prepareRequest = { NSApp.activate() }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 330, height: min(340 + CGFloat(entries.count) * 54, NSScreen.main?.visibleFrame.height ?? 700)),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Permissions"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.delegate = self
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Banana"
        panel.contentView = NSHostingView(rootView: MacPermissionGuideView(
            model: model, appName: appName, appIcon: NSApp.applicationIconImage))
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        model.setVisible(true)
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.updateVisibility() } }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in
            guard let self else { return }
            self.displayLink?.invalidate()
            self.displayLink = nil
            if self.model?.selected != nil { self.startFollowing(); self.updateVisibility() }
        } }
        refreshTask = Task { [weak model] in
            while !Task.isCancelled {
                guard let model else { return }
                if model.visible { Task { await model.refresh() } }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        if let selected, let entry = entries.first(where: { $0.id == selected }) { open(entry) }
    }

    private func open(_ entry: MacPermissionEntry) {
        model?.selected = entry.id
        settingsWindowID = nil
        lastWindowRead = -.infinity
        panel?.orderOut(nil)
        model?.setVisible(false)
        if NSWorkspace.shared.open(entry.id.url) { startFollowing() }
        else {
            model?.error = "System Settings couldn’t open. Try Open Settings again."
            panel?.orderFront(nil)
            model?.setVisible(true)
        }
    }

    private func startFollowing() {
        guard displayLink == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(followSettings))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func updateVisibility() {
        guard let panel, let model else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let visible = frontmost == Bundle.main.bundleIdentifier || frontmost == "com.apple.systempreferences"
        if frontmost == "com.apple.systempreferences", model.selected != nil {
            lastWindowRead = -.infinity
            startFollowing()
            displayLink?.isPaused = false
        } else {
            model.setVisible(visible)
            if visible { panel.orderFront(nil) } else { panel.orderOut(nil) }
            displayLink?.isPaused = true
        }
        Task { [weak model] in await model?.refresh() }
    }

    @objc private func followSettings() {
        guard readTask == nil, model?.selected != nil,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return }
        if settingsPID != app.processIdentifier { settingsPID = app.processIdentifier; settingsWindowID = nil }
        let now = ProcessInfo.processInfo.systemUptime
        let recentInput = CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp) < 0.5
            || CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 0.5
        guard MacPermissionFollowSchedule.shouldRead(now: now, lastRead: lastWindowRead,
            hasWindow: settingsWindowID != nil, recentInput: recentInput) else { return }
        lastWindowRead = now
        let generation = generation
        let pid = app.processIdentifier
        let windowID = settingsWindowID
        readTask = Task { [weak self] in
            guard let self else { return }
            let found = await reader.bounds(pid: pid, windowID: windowID)
            guard !Task.isCancelled, generation == self.generation else { return }
            self.readTask = nil
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" else { return }
            guard let (id, bounds) = found, let panel = self.panel else {
                self.settingsWindowID = nil
                self.panel?.orderOut(nil)
                self.model?.setVisible(false)
                return
            }
            self.settingsWindowID = id
            let frame = MacPermissionGuidePlacement.appKitFrame(bounds, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
            guard let screen = NSScreen.screens.max(by: {
                $0.frame.intersection(frame).area < $1.frame.intersection(frame).area
            }), let placement = MacPermissionGuidePlacement.frame(beside: frame, size: panel.frame.size, visible: screen.visibleFrame) else {
                panel.orderOut(nil)
                self.model?.setVisible(false)
                return
            }
            if panel.frame != placement { panel.setFrame(placement, display: true) }
            if !panel.isVisible { panel.orderFront(nil) }
            self.model?.setVisible(true)
        }
    }

    func windowWillClose(_ notification: Notification) { close() }

    func close() {
        generation += 1
        refreshTask?.cancel(); refreshTask = nil
        readTask?.cancel(); readTask = nil
        displayLink?.invalidate(); displayLink = nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        model?.stop()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
        settingsWindowID = nil
        settingsPID = nil
        lastWindowRead = -.infinity
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

struct MacPermissionGuideView: View {
    @ObservedObject var model: MacPermissionGuideModel
    let appName: String
    let appIcon: NSImage

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(nsImage: appIcon)
                    .resizable().frame(width: 48, height: 48).accessibilityHidden(true)
                ForEach(model.entries) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.symbol).frame(width: 22)
                        Text(entry.title)
                        Spacer(minLength: 8)
                        let status = model.states[entry.id]
                        if status == .allowed {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel("Allowed")
                        } else if status == .restricted {
                            Text("Restricted").foregroundStyle(.secondary)
                        } else if status == nil || status == .checking || model.busy == entry.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(status == .settings ? "Open Settings" : "Allow") {
                                Task { await model.activate(entry) }
                            }
                            .disabled(model.busy != nil)
                            .accessibilityIdentifier("mac.permissions.allow.\(entry.title)")
                        }
                    }
                    .padding(10)
                    .background(model.selected == entry.id ? Color.accentColor.opacity(0.08) : .clear, in: .rect(cornerRadius: 10))
                }
                if let entry = model.entries.first(where: { $0.id == model.selected }), model.states[entry.id] == .settings {
                    Text(entry.id == .photos ? "Choose Full Access for \(appName) in Photos." : "Turn on \(appName) in \(entry.title).")
                        .font(.callout).multilineTextAlignment(.center)
                    MacPermissionExample(appName: appName, permission: entry.id, visible: model.visible)
                }
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
            }
            .padding(20)
        }
        .frame(width: 330)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background)
        .accessibilityIdentifier("mac.permissions.guide")
    }
}

/// A local illustration, never an operating-system grant or a synthetic mouse event.
private struct MacPermissionExample: View {
    let appName: String
    let permission: SystemSettingsLink
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if visible && !reduceMotion {
                PhaseAnimator([false, true]) { on in row(on: on) }
                    animation: { on in .easeInOut(duration: on ? 1.2 : 1) }
            } else { row(on: true) }
        }
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: 8))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func row(on: Bool) -> some View {
        HStack {
            Text(appName)
            Spacer()
            Image(systemName: "cursorarrow.click").scaleEffect(on ? 0.9 : 1)
            if permission == .photos {
                Text(on ? "Full Access" : "No Access").font(.caption)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            } else {
                Toggle("", isOn: .constant(on)).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}
#endif
