import UIKit
import os.signpost

/// Optional manual/XCTest entry point for real touch input in the isolated prototype.
/// Signposts delimit handler work only; they do not claim display delivery or input latency.
@MainActor
final class InteractiveControls: UIStackView {
    private static let log = OSLog(subsystem: "com.boris.banana.calendar-library-benchmark", category: .pointsOfInterest)
    init(heading: UILabel, previous: @escaping () -> Void, next: @escaping () -> Void,
         clear: @escaping () -> Void) {
        super.init(frame: .zero)
        axis = .horizontal; spacing = 4
        func button(_ title: String, _ identifier: String, name: StaticString,
                    action: @escaping () -> Void) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.accessibilityIdentifier = identifier
            button.addAction(UIAction { _ in
                let id = OSSignpostID(log: Self.log)
                os_signpost(.begin, log: Self.log, name: name, signpostID: id)
                action()
                os_signpost(.end, log: Self.log, name: name, signpostID: id)
            }, for: .touchUpInside)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            return button
        }
        addArrangedSubview(button("Earlier", "benchmark.previous", name: "Previous page", action: previous))
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heading.accessibilityIdentifier = "benchmark.date"
        addArrangedSubview(heading)
        addArrangedSubview(button("Later", "benchmark.next", name: "Next page", action: next))
        addArrangedSubview(button("Clear cache", "benchmark.clearCache", name: "Clear cache", action: clear))
    }
    required init(coder: NSCoder) { fatalError("Programmatic benchmark") }
}
