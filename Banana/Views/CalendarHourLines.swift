import SwiftUI

/// Decorative grid only. Interactive events and their accessibility remain separate.
/// Apple recommends Canvas for noninteractive drawings; adoption is gated by pixel and UI tests.
struct CalendarHourLines: View {
    let hourHeight: CGFloat
    let hourColor: Color
    let halfHourColor: Color
    let usesCanvas: Bool

    static let experimentalCanvasEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--calendar-canvas-grid")
        #else
        false
        #endif
    }()

    var body: some View {
        Group {
            if usesCanvas {
                Canvas { context, size in
                    var hours = Path(), halves = Path()
                    for hour in 0...24 {
                        hours.addRect(CGRect(x: 0, y: CGFloat(hour) * hourHeight, width: size.width, height: 1))
                    }
                    for hour in 0..<24 {
                        halves.addRect(CGRect(x: 0, y: (CGFloat(hour) + 0.5) * hourHeight, width: size.width, height: 1))
                    }
                    context.fill(hours, with: .color(hourColor))
                    context.fill(halves, with: .color(halfHourColor))
                }
            } else {
                ZStack(alignment: .topLeading) {
                    ForEach(0...24, id: \.self) { hour in
                        Rectangle().fill(hourColor).frame(height: 1)
                            .offset(y: CGFloat(hour) * hourHeight)
                    }
                    ForEach(0..<24, id: \.self) { hour in
                        Rectangle().fill(halfHourColor).frame(height: 1)
                            .offset(y: (CGFloat(hour) + 0.5) * hourHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
