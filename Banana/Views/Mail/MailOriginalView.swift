#if !BANANA_PUBLIC
import SwiftUI
import WebKit

/// One web view, created only when Original is opened. The native reader stays intact.
struct MailOriginalSheet: View {
    let load: () async throws -> String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var fragment: String?
    @State private var failed = false
    @State private var remoteImages = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if let fragment {
                    MailHTMLWebView(document: MailOriginalDocument.page(fragment, remoteImages: remoteImages), open: { url in
                        openURL(url)
                    })
                } else if failed {
                    ContentUnavailableView {
                        Label("Original unavailable", systemImage: "envelope.badge")
                    } actions: {
                        Button("Retry") { attempt += 1 }
                    }
                } else { ProgressView() }
            }
            .navigationTitle("Original")
            .toolbar {
                SheetClose { dismiss() }
                ToolbarItem(placement: .automatic) {
                    if fragment != nil && !remoteImages {
                        Button("Load images") { remoteImages = true }
                    }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 400)
        .task(id: attempt) {
            failed = false
            do {
                let value = try await load()
                guard !Task.isCancelled else { return }
                fragment = value; failed = value == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

@MainActor private final class MailOriginalNavigation: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var open: (URL) -> Void
    var document: String?
    var height: ((CGFloat) -> Void)?
    var resource: ((URL) async -> MailResource?)?
    init(open: @escaping (URL) -> Void) { self.open = open }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? Double, value.isFinite, value > 0 else { return }
        height?(min(20_000, max(44, ceil(value))))
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated {
            if let url = MailBodyHTML.safeLink(action.request.url) { open(url) }
            decisionHandler(.cancel)
        } else {
            decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}

@MainActor private struct MailHTMLWebView {
    let document: String
    let open: (URL) -> Void
    var height: ((CGFloat) -> Void)? = nil
    var resource: ((URL) async -> MailResource?)? = nil
    var scrolls = true
    func makeCoordinator() -> MailOriginalNavigation { MailOriginalNavigation(open: open) }
    func makeWebView(_ coordinator: MailOriginalNavigation) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        if height != nil {
            // App-owned code in an isolated world measures layout; message scripts remain disabled.
            let script = """
            (()=>{const report=()=>window.webkit.messageHandlers.mailHeight.postMessage(Math.ceil(document.documentElement.getBoundingClientRect().height));new ResizeObserver(report).observe(document.documentElement);report()})();
            """
            config.userContentController.add(coordinator, contentWorld: .defaultClient, name: "mailHeight")
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                forMainFrameOnly: true, in: .defaultClient))
        }
        let images = MailHTMLImages()
        images.resolve = { [weak coordinator] url in await coordinator?.resource?(url) }
        config.setURLSchemeHandler(images, forURLScheme: "banana-mail-image")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = coordinator
        return view
    }
    func update(_ view: WKWebView, coordinator: MailOriginalNavigation) {
        coordinator.open = open
        coordinator.height = height
        coordinator.resource = resource
        #if os(iOS)
        view.scrollView.isScrollEnabled = scrolls
        view.isOpaque = false
        view.backgroundColor = .white
        #endif
        guard coordinator.document != document else { return }
        coordinator.document = document
        view.loadHTMLString(document, baseURL: nil)
    }
}
#if os(iOS)
extension MailHTMLWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
}
#else
extension MailHTMLWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
}
#endif

@MainActor private final class MailHTMLImages: NSObject, WKURLSchemeHandler {
    var resolve: ((URL) async -> MailResource?)?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        tasks[key] = Task { [weak self] in
            defer { self?.tasks[key] = nil }
            guard let url = urlSchemeTask.request.url, let value = await self?.resolve?(url), !Task.isCancelled else {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)) }
                return
            }
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: value.mimeType,
                expectedContentLength: value.data.count, textEncodingName: nil))
            urlSchemeTask.didReceive(value.data)
            urlSchemeTask.didFinish()
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}

/// Visible message layouts share a bounded number of WebKit instances per conversation.
@MainActor final class MailHTMLSlots: ObservableObject {
    @Published private(set) var messages: [MailMessageID] = []
    func show(_ id: MailMessageID) {
        var next = messages.filter { $0 != id }
        next.append(id)
        if next.count > MailTuning.maxOpenDesignedBodies { next.removeFirst() }
        if next != messages { messages = next }
    }
    func hide(_ id: MailMessageID) {
        guard messages.contains(id) else { return }
        messages = messages.filter { $0 != id }
    }
}

struct MailFormattedBody<Fallback: View>: View {
    let id: MailMessageID
    let source: any MailSource
    @ViewBuilder var fallback: () -> Fallback
    @EnvironmentObject private var slots: MailHTMLSlots
    @Environment(\.openURL) private var openURL
    @State private var fragment: String?
    @State private var height: CGFloat = 160
    @State private var remoteImages = false
    @State private var visible = false
    @State private var simplified = false
    @State private var failed = false
    @State private var attempt = 0
    private var active: Bool { visible && !simplified && slots.messages.contains(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if active, let fragment {
                MailHTMLWebView(document: MailOriginalDocument.page(fragment, remoteImages: remoteImages, embedded: true),
                    open: { openURL($0) }, height: { value in
                        if abs(height - value) >= 1 { height = value }
                    }, resource: { url in
                        guard url.scheme == "banana-mail-image", url.host == "message",
                              let raw = url.path.dropFirst().removingPercentEncoding,
                              let escaped = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                              let cid = URL(string: "cid:" + escaped) else { return nil }
                        return await source.resource(cid, for: id, presentation: .onScreen)
                    }, scrolls: height >= 20_000)
                    .frame(height: height)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                    .accessibilityIdentifier("mail.body.html." + id.message)
                Button("Simplify message") { simplified = true; slots.hide(id) }
                    .accessibilityIdentifier("mail.body.simplify." + id.message)
                if !remoteImages && (fragment.contains("src=\"https://") || fragment.contains("url(")) {
                    Button("Load images") { remoteImages = true }
                        .accessibilityIdentifier("mail.body.images." + id.message)
                }
            } else {
                fallback()
                if visible && (!active || failed) {
                    Button("Show formatted message") { simplified = false; slots.show(id); attempt += 1 }
                        .accessibilityIdentifier("mail.body.format." + id.message)
                }
            }
        }
        .onAppear { visible = true; if !simplified { slots.show(id) } }
        .onDisappear { visible = false; slots.hide(id); fragment = nil }
        .task(id: active ? attempt : nil) {
            guard active else { fragment = nil; return }
            failed = false
            do {
                let value = try await source.originalHTML(id)
                guard !Task.isCancelled else { return }
                fragment = value; failed = value == nil
            } catch { if !Task.isCancelled { fragment = nil; failed = true } }
        }
    }
}
#endif
