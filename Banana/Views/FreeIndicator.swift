import SwiftUI

/// The shared indicator for an event marked "Show As: Free".
///
/// These used to be dropped at ingest, so a dinner booked through a reservation service — which
/// is where transparent events overwhelmingly come from — simply never appeared, with nothing
/// anywhere to say why. They are shown now, and the indicator has to answer the obvious next
/// question: why does this one look different?
///
/// Hollow rather than filled, everywhere. A free event is on your day but is not holding the
/// slot, and an outline reads as exactly that against the solid blocks around it.
struct FreeBadge: View {
    var body: some View {
        Text("Free")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
            )
            .accessibilityLabel("Shown as free")
    }
}

extension View {
    /// Grid-block treatment for a free event: same tint, but dashed, so it reads as not occupying
    /// the slot at a glance across a week — where there is no room for the badge.
    @ViewBuilder
    func freeBlockTreatment(_ isFree: Bool, tint: Color, cornerRadius: CGFloat = 4) -> some View {
        overlay {
            if isFree {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        tint.opacity(0.85),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
            }
        }
    }
}
