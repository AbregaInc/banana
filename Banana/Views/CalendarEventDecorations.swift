import SwiftUI

/// An event on several calendars: one dot per calendar down its leading edge. On one calendar,
/// nothing: the block's fill already says which.
struct EventRibbons: View {
    let colors: [Color]
    var opacity: Double = 1
    var cornerRadius: CGFloat = 0

    var body: some View {
        if colors.count > 1 {
            VStack(spacing: DS.Space.hair) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color.opacity(opacity))
                        .frame(width: DS.Event.calendarDot, height: DS.Event.calendarDot)
                }
            }
            .padding(.leading, DS.Space.xs)
            .padding(.top, DS.Space.xs)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The glyph before the title when every other guest declined.
struct OthersDeclinedMark: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DS.Palette.accent)
            .help("Everyone else declined")
            .accessibilityLabel("Everyone else declined")
    }
}

/// Diagonal hatching for a tentative reply.
struct TentativeStripes: Shape {
    var spacing: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

extension View {
    @ViewBuilder
    func eventReplyTreatment(tentative: Bool, needsAction: Bool, tint: Color,
                             cornerRadius: CGFloat = 4) -> some View {
        if tentative {
            overlay {
                TentativeStripes()
                    .stroke(tint.opacity(DS.Tint.strong), lineWidth: 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
            }
        } else if needsAction {
            overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.85), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
    }
}
