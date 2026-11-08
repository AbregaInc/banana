import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What the page in front adds to a report: ids that always go, and content (an email, an
/// answer) that goes only while its row is on.
struct ProblemReportPageContext {
    enum Row: Equatable {
        /// A switch: the email, which is his. On by default in the Beta only.
        case toggle(String, defaultOn: Bool)
        /// Always sent, named so he sees it.
        case fixed(String)
    }
    var row: Row
    var context: [String: ProblemReport.Value] = [:]
    /// Read when the report is sent, off the main thread where it can be.
    var attachments: @Sendable () async -> [ProblemReport.Attachment] = { [] }
}

/// One report being written.
struct ProblemReportDraft: Identifiable {
    let id = UUID()
    var page: String
    var screenshot: PlatformImage?
    var pageContext: ProblemReportPageContext?
    var note = ""
    var includeScreenshot = true
    var includePage = true
}

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

/// Report a problem (docs/design/PROBLEM-REPORTS.md): the one way in on every platform, whether
/// shaken, chosen from "…", ⌘⇧R or Help, or a 👎 on an answer. Takes the screenshot before the
/// sheet covers the screen, asks the page in front what it adds, and presents the sheet over
/// whatever is showing, another sheet included.
@MainActor
final class ProblemReportCenter: ObservableObject {
    static let shared = ProblemReportCenter()

    /// What each page adds, set while it shows: the mail reader, the assistant, the calendar.
    private var providers: [String: (owner: ObjectIdentifier?, make: () -> ProblemReportPageContext?)] = [:]

    /// `owner` is the view's model: a page that disappears after the next one appeared (a new
    /// conversation in the reader) withdraws only its own.
    func provide(_ page: AppSection, owner: ObjectIdentifier? = nil, _ provider: @escaping () -> ProblemReportPageContext?) {
        providers[page.rawValue] = (owner, provider)
    }

    func withdraw(_ page: AppSection, owner: ObjectIdentifier? = nil) {
        guard providers[page.rawValue]?.owner == owner else { return }
        providers[page.rawValue] = nil
    }

    /// The calendar's days in view and the events on them, kept as the grid changes its days.
    /// A value and a closure: nothing is read until a report asks.
    func noteCalendar(start: Date?, end: Date?, ids: [String]) {
        guard let start, let end else { return }
        provide(.plan) {
            ProblemReportPageContext(row: .fixed("Days shown"), context: [
                "start": .text(start.ISO8601Format()), "end": .text(end.ISO8601Format()),
                "ids": .list(Array(ids.prefix(200))),
            ])
        }
    }

    #if os(iOS)
    private weak var presented: UIViewController?
    #else
    private var presented: NSWindow?
    #endif

    /// Opens the sheet for the page in front, or with the context given (a 👎 on one answer).
    func open(context: ProblemReportPageContext? = nil, page: AppSection? = nil) {
        guard presented == nil else { return }
        let name = page?.rawValue ?? ProblemReporter.page
        let began = DispatchTime.now().uptimeNanoseconds
        let screenshot = Self.captureScreen()
        let captured = DispatchTime.now().uptimeNanoseconds
        var draft = ProblemReportDraft(page: name, screenshot: screenshot,
                                       pageContext: context ?? providers[name]?.make())
        if case .toggle(_, let on)? = draft.pageContext?.row { draft.includePage = on }
        present(draft)
        // Opening is a UI response (docs/performance): its cost goes in the journal.
        let done = DispatchTime.now().uptimeNanoseconds
        PlaybackDiagnostics.shared.log("📝 report opened",
            "page=\(name) screenshot=\((captured - began) / 1_000_000)ms total=\((done - began) / 1_000_000)ms")
    }

    func send(_ draft: ProblemReportDraft) {
        dismiss()
        let page = draft.page
        let note = draft.note
        let screenshot = draft.includeScreenshot ? draft.screenshot : nil
        let pageContext = draft.pageContext
        let includePage = draft.includePage
        Task.detached(priority: .userInitiated) {
            var report = ProblemReport(kind: .problem, page: page, note: note)
            report.context = pageContext?.context ?? [:]
            if let screenshot, let jpeg = Self.jpeg(screenshot) {
                report.attachments.append(ProblemReport.Attachment(name: .screenshot, type: "image/jpeg", data: jpeg))
            }
            if let pageContext, includePage { report.attachments += await pageContext.attachments() }
            report.context["included"] = .flag(includePage)
            let finished = report
            await MainActor.run { ProblemReporter.shared.send(finished) }
        }
        ToastCenter.shared.notify("Report sent")
    }

    func dismiss() {
        #if os(iOS)
        presented?.dismiss(animated: true)
        #else
        if let sheet = presented {
            if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
        }
        #endif
        presented = nil
    }

    // MARK: - Presenting over whatever shows

    private func present(_ draft: ProblemReportDraft) {
        let sheet = ProblemReportSheet(draft: draft, send: { [weak self] in self?.send($0) },
                                       cancel: { [weak self] in self?.dismiss() })
        #if os(iOS)
        guard let top = Self.topController() else { return }
        let host = UIHostingController(rootView: sheet)
        host.modalPresentationStyle = .formSheet
        host.presentationController?.delegate = Coordinator.shared
        top.present(host, animated: true)
        presented = host
        #else
        guard var parent = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        while let attached = parent.attachedSheet { parent = attached }
        let window = NSWindow(contentViewController: NSHostingController(rootView: sheet.frame(width: 440)))
        window.title = "Report a Problem"
        parent.beginSheet(window)
        presented = window
        #endif
    }

    #if os(iOS)
    /// Swiping the sheet away is a cancel.
    private final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        static let shared = Coordinator()
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            MainActor.assumeIsolated { ProblemReportCenter.shared.presented = nil }
        }
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        return (active.isEmpty ? scenes : active).flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
    }

    private static func topController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
    #endif

    // MARK: - The screenshot

    /// The screen as it is, before the sheet covers it. Nil when nothing can be drawn.
    static func captureScreen() -> PlatformImage? {
        #if os(iOS)
        guard let window = keyWindow() else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(2, window.traitCollection.displayScale)
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        #else
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
        #endif
    }

    /// JPEG at a size that reads text and stays under the service's 3 MB.
    nonisolated static func jpeg(_ image: PlatformImage) -> Data? {
        #if os(iOS)
        return image.jpegData(compressionQuality: 0.6)
        #else
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        #endif
    }
}

