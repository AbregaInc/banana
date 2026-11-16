import AppKit
import SwiftUI
import Combine
setbuf(__stdoutp, nil)
@MainActor final class FastState { var value = MacPermissionState.requestable }
var checks = 0
func check(_ value: Bool) { checks += 1; precondition(value) }
let visible = CGRect(x: 0, y: 0, width: 1500, height: 950)
let size = CGSize(width: 330, height: 500)
let settings = CGRect(x: 300, y: 100, width: 700, height: 700)
let right = MacPermissionGuidePlacement.frame(beside: settings, size: size, visible: visible)!
check(right.minX == 1012 && right.maxY == settings.maxY)
check(!right.intersects(settings) && visible.contains(right))
let leftSettings = settings.offsetBy(dx: 450, dy: 0)
let left = MacPermissionGuidePlacement.frame(beside: leftSettings, size: size, visible: visible)!
check(left.maxX == leftSettings.minX - 12)
check(visible.contains(left) && !left.intersects(leftSettings))
check(MacPermissionGuidePlacement.frame(beside: settings, size: size, visible: CGRect(x: 200, y: 0, width: 800, height: 950)) == nil)
check(MacPermissionGuidePlacement.frame(beside: settings, size: CGSize(width: 330, height: 1000), visible: visible) == nil)
for x in stride(from: -1800.0, through: 1800, by: 150) {
    let screen = visible.offsetBy(dx: x, dy: -1200)
    for y in stride(from: -1400.0, through: -300, by: 100) {
        let target = CGRect(x: x + 300, y: y, width: 700, height: 500)
        if let frame = MacPermissionGuidePlacement.frame(beside: target, size: size, visible: screen) {
            check(screen.contains(frame))
            check(!frame.intersects(target))
        }
    }
}
check(MacPermissionGuidePlacement.appKitFrame(CGRect(x: -1000, y: 1200, width: 700, height: 500), primaryTop: 1000)
      == CGRect(x: -1000, y: -700, width: 700, height: 500))
check(SystemSettingsLink.reminders.url.absoluteString.hasSuffix("?Privacy_Reminders"))
check(SystemSettingsLink.location.url.absoluteString.hasSuffix("?Privacy_LocationServices"))
check(SystemSettingsLink.music.url.absoluteString.hasSuffix("?Privacy_Media"))
check(SystemSettingsLink.photos.url.absoluteString.hasSuffix("?Privacy_Photos"))
// Controlled ablation: the frame-by-frame control asks 120 times per quiet
// second; the production schedule asks four. Active input keeps every frame.
for active in [false, true] {
    var lastRead = -Double.infinity
    var reads = 0
    for frame in 0..<120 {
        let now = Double(frame) / 120
        if MacPermissionFollowSchedule.shouldRead(now: now, lastRead: lastRead, hasWindow: true, recentInput: active) {
            reads += 1
            lastRead = now
        }
    }
    check(reads == (active ? 120 : 4))
}
check(MacPermissionFollowSchedule.shouldRead(now: 0, lastRead: -.infinity, hasWindow: false, recentInput: false))
check(!MacPermissionFollowSchedule.shouldRead(now: 0.1, lastRead: 0, hasWindow: false, recentInput: true))
var done = false
Task { @MainActor in
    var state = MacPermissionState.requestable
    var requests = 0
    var opened = 0
    let entry = MacPermissionEntry(id: .reminders, title: "Reminders", symbol: "checklist", read: { state }, request: { requests += 1; state = .settings })
    let model = MacPermissionGuideModel(entries: [entry])
    model.openSettings = { _ in opened += 1 }
    var publications = 0
    let subscription = model.$states.dropFirst().sink { _ in publications += 1 }
    await model.refresh()
    check(publications == 1)
    for _ in 0..<100 { await model.refresh() }
    check(publications == 1)
    await model.activate(entry)
    check(requests == 1 && opened == 0 && model.states[.reminders] == .settings)
    await model.activate(entry)
    check(requests == 1 && opened == 1 && model.selected == .reminders)
    state = .allowed
    await model.refresh()
    await model.activate(entry)
    check(requests == 1 && opened == 1 && model.states[.reminders] == .allowed)
    state = .restricted
    await model.activate(entry)
    check(requests == 1 && opened == 1 && model.states[.reminders] == .restricted)
    check(model.busy == nil)
    state = .checking
    await model.activate(entry)
    check(requests == 1 && opened == 1 && model.states[.reminders] == .checking)
    subscription.cancel()
    // A slow notification daemon cannot block another permission's refresh.
    var pending: CheckedContinuation<MacPermissionState, Never>?
    var slowReads = 0
    let fastState = FastState()
    let slow = MacPermissionEntry(id: .notifications, title: "Notifications", symbol: "bell", read: {
        slowReads += 1
        return await withCheckedContinuation { pending = $0 }
    }, request: {})
    let fast = MacPermissionEntry(id: .reminders, title: "Reminders", symbol: "checklist", read: { fastState.value }, request: {})
    let independent = MacPermissionGuideModel(entries: [slow, fast])
    let first = Task { await independent.refresh() }
    for _ in 0..<1000 { if pending != nil { break }; await Task.yield() }
    check(pending != nil)
    fastState.value = .allowed
    await independent.refresh()
    check(independent.states[.reminders] == .allowed && slowReads == 1)
    independent.stop()
    pending!.resume(returning: .settings)
    await first.value
    check(independent.states[.notifications] == nil)
    // An earlier refresh must not overwrite the result of a newer native request.
    var oldRead: CheckedContinuation<MacPermissionState, Never>?
    var readCount = 0
    var granted = false
    let changing = MacPermissionEntry(id: .location, title: "Location", symbol: "location", read: {
        readCount += 1
        if readCount == 1 { return await withCheckedContinuation { oldRead = $0 } }
        return granted ? .allowed : .requestable
    }, request: { granted = true })
    let race = MacPermissionGuideModel(entries: [changing])
    let stale = Task { await race.refresh() }
    for _ in 0..<1000 { if oldRead != nil { break }; await Task.yield() }
    check(oldRead != nil)
    await race.activate(changing)
    check(race.states[.location] == .allowed)
    oldRead!.resume(returning: .requestable)
    await stale.value
    check(race.states[.location] == .allowed)
    // Render the actual guide with injected state, without opening or focusing a window.
    state = .settings
    await model.refresh()
    var visibilityUpdates = 0
    let visibilitySubscription = model.$visible.dropFirst().sink { _ in visibilityUpdates += 1 }
    for _ in 0..<100 { model.setVisible(true) }
    check(visibilityUpdates == 1)
    visibilitySubscription.cancel()
    let host = NSHostingView(rootView: MacPermissionGuideView(model: model, appName: "Banana", appIcon: NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)!).preferredColorScheme(.light))
    host.appearance = NSAppearance(named: .aqua)
    host.frame = CGRect(x: 0, y: 0, width: 330, height: 500)
    host.layoutSubtreeIfNeeded()
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
    }
    check(host.fittingSize.width == 330)
    check((try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])).count) ?? 0 > 100)
    done = true
}
let deadline = Date(timeIntervalSinceNow: 15)
while !done && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001)) }
check(done)
print("\(checks) permission geometry/state/render checks passed; visible native lifecycle and physical timing unmeasured")
