import SwiftUI

// The first run's pictures, placed in the accepted artwork's own coordinates
// (output/imagegen/onboarding-v12, each screen 1024 wide). A canvas shows one band of the art's
// height at the column's width; every shape, card and mascot below gives its corners in art
// pixels, so a page and its artwork line up when laid side by side. The mascot is a picture per
// page (Brand.xcassets, `Mascot…`), cut from that page's artwork with its pose and gaze; the
// rest is drawn here. The whole picture is one accessibility element: it illustrates, the words
// and controls around it say.

/// Art pixels to points, for one canvas.
struct ArtSpace {
    let scale: CGFloat
    let top: CGFloat
    /// How far past the canvas's sides a band may run, in art pixels.
    let bleed: CGFloat

    func x(_ value: CGFloat) -> CGFloat { value * scale }
    func y(_ value: CGFloat) -> CGFloat { (value - top) * scale }
    func point(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x(px), y: y(py)) }
    func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: x(x0), y: y(y0), width: (x1 - x0) * scale, height: (y1 - y0) * scale)
    }
    func length(_ value: CGFloat) -> CGFloat { value * scale }
    /// A rectangle inside something already placed, from that thing's corner.
    func local(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: x0 * scale, y: y0 * scale, width: (x1 - x0) * scale, height: (y1 - y0) * scale)
    }
    /// Type inside a picture follows the picture, not Dynamic Type: it is part of the drawing.
    func font(_ px: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: px * scale, weight: weight) }
}

/// One stretch of the artwork, from `top` to `bottom`, at the width it is given.
struct ArtCanvas<Content: View>: View {
    let top: CGFloat
    let bottom: CGFloat
    @ViewBuilder let content: (ArtSpace) -> Content
    @Environment(\.firstRunBleed) private var bleed
    @Environment(\.firstRunFullBleed) private var fullBleed

    var body: some View {
        canvas.padding(.horizontal, fullBleed ? -FirstRun.margin : 0)
    }

    private var canvas: some View {
        Color.clear
            .aspectRatio(FirstRun.artWidth / (bottom - top), contentMode: .fit)
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    let scale = proxy.size.width / FirstRun.artWidth
                    ZStack(alignment: .topLeading) {
                        content(ArtSpace(scale: scale, top: top, bleed: scale > 0 ? bleed / scale : 0))
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(true)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension View {
    /// Placed by its frame in a canvas.
    func placed(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }
}

// MARK: - Shared parts

/// The flat yellow band: a top and a bottom contour, each one cubic curve across the art, run
/// on past both sides of a column (`ArtSpace.bleed`).
struct BandShape: Shape {
    /// From x 0 to x 1024: start, two controls, end, in art pixels.
    let top: [CGPoint]
    /// From x 1024 back to x 0.
    let bottom: [CGPoint]
    let art: ArtSpace

    func path(in _: CGRect) -> Path {
        func p(_ point: CGPoint) -> CGPoint { art.point(point.x, point.y) }
        var path = Path()
        path.move(to: art.point(-art.bleed, top[0].y))
        path.addLine(to: p(top[0]))
        path.addCurve(to: p(top[3]), control1: p(top[1]), control2: p(top[2]))
        path.addLine(to: art.point(FirstRun.artWidth + art.bleed, top[3].y))
        path.addLine(to: art.point(FirstRun.artWidth + art.bleed, bottom[0].y))
        path.addLine(to: p(bottom[0]))
        path.addCurve(to: p(bottom[3]), control1: p(bottom[1]), control2: p(bottom[2]))
        path.addLine(to: art.point(-art.bleed, bottom[3].y))
        path.closeSubpath()
        return path
    }
}

/// Banana, as the page's artwork poses it: a fine ivory rim where it overlaps colour, and a
/// restrained shadow, as in the accepted welcome.
struct MascotPicture: View {
    let name: String
    let rect: CGRect
    var rim: CGFloat = 3

    var body: some View {
        // Always scaled as one: Banana is a rounded square (about 1:1, Brand/BananaMascotReference),
        // and a frame of another shape only leaves space around it, never stretches it.
        Image(name)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .background {
                Image(name)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(FirstRun.page)
                    .padding(-rim)
            }
            .shadow(color: .black.opacity(0.10), radius: 5, y: 3)
            .placed(rect)
    }
}

/// A calendar panel: a dot and a name, faint lines, and whatever blocks it holds.
struct CalendarPanel<Blocks: View>: View {
    let title: String
    let dot: Color
    let text: Color
    let art: ArtSpace
    let frame: CGRect
    @ViewBuilder let blocks: Blocks

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: art.length(24), style: .continuous)
                .fill(FirstRun.card)
                .overlay(RoundedRectangle(cornerRadius: art.length(24), style: .continuous).strokeBorder(FirstRun.cardLine, lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
            // Faint lines, like an hour grid.
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { _ in
                    Spacer(minLength: 0)
                    Rectangle().fill(FirstRun.grid).frame(height: 1)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, art.length(90))
            .padding(.horizontal, art.length(28))
            HStack(spacing: art.length(16)) {
                Circle().fill(dot).frame(width: art.length(34), height: art.length(34))
                Text(title).font(art.font(38)).foregroundStyle(text).lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.top, art.length(36))
            .padding(.horizontal, art.length(36))
            blocks
        }
        .placed(frame)
    }
}

/// A block in a panel, at art coordinates relative to the panel's corner.
struct PanelBlock: View {
    let art: ArtSpace
    let rect: CGRect
    var fill: Color? = nil
    var stroke: Color? = nil
    var title: String? = nil
    var detail: String? = nil
    var textColour: Color = FirstRun.ink

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: art.length(14), style: .continuous)
        ZStack(alignment: .leading) {
            if let fill { shape.fill(fill) }
            if let stroke { shape.strokeBorder(stroke, lineWidth: art.length(5)) }
            if let title {
                VStack(alignment: .leading, spacing: art.length(4)) {
                    Text(title).font(art.font(38))
                    if let detail { Text(detail).font(art.font(32)).monospacedDigit() }
                }
                .foregroundStyle(textColour)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, art.length(28))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }
}

// MARK: - The pages' pictures

/// Welcome: a day of three events on a card, Banana leaning in from the right and looking at it.
struct WelcomeScene: View {
    let art: ArtSpace