#if os(iOS)
extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

extension UIWindow {
    /// A shake opens Report a problem, unless something is being typed (where a shake is Undo).
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        guard motion == .motionShake else { return }
        NotificationCenter.default.post(name: .deviceDidShake, object: nil)
    }
}

private final class FirstResponderProbe: NSObject {
    nonisolated(unsafe) static weak var found: UIResponder?
}

extension UIResponder {
    @objc fileprivate func reportProbeFirstResponder(_ sender: Any?) { FirstResponderProbe.found = self }

    /// Whether text is being typed somewhere: a shake there is the system's Undo.
    @MainActor static var isTyping: Bool {
        FirstResponderProbe.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.reportProbeFirstResponder(_:)), to: nil, from: nil, for: nil)
        return FirstResponderProbe.found is UITextInput
    }
}
#endif

/// Installs the ways in that aren't a menu item: the shake, and the screenshot route.
struct ProblemReporting: ViewModifier {
    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                guard !UIResponder.isTyping else { return }
                ProblemReportCenter.shared.open()
            }
            #endif
            #if DEBUG
            .task {
                // `--report-problem`: opens the sheet once the screen has drawn (screenshots, UI tests).
                guard ProcessInfo.processInfo.arguments.contains("--report-problem") else { return }
                try? await Task.sleep(for: .seconds(2))
                ProblemReportCenter.shared.open()
            }
            #endif
    }
}

extension View {
    func problemReporting() -> some View { modifier(ProblemReporting()) }
}

/// "Report a problem" in a "…" menu.
struct ReportProblemMenuItem: View {
    var body: some View {
        Button { ProblemReportCenter.shared.open() } label: {
            Label("Report a Problem", systemImage: "exclamationmark.bubble")
        }
        .accessibilityIdentifier("report.problem")
    }
}
