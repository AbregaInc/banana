#if STRESS_DEVICE_AUDIT && os(iOS) && !BANANA_PUBLIC
import UIKit

/// Matches the physical XCTest recording to UIKit's touch clock in the isolated app.
/// The colored squares stop changing before the measured input.
@MainActor
final class StressPresentationClock: UIView {
    enum Surface: String {
        case mail, calendar
        var requested: Bool {
            ProcessInfo.processInfo.arguments.contains("--stress-" + rawValue + "-presentation-clock")
        }
    }
    fileprivate var surface: Surface = .mail
    private var observer: StressPresentationTouch?
    fileprivate var contact: [[Double]] = []
    private static weak var installed: StressPresentationClock?
    private let squares = (0..<5).map { _ in CALayer() }
    private var pulses: [[Double]] = []
    private var link: CADisplayLink?
    fileprivate var down: TimeInterval?
    fileprivate var up: TimeInterval?
    private var selected: TimeInterval?

    static func attach(to list: UICollectionView, surface: Surface) {
        guard surface.requested, let window = list.window else { return }
        if let probe = installed, probe.window === window, probe.surface == surface {
            if let touch = probe.observer, touch.view !== list { list.addGestureRecognizer(touch) }
            return
        }
        let probe = StressPresentationClock(frame: .zero)
        probe.surface = surface
        probe.isUserInteractionEnabled = false
        probe.isAccessibilityElement = true
        probe.accessibilityIdentifier = "stress." + surface.rawValue + ".presentationClock"
        probe.accessibilityLabel = "Presentation clock"
        probe.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(probe)
        NSLayoutConstraint.activate([
            probe.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -4),
            probe.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            probe.widthAnchor.constraint(equalToConstant: 40), probe.heightAnchor.constraint(equalToConstant: 8)
        ])
        for (index, square) in probe.squares.enumerated() {
            square.frame = CGRect(x: index * 8, y: 0, width: 8, height: 8)
            probe.layer.addSublayer(square)
        }
        let touch = StressPresentationTouch(target: nil, action: nil)
        probe.observer = touch
        touch.probe = probe
        touch.cancelsTouchesInView = false
        touch.delaysTouchesBegan = false
        touch.delaysTouchesEnded = false
        list.addGestureRecognizer(touch)
        installed = probe
        let link = CADisplayLink(target: probe, selector: #selector(probe.pulse(_:)))
        probe.link = link
        link.add(to: .main, forMode: .common)
    }

    static func recordSelection() {
        guard let probe = installed, probe.surface == .mail, probe.selected == nil else { return }
        probe.selected = CACurrentMediaTime()
    }

    @objc private func pulse(_ link: CADisplayLink) {
        let target = link.targetTimestamp
        guard let window else { link.invalidate(); self.link = nil; return }
        guard !bounds.isEmpty, window.isKeyWindow,
              target - (pulses.last?[1] ?? 0) >= 0.16 else { return }
        let code = pulses.count
        let colors: [UIColor] = [.magenta] + (0..<3).map { (code & (1 << $0)) == 0 ? .black : .white } + [.cyan]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (square, color) in zip(squares, colors) { square.backgroundColor = color.cgColor }
        CATransaction.commit()
        pulses.append([Double(code), target, CACurrentMediaTime()])
        if pulses.count == 8 { link.invalidate(); self.link = nil }
    }

    override var accessibilityValue: String? {
        get {
            guard let window else { return nil }
            let rect = convert(bounds, to: window)
            var value: [String: Any] = ["pulses": pulses, "ready": pulses.count == 8,
                                        "rect": [rect.minX, rect.minY, rect.width, rect.height],
                                        "window": [window.bounds.width, window.bounds.height]]
            value["down"] = down
            value["up"] = up
            value["selected"] = selected
            if surface == .mail { value["diskReads"] = MailDiskReaderFixture.reads }
            else { value["contact"] = contact }
            guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set { super.accessibilityValue = newValue }
    }
}

private final class StressPresentationTouch: UIGestureRecognizer {
    weak var probe: StressPresentationClock?
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
    private func sample(_ touch: UITouch, in probe: StressPresentationClock) {
        let point = touch.location(in: nil)
        probe.contact.append([touch.timestamp, point.x, point.y, CACurrentMediaTime()])
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let probe, let touch = touches.first else { return }
        if probe.surface == .calendar {
            probe.contact.removeAll(keepingCapacity: true)
            probe.down = touch.timestamp
            probe.up = nil
            sample(touch, in: probe)
        } else if probe.down == nil { probe.down = touch.timestamp }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let probe, probe.surface == .calendar, let touch = touches.first else { return }
        sample(touch, in: probe)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let probe, let touch = touches.first {
            if probe.surface == .calendar { sample(touch, in: probe) }
            if probe.up == nil { probe.up = touch.timestamp }
        }
        state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }
}

/// The synthetic inbox and row run the normal UI. This opt-in fixture serves the selected
/// message through the same compressed SQLite representation as a downloaded conversation.
@MainActor
enum MailDiskReaderFixture {
    private(set) static var reads: [[String: Double]] = []

    static func install(in source: MailFixtureSource, root: URL) async throws {
        let id = MailMessageID(account: MailFixtureConversations.account, message: "long-reader~1")
        precondition(source.bodies[id] != nil)
        let originalOnly = ProcessInfo.processInfo.arguments.contains("--stress-mail-original-only")
        let stores = try await Task.detached(priority: .userInitiated) {
            let stores = try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations())
            let html = "<html><body>" + (1...1200).map { section in
                "<p>Section \(section). The team <strong>reviewed</strong> the <a href='https://plan.example/calendar'>calendar</a> and travel arrangements.</p>"
            }.joined() + "</body></html>"
            let bytes = Data(html.utf8)
            let encoded = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let part = GmailPart(partId: "0", mimeType: "text/html", headers: [
                GmailHeader(name: "Content-Type", value: "text/html; charset=utf-8")
            ], body: GmailPartBody(size: bytes.count, data: encoded))
            let message = GmailMessage(id: id.message, threadId: "long-reader", labelIds: ["INBOX"], snippet: "Section 1.",
                                       historyId: 1, internalDate: 1000, sizeEstimate: bytes.count, payload: part)
            let blobs = MailBlobStore(stores: stores)
            try await blobs.put(message, account: id.account, extraction: MIMEStructure.extract(part), ftsRowID: 1, at: 1)
            if !originalOnly {
                let prepared = try await blobs.prepare(account: id.account, messageID: id.message, at: 2)
                precondition(prepared?.text.blocks.count == 1200)
            }
            return try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations())
        }.value
        reads.removeAll()
        source.diskFixtureBody = { wanted in
            guard wanted == id else { return nil }
            let began = CACurrentMediaTime()
            let blobs = MailBlobStore(stores: stores)
            do {
                var value = try await blobs.prepared(account: id.account, messageID: id.message)
                let hit = value != nil
                if value == nil { value = try await blobs.prepare(account: id.account, messageID: id.message, at: 3) }
                guard let value else { preconditionFailure("Missing synthetic disk body") }
                let ended = CACurrentMediaTime()
                reads.append(["began": began, "ended": ended, "preparedHit": hit ? 1 : 0,
                              "blocks": Double(value.text.blocks.count)])
                return value.body
            } catch { preconditionFailure("Could not read synthetic disk body: \(error)") }
        }
    }
}
#endif
