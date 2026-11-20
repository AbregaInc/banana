import Foundation
import Network

@main
struct DesktopPeerLinkTest {
    @MainActor
    static func main() async throws {
        let pairing = DesktopPeerLink.Pairing()
        precondition(DesktopPeerLink.Pairing(code: pairing.code) == pairing)
        precondition(DesktopPeerLink.Pairing(code: "bad") == nil)
        precondition(DesktopPeerLink.tailnetEndpoint("100.64.1.1") != nil)
        precondition(DesktopPeerLink.tailnetEndpoint("100.127.255.254") != nil)
        for invalid in ["127.0.0.1", "100.63.1.1", "100.128.1.1", "example.org", "100.64.1.1:443"] {
            precondition(DesktopPeerLink.tailnetEndpoint(invalid) == nil)
        }

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