    var body: some View {
        BandShape(top: [CGPoint(x: 0, y: 525), CGPoint(x: 330, y: 432), CGPoint(x: 700, y: 440), CGPoint(x: 1024, y: 585)],
                  bottom: [CGPoint(x: 1024, y: 985), CGPoint(x: 820, y: 878), CGPoint(x: 330, y: 885), CGPoint(x: 0, y: 968)],
                  art: art)
            .fill(FirstRun.yellow)
        MascotPicture(name: "MascotWelcome", rect: art.rect(547, 455, 978, 895))
        let card = art.rect(110, 527, 578, 942)
        RoundedRectangle(cornerRadius: art.length(26), style: .continuous)
            .fill(FirstRun.card)
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            .placed(card)
        row("Team meeting", minutes: 9 * 60, colours: FirstRun.lilac, top: 548)
        row("Lunch", minutes: 12 * 60 + 30, colours: FirstRun.mint, top: 676)
        row("Time for you", minutes: 16 * 60, colours: FirstRun.coral, top: 804)
    }

    private func row(_ title: String, minutes: Int, colours: (fill: Color, dot: Color, text: Color, block: Color),
                     top: CGFloat) -> some View {
        HStack(spacing: art.length(18)) {
            Circle().fill(colours.dot).frame(width: art.length(38), height: art.length(38))
            Text(title).font(art.font(33)).foregroundStyle(colours.text).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: art.length(8))
            Text(DayClock.parts(minutes).time).font(art.font(31, .regular)).monospacedDigit()
                .foregroundStyle(FirstRun.ink)
        }
        .padding(.horizontal, art.length(24))
        .frame(width: art.length(424), height: art.length(115))
        .background(colours.fill, in: RoundedRectangle(cornerRadius: art.length(20), style: .continuous))
        .position(art.rect(132, top, 556, top + 115).center)
    }
}

/// What Banana looks after: Banana peeks in at the right, over a small yellow quarter, looking
/// down at the list.
struct ModulesScene: View {
    let art: ArtSpace

    var body: some View {
        // Cut at the art's right edge: the screen's on a phone, the column's in a window.
        ZStack(alignment: .topLeading) {
            Ellipse()
                .fill(FirstRun.yellow)
                .placed(art.rect(880, 420, 1174, 560))
            MascotPicture(name: "MascotModules", rect: art.rect(852, 281, 1017, 449))
        }
        .mask(alignment: .topLeading) { Rectangle().frame(width: art.length(1024), height: art.y(600)) }
    }
}

