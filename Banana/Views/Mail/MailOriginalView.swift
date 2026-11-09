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
                    MailOriginalWebView(document: MailOriginalDocument.page(fragment, remoteImages: remoteImages)) { url in
                        openURL(url)
                    }
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

private final class MailOriginalNavigation: NSObject, WKNavigationDelegate {
    var open: (URL) -> Void
    var document: String?
    init(open: @escaping (URL) -> Void) { self.open = open }
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

private struct MailOriginalWebView {
    let document: String
    let open: (URL) -> Void
    func makeCoordinator() -> MailOriginalNavigation { MailOriginalNavigation(open: open) }
    func makeWebView(_ coordinator: MailOriginalNavigation) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = coordinator
        return view
    }
    func update(_ view: WKWebView, coordinator: MailOriginalNavigation) {
        coordinator.open = open
        guard coordinator.document != document else { return }
        coordinator.document = document
        view.loadHTMLString(document, baseURL: nil)
    }
}
#if os(iOS)
extension MailOriginalWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
}
#else
extension MailOriginalWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
}
#endif
#endif
