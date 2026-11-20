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
    @State private var showingScanner = false
    @State private var requestingCamera = false
    #else
    @State private var copied = false
    @State private var showingQRCode = false
    @State private var qrImage: CGImage?
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
                        if let payload = link.pairingQRPayload {
                            DisclosureGroup("Pairing QR code", isExpanded: $showingQRCode) {
                                if let qrImage {
                                    Image(decorative: qrImage, scale: 1)
                                        .interpolation(.none)
                                        .resizable()
                                        .frame(width: 164, height: 164)
                                        .padding(20)
                                        .background(.white)
                                        .frame(maxWidth: .infinity)
                                        .accessibilityLabel("Desktop link QR code")
                                }
                            }
                            .task(id: showingQRCode ? payload : nil) {
                                qrImage = showingQRCode ? DesktopPairingQRCode.image(for: payload) : nil
                            }
                        }
                        Button(copied ? "Copied" : "Copy pairing code") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(code, forType: .string)
                        }
                        if !link.hosting {
                            Button("Try again") { link.startHosting() }
                        }
                        Button("Turn off and revoke pairing", role: .destructive) {
                            update {
                                try link.forget()
                                qrImage = nil
                                showingQRCode = false
                                copied = false
                            }
                        }
                    } else {
                        Button("Enable desktop link") {
                            update {
                                try link.enableHosting()
                                showingQRCode = true
                            }
                        }
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
                        if BarcodeScannerView.isSupported {
                            Button("Scan Mac QR code", systemImage: "qrcode.viewfinder") { openScanner() }
                                .disabled(waiting || requestingCamera)
                        }
                        SecureField("Pairing code", text: $code)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(waiting)
                        Button("Connect to Mac") {
                            connect(code)
                        }
                        .disabled(code.isEmpty || waiting || requestingCamera)
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
            .sheet(isPresented: $showingScanner) { scanner }
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
    private var scanner: some View {
        NavigationStack {
            BarcodeScannerView(
                onScan: { payload in
                    guard let pairing = DesktopPeerLink.Pairing(qrPayload: payload) else { return }
                    showingScanner = false
                    code = pairing.code
                    connect(code)
                },
                onError: { message in showingScanner = false; error = message },
                symbologies: [.qr],
                accepts: { DesktopPeerLink.Pairing(qrPayload: $0) != nil },
                accessibilityID: "assistant.desktopLink.scanner",
                unavailableMessage: "The camera scanner is unavailable. You can still enter the pairing code.")
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan the code on your Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { SheetClose { showingScanner = false } }
        }
    }

    private func openScanner() {
        requestingCamera = true
        error = nil
        Task {
            defer { requestingCamera = false }
            if await requestBarcodeCameraAccess() {
                showingScanner = true
            } else {
                error = "Allow camera access in Settings to scan, or enter the pairing code."
            }
        }
    }

    private func connect(_ pairingCode: String) {
        run {
            try link.setTailscaleAddress(address)
            try await link.pair(with: pairingCode)
            code = ""
            _ = await link.model()
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !waiting else { return }
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