/// Wake: a flat sun rising, Banana beside it looking up at the time.
struct SunriseScene: View {
    let art: ArtSpace
    private let centre = CGPoint(x: 590, y: 1145)
    private let radius: CGFloat = 245

    var body: some View {
        ForEach([-144.0, -122.0, -100.0, -78.0, -56.0], id: \.self) { angle in
            let a = angle * .pi / 180
            Path { path in
                path.move(to: art.point(centre.x + cos(a) * 290, centre.y + sin(a) * 290))
                path.addLine(to: art.point(centre.x + cos(a) * 345, centre.y + sin(a) * 345))
            }
            .stroke(FirstRun.yellow, style: StrokeStyle(lineWidth: art.length(14), lineCap: .round))
        }
        Path { path in
            path.addArc(center: art.point(centre.x, centre.y), radius: art.length(radius),
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.closeSubpath()
        }
        .fill(FirstRun.yellow)
        MascotPicture(name: "MascotWake", rect: art.rect(50, 838, 410, 1198))
            .mask(alignment: .topLeading) {
                Rectangle().frame(width: art.length(1024), height: art.y(1150))
            }
    }
}

/// Wind down: a flat crescent moon and stars, Banana rising behind a lilac hill, looking up.
struct MoonriseScene: View {
    let art: ArtSpace

