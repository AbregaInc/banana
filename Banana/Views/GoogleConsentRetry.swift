import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Google's screen came back with boxes unticked: say which, why Banana needs them, and show what
/// to tick, then one tap opens Google's screen again. Shown by the sign-in itself, over whatever is
/// in front (a sheet, Settings, onboarding), the way Google's own screen is.
struct GoogleConsentRetryView: View {
    let missing: [GoogleScopes.Permission]
    let finish: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("Banana needs every box ticked")
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ForEach(missing) { permission in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                        Image(systemName: permission.symbol)
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.title).font(.headline)
                            Text(permission.reason).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            GoogleConsentIllustration(missing: Set(missing))
            Text("On Google’s screen, tick Select all.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Not now") { finish(false) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("consent-retry.later")
                Spacer()
                Button("Continue") { finish(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("consent-retry.again")
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: 440, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("consent-retry")
    }
}

/// A drawing of Google's permission list with every box ticked; the ones left unticked are
/// marked, so the person knows what to look for.
private struct GoogleConsentIllustration: View {
    let missing: Set<GoogleScopes.Permission>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(title: "Select all", symbol: nil, highlighted: true, bold: true)
            Divider()
            ForEach(GoogleScopes.permissions) { permission in
                row(title: permission.title, symbol: permission.symbol,
                    highlighted: missing.contains(permission), bold: false)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .background(.background, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.quaternary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Google’s screen with Select all and every permission ticked")
    }

    private func row(title: String, symbol: String?, highlighted: Bool, bold: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            }
            Text(title).font(bold ? .body.weight(.semibold) : .body)
            Spacer()
            Image(systemName: "checkmark.square.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(highlighted ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .padding(.horizontal, DS.Space.xs)
    }
}

/// Presents `GoogleConsentRetryView` over the front-most window and answers once it has gone, so
/// Google's screen can be shown straight after.
@MainActor
enum GoogleConsentRetry {
    /// True: open Google's screen again. False: carry on with what was granted.
    static func ask(_ missing: [GoogleScopes.Permission]) async -> Bool {
        #if os(iOS)
        guard let presenter = frontViewController() else { return false }
        return await withCheckedContinuation { continuation in
            var host: UIHostingController<GoogleConsentRetryView>?
            var answered = false
            let view = GoogleConsentRetryView(missing: missing) { again in
                guard !answered else { return }
                answered = true
                host?.dismiss(animated: true) { continuation.resume(returning: again) }
            }
            let controller = UIHostingController(rootView: view)
            controller.isModalInPresentation = true
            if let sheet = controller.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = false
            }
            host = controller
            presenter.present(controller, animated: true)
        }
        #elseif os(macOS)
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return false }
        return await withCheckedContinuation { continuation in
            var sheet: NSWindow?
            var answered = false
            let view = GoogleConsentRetryView(missing: missing) { again in
                guard !answered, let sheet else { return }
                answered = true
                window.endSheet(sheet)
                continuation.resume(returning: again)
            }
            let made = NSWindow(contentViewController: NSHostingController(rootView: view))
            made.styleMask = [.titled]
            sheet = made
            window.beginSheet(made)
        }
        #else
        return false
        #endif
    }

    #if os(iOS)
    private static func frontViewController() -> UIViewController? {
        var current = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        while let presented = current?.presentedViewController, !presented.isBeingDismissed { current = presented }
        return current
    }
    #endif
}

#if DEBUG
/// `--consent-retry-preview gmail,contacts`: the sheet over the app at launch, for screenshots.
enum GoogleConsentRetryPreview {
    static var requested: [GoogleScopes.Permission]? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--consent-retry-preview") else { return nil }
        let names = args.indices.contains(index + 1) ? args[index + 1].split(separator: ",").map(String.init) : []
        let chosen = names.compactMap(GoogleScopes.Permission.init(rawValue:))
        return chosen.isEmpty ? GoogleScopes.permissions : chosen
    }
}
#endif
