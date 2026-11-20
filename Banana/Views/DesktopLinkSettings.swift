#if BANANA_AI && BANANA_BETA && !PI_DEVELOPMENT && !BANANA_DEVELOPMENT
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct DesktopLinkSettings: View {
    @ObservedObject private var link = DesktopAssistantLink.shared
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    #if os(iOS)
    @State private var code = ""
    @State private var address = ""
    @State private var waiting = false
    #else
    @State private var copied = false
    @ObservedObject private var model = LocalModel.shared
    #endif

    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                Section("Share this Mac’s model") {
                    if let code = link.pairingCode {
                        LabeledContent("Status", value: link.status)
                        LabeledContent("Model", value: model.statusLine)
                        Button(copied ? "Copied" : "Copy pairing code") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(code, forType: .string)
                        }
                        if !link.hosting {
                            Button("Try again") { link.startHosting() }
                        }
                        Button("Turn off and revoke pairing", role: .destructive) { update { try link.forget() } }
                    } else {
                        Button("Enable desktop link") { update { try link.enableHosting() } }
                    }
                }
                #else
                Section("Mac model") {
                    if link.isPaired {
                        if let route = link.route { LabeledContent("Connection", value: route.rawValue) }
                        if !link.status.isEmpty { Text(link.status) }
                        Button("Check connection") { run { _ = await link.model() } }
                            .disabled(waiting)
                        Button("Forget Mac", role: .destructive) { update { try link.forget() } }
                            .disabled(waiting)
                    } else {
                        SecureField("Pairing code", text: $code)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Connect to Mac") {
                            run {
                                try link.setTailscaleAddress(address)
                                try await link.pair(with: code)
                                code = ""
                                _ = await link.model()
                            }
                        }
                        .disabled(code.isEmpty || waiting)
                    }
                    if waiting { ProgressView("Connecting…") }
                }
                Section("Away from home") {
                    TextField("Mac’s Tailscale IPv4 address", text: $address)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                        .disabled(waiting)
                        .onChange(of: address) { _, _ in
                            if link.allowTailscale { link.allowTailscale = false }
                        }
                    Toggle("Allow Tailscale this session", isOn: Binding(
                        get: { link.allowTailscale },
                        set: { allow in
                            if !allow { link.allowTailscale = false; return }
                            update {
                                try link.setTailscaleAddress(address)
                                link.allowTailscale = !link.tailscaleAddress.isEmpty
                            }
                        }))
                    .disabled(address.isEmpty || waiting)
                }
                #endif
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            .navigationTitle("Desktop link")
            .toolbar { SheetClose { dismiss() } }
            #if os(iOS)
            .onAppear { address = link.tailscaleAddress }
            .interactiveDismissDisabled(waiting)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 300)
        #endif
    }

    private func update(_ operation: () throws -> Void) {
        error = nil
        do { try operation() }
        catch { self.error = error.localizedDescription }
    }

    #if os(iOS)
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        waiting = true
        error = nil
        Task {
            defer { waiting = false }
            do { try await operation() }
            catch { self.error = error.localizedDescription }
        }
    }
    #endif
}
#endif