    var body: some View {
        // The crescent: a disc with a second disc taken out of it.
        Circle()
            .fill(FirstRun.lilacShape)
            .mask {
                ZStack {
                    Rectangle()
                    Circle().frame(width: art.length(300), height: art.length(300))
                        .offset(x: art.length(95), y: -art.length(70))
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .placed(art.rect(124, 780, 484, 1140))
        ForEach([(416.0, 843.0, 42.0), (344.0, 915.0, 30.0), (528.0, 960.0, 36.0)], id: \.0) { star in
            Image(systemName: "sparkle")
                .resizable()
                .scaledToFit()
                .foregroundStyle(FirstRun.lilacShape)
                .placed(art.rect(star.0 - star.2, star.1 - star.2, star.0 + star.2, star.1 + star.2))
        }
        MascotPicture(name: "MascotWindDown", rect: art.rect(679, 857, 915, 1097))
        BandShape(top: [CGPoint(x: 0, y: 1185), CGPoint(x: 300, y: 1040), CGPoint(x: 720, y: 1045), CGPoint(x: 1024, y: 1180)],
                  bottom: [CGPoint(x: 1024, y: 1250), CGPoint(x: 700, y: 1250), CGPoint(x: 300, y: 1250), CGPoint(x: 0, y: 1250)],
                  art: art)
            .fill(LinearGradient(stops: [.init(color: FirstRun.lilacShape, location: 0),
                                         .init(color: FirstRun.lilacShape, location: 0.8),
                                         .init(color: FirstRun.lilacShape.opacity(0), location: 1)],
                                 startPoint: .top, endPoint: .bottom))
    }
}

/// The calendar: two calendars, Work and Personal, Banana rising from the band beside them.
struct ConnectScene: View {
    let art: ArtSpace

    var body: some View {
        BandShape(top: [CGPoint(x: 0, y: 590), CGPoint(x: 250, y: 478), CGPoint(x: 600, y: 470), CGPoint(x: 1024, y: 640)],
                  bottom: [CGPoint(x: 1024, y: 968), CGPoint(x: 850, y: 878), CGPoint(x: 300, y: 900), CGPoint(x: 0, y: 975)],
                  art: art)
            .fill(FirstRun.yellow)
        MascotPicture(name: "MascotConnect", rect: art.rect(725, 585, 1025, 891))
        CalendarPanel(title: "Work", dot: FirstRun.lilac.dot, text: FirstRun.lilac.text, art: art,
                      frame: art.rect(58, 597, 398, 985)) {
            PanelBlock(art: art, rect: art.local(59, 144, 230, 205), fill: FirstRun.lilac.block)
            PanelBlock(art: art, rect: art.local(132, 253, 283, 311), fill: FirstRun.lilac.block)
        }
        CalendarPanel(title: "Personal", dot: FirstRun.mint.dot, text: FirstRun.mint.text, art: art,
                      frame: art.rect(407, 597, 723, 985)) {
            PanelBlock(art: art, rect: art.local(60, 166, 210, 221), fill: FirstRun.mint.block)
            PanelBlock(art: art, rect: art.local(110, 276, 260, 331), fill: FirstRun.coral.block)
        }
    }
}

/// Which calendars make you busy: a busy one filled, one that only shows outlined, Banana
/// peeking from the left at the outline.
struct CalendarsScene: View {
    let art: ArtSpace
    let busy: String
    let notBusy: String?

    var body: some View {
        Circle()
            .fill(FirstRun.lilacShape)
            .placed(art.rect(330, 428, 860, 958))
            .mask(alignment: .topLeading) { Rectangle().frame(width: art.length(1024), height: art.y(700)) }
        Capsule().fill(FirstRun.lilacShape).placed(art.rect(772, 428, 855, 442))
        Capsule().fill(FirstRun.lilacShape).placed(art.rect(835, 476, 890, 490))
        MascotPicture(name: "MascotCalendars", rect: art.rect(67, 431, 377, 745))
        CalendarPanel(title: busy, dot: FirstRun.lilac.dot, text: FirstRun.lilac.text, art: art,
                      frame: art.rect(264, 582, 565, 950)) {
            PanelBlock(art: art, rect: art.local(48, 193, 200, 265), fill: FirstRun.lilac.block)
        }
        if let notBusy {
            CalendarPanel(title: notBusy, dot: FirstRun.coral.dot, text: FirstRun.coral.text, art: art,
                          frame: art.rect(590, 582, 937, 950)) {
                PanelBlock(art: art, rect: art.local(49, 185, 236, 248), stroke: FirstRun.coral.dot)
            }
        }
    }
}

/// Copies: an event on one calendar becomes "Busy" on the other, Banana watching over the field.
struct CopiesScene: View {
    let art: ArtSpace
    let source: String
    let destination: String

    var body: some View {
        // Behind the field, its head well above the field's edge, as in the art.
        MascotPicture(name: "MascotCopies", rect: art.rect(655, 252, 975, 578))
        RoundedRectangle(cornerRadius: art.length(70), style: .continuous)
            .fill(FirstRun.yellow)
            .placed(art.rect(62, 497, 962, 988))
        let from = DayClock.hour(14), to = DayClock.hour(15, withPeriod: true)
        CalendarPanel(title: source, dot: FirstRun.mint.dot, text: FirstRun.mint.text, art: art,
                      frame: art.rect(124, 558, 442, 942)) {
            PanelBlock(art: art, rect: art.local(24, 188, 292, 310), fill: FirstRun.mint.fill,
                       title: "Meeting", detail: "\(from)\u{2013}\(to)", textColour: FirstRun.mint.text)
        }
        Image(systemName: "arrow.right")
            .resizable()
            .scaledToFit()
            .fontWeight(.medium)
            .foregroundStyle(DS.Palette.Brand.night)
            .placed(art.rect(474, 722, 550, 770))
        CalendarPanel(title: destination, dot: FirstRun.lilac.dot, text: FirstRun.lilac.text, art: art,
                      frame: art.rect(580, 558, 900, 942)) {
            PanelBlock(art: art, rect: art.local(26, 188, 296, 310), fill: FirstRun.busyGrey,
                       title: "Busy", detail: "\(from)\u{2013}\(to)", textColour: DS.Palette.Brand.night.opacity(0.75))
        }
    }
}

/// Done: Banana stands in front of the band, a little confetti, looking at the receipt.
struct DoneScene: View {
    let art: ArtSpace

    var body: some View {
        BandShape(top: [CGPoint(x: 0, y: 665), CGPoint(x: 350, y: 640), CGPoint(x: 700, y: 575), CGPoint(x: 1024, y: 560)],
                  bottom: [CGPoint(x: 1024, y: 845), CGPoint(x: 700, y: 845), CGPoint(x: 300, y: 845), CGPoint(x: 0, y: 845)],
                  art: art)
            .fill(FirstRun.yellow)
        confetti(432, 544, FirstRun.lilacShape, -30)
        confetti(928, 477, FirstRun.lilacShape, 25)
        confetti(896, 568, FirstRun.mint.block, 20)
        MascotPicture(name: "MascotDone", rect: art.rect(537, 449, 902, 821))
    }

    private func confetti(_ x: CGFloat, _ y: CGFloat, _ colour: Color, _ angle: Double) -> some View {
        Capsule().fill(colour)
            .frame(width: art.length(48), height: art.length(16))
            .rotationEffect(.degrees(angle))
            .position(art.point(x, y))
    }
}
