import Foundation
import Network
import Vision

@main
struct DesktopPeerLinkTest {
    @MainActor
    static func main() async throws {
        let pairing = DesktopPeerLink.Pairing()
        precondition(DesktopPeerLink.Pairing(code: pairing.code) == pairing)
        precondition(DesktopPeerLink.Pairing(code: "bad") == nil)
        let legacy = DesktopPeerLink.PairingQR(pairing: pairing, tailscaleAddress: nil)
        precondition(DesktopPeerLink.PairingQR(payload: legacy.payload)?.pairing == pairing)
        precondition(DesktopPeerLink.PairingQR(payload: legacy.payload)?.tailscaleAddress == nil)
        let qr = DesktopPeerLink.PairingQR(pairing: pairing, tailscaleAddress: "100.64.1.1")
        precondition(DesktopPeerLink.PairingQR(payload: qr.payload)?.pairing == pairing)
        precondition(DesktopPeerLink.PairingQR(payload: qr.payload)?.tailscaleAddress == "100.64.1.1")
        precondition(DesktopPeerLink.PairingQR(payload: pairing.code) == nil)
        precondition(DesktopPeerLink.PairingQR(payload: "https://example.org/" + pairing.code) == nil)
        precondition(DesktopPeerLink.PairingQR(payload: "BANANA-DESKTOP-LINK/2/" + pairing.code) == nil)
        precondition(DesktopPeerLink.PairingQR(payload: "BANANA-DESKTOP-LINK/2/" + pairing.code + ":192.0.2.1") == nil)
        guard let image = DesktopPairingQRCode.image(for: qr.payload) else {
            fatalError("Mac did not render the pairing code")
        }
        let scan = VNDetectBarcodesRequest()
        scan.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([scan])
        precondition(scan.results?.first?.payloadStringValue == qr.payload)
        precondition(DesktopPeerLink.tailnetEndpoint("100.64.1.1") != nil)
        precondition(DesktopPeerLink.tailnetEndpoint("100.127.255.254") != nil)
        for invalid in ["127.0.0.1", "100.63.1.1", "100.128.1.1", "example.org", "100.64.1.1:443"] {
            precondition(DesktopPeerLink.tailnetEndpoint(invalid) == nil)
        }

        let address = "100.64.1.1"
        precondition(DesktopPeerLink.tailscaleFallback(address: address, preference: nil) == address)
        precondition(DesktopPeerLink.tailscaleFallback(address: address, preference: true) == address)
        precondition(DesktopPeerLink.tailscaleFallback(address: address, preference: false) == nil)
        precondition(DesktopPeerLink.tailscaleFallback(address: "", preference: true) == nil)
        precondition(DesktopPeerLink.tailscaleFallback(address: "192.0.2.1", preference: nil) == nil)

        let listener = try NWListener(using: pairing.parameters())
        defer { listener.cancel() }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            Task { @MainActor in
                defer { connection.cancel() }
                do {
                    let request = try await DesktopPeerLink.within(.seconds(3), connection: connection) {
                        try await DesktopPeerLink.read(DesktopPeerLink.Request.self, from: connection)
                    }
                    precondition(request.version == 1 && request.operation == "test.echo.v1")
                    try await DesktopPeerLink.send(DesktopPeerLink.Response(payload: request.payload, error: nil), to: connection)
                } catch {
                    // The wrong pairing never reaches the application protocol.
                }
            }
        }
        listener.start(queue: .main)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while (listener.port == nil || listener.port == .any) && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let port = listener.port, port != .any else { throw DesktopPeerLink.Failure.unavailable }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        print("Opening TLS connection")
        let client = try await DesktopPeerLink.open(endpoint, pairing: pairing, localOnly: false, timeout: .seconds(3))
        defer { client.cancel() }
        print("Exchanging framed request")
        let response = try await DesktopPeerLink.within(.seconds(3), connection: client) {
            try await DesktopPeerLink.send(DesktopPeerLink.Request("test.echo.v1", payload: "Test ✓"), to: client)
            return try await DesktopPeerLink.read(DesktopPeerLink.Response.self, from: client)
        }
        precondition(response.payload == "Test ✓" && response.error == nil)

        print("Checking rejected pairing")
        if let wrong = try? await DesktopPeerLink.open(endpoint, pairing: .init(), localOnly: false, timeout: .seconds(3)) {
            wrong.cancel()
            fatalError("Incorrect pairing authenticated")
        }

        print("Checking discovery cancellation")
        let cancelled = Task {
            try await DesktopPeerLink.discover(.init(), timeout: .seconds(10))
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("Cancelled discovery returned success")
        } catch is CancellationError {}

        print("Passed pairing validation, TLS frame round trip, incorrect key rejection, Tailnet address checks and discovery cancellation.")
    }
}
