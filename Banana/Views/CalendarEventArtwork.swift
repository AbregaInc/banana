import SwiftUI

/// Immutable paint inputs shared by the reference artwork and the prepared native renderer.
/// No provider objects, stores, closures or pending-write operations cross this boundary.
/// Dynamic colors are resolved by the rendering backend in the current view environment.
struct CalendarEventPaint: Equatable {
    var title: String
    var start: Date
    var startText: String
    var timeRange: String
    var icon: String
    var isTask: Bool = false
    var isEvent: Bool = true
    var isMoment: Bool = false
    var hasScheduledTime: Bool = true
    var completed: Bool = false
    var skipped: Bool = false
    var othersDeclined: Bool = false
    var showsAsFree: Bool = false
    var tentative: Bool = false
    var needsAction: Bool = false
    var tint: Color = .blue
    var ribbons: [Color] = [.blue]
    var fillOpacity: Double = DS.Event.fill
    var returnCaption: String? = nil
    var location: String? = nil
    var ribbonInset: CGFloat { ribbons.count > 1 ? DS.Event.calendarDot + DS.Space.xs : 0 }
}

/// The production SwiftUI reference. Interaction and accessibility ownership stay with the
/// calendar cell; this view owns only artwork. Both modes remain available on either platform
/// so the offline renderer oracle can verify every layout without launching an app window.
struct CalendarEventArtwork: View {
    enum Layout { case desktop, mobile }
    let paint: CalendarEventPaint
    let height: CGFloat
    let layout: Layout
    var showsIcon = true

    @ViewBuilder var body: some View {
        switch layout {
        case .desktop: desktop
        case .mobile: mobile
        }
    }

    private var desktop: some View {
        let tint = paint.tint, ribbons = paint.ribbons
        let twoLine = height >= DS.Event.twoLineMinHeight
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: DS.Space.xs) {
                // Reminders always carry their done/not-done mark, at any width: for a reminder
                // that IS the important fact. Other kinds show their icon only when the column
                // has room for it on every block.
                if paint.isTask {
                    Image(systemName: paint.completed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 9, weight: .semibold))
                } else if paint.completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                } else if paint.skipped {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 9, weight: .semibold))
                } else if showsIcon {
                    Image(systemName: paint.icon)
                        .font(.system(size: 9, weight: .semibold))
                }
                if paint.othersDeclined { OthersDeclinedMark() }
                if twoLine {
                    Text(paint.title)
                        .font(DS.Typeface.eventTitle)
                        // Strikethrough carries at any size and says "done" rather than the
                        // "faded" that also means skipped, past, or tentative.
                        .strikethrough(paint.completed || paint.skipped, color: .secondary)
                        .lineLimit(max(1, Int((height - 20) / 13)))
                } else {
                    // Too short for two lines: title, then when — on one.
                    (Text(paint.title).font(DS.Typeface.eventTitle)
                        + Text("  \(paint.startText)").font(DS.Typeface.eventMeta).foregroundColor(tint.opacity(0.75)))
                        .strikethrough(paint.completed || paint.skipped, color: .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if twoLine {
                if let returnCaption = paint.returnCaption {
                    Label(returnCaption,
                          systemImage: "house")
                        .font(DS.Typeface.eventMeta.weight(.semibold))
                        .foregroundStyle(DS.Palette.travel)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                } else {
                    Text(paint.timeRange)
                        .font(DS.Typeface.eventMeta)
                        .foregroundStyle(tint.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(tint)
        .padding(.leading, DS.Space.s + paint.ribbonInset)
        .padding(.trailing, DS.Space.xs)
        .padding(.vertical, twoLine ? DS.Space.xs : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: twoLine ? .topLeading : .leading)
        // A free event keeps its calendar's colour but loses the solid fill and the full-strength
        // spine, so a glance down the column separates what holds a slot from what merely sits in it.
        .background(tint.opacity(paint.fillOpacity))
        .overlay(alignment: .leading) {
            EventRibbons(colors: ribbons, opacity: paint.showsAsFree ? 0.4 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous))
        .freeBlockTreatment(paint.showsAsFree, tint: tint, cornerRadius: DS.Radius.block)
        .eventReplyTreatment(tentative: paint.tentative, needsAction: paint.needsAction, tint: tint, cornerRadius: DS.Radius.block)
        .opacity(paint.completed ? 0.55 : (paint.skipped ? 0.4 : 1))
    }

    private var mobile: some View {
        let color = paint.tint, ribbons = paint.ribbons
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if paint.isTask {
                    // Same rule as the Mac grid: for a reminder, done-or-not is the fact worth
                    // the glyph, so it always shows the circle/checkmark rather than a kind icon.
                    Image(systemName: paint.completed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                } else if !paint.isEvent {
                    Image(systemName: paint.completed ? "checkmark.circle.fill" : (paint.skipped ? "xmark.circle" : paint.icon))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                }
                if paint.othersDeclined { OthersDeclinedMark() }
                Text(paint.title)
                    // A block kept to its own few minutes (see CalendarBlockHeight) still names itself.
                    .font(height < 20 ? .system(size: 9, weight: .semibold) : DS.Typeface.eventTitle)
                    .foregroundStyle(.primary)
                    .strikethrough(paint.completed || paint.skipped, color: .secondary)
                    .lineLimit(height >= 76 ? 3 : (height >= 40 ? 2 : 1))
                // A moment — a wake-up, an alarm — has no length to draw, so its block is too short
                // for the time line below: its time goes beside the name, and keeps its room first.
                if height < 40, paint.hasScheduledTime, paint.isMoment {
                    Text(paint.start, format: .dateTime.hour().minute())
                        .font(DS.Typeface.eventMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                        .accessibilityIdentifier("grid.cueTime")
                }
                Spacer(minLength: 0)
            }
            // Same "Travel home" hold meetingContent surfaces inline, drawn here too so Day-grid
            // users (WeekView in dayMode) see it — the grid's own .block occurrences stay
            // undrawn (design intent), so this is the only place the return leg reaches the grid.
            // A short block has no room for the duration, so collapse to icon + time only.
            if let returnCaption = paint.returnCaption {
                Label(returnCaption, systemImage: "house")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Palette.travel)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            } else if height >= 40 {
                Text(paint.timeRange)
                    .font(DS.Typeface.eventMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if height >= 64, let location = paint.location {
                Text(location)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, DS.Space.s + paint.ribbonInset)
        .padding(.trailing, DS.Space.xs)
        .padding(.vertical, height < 16 ? 0 : DS.Space.hair)
        // Too short for any text: just the block, its colour and ribbon.
        .opacity(height < 9 ? 0 : 1)
        // The block fills its whole slot at every height, text at the top. Below 46 pt the
        // content used to hug its text and sit centred in the slot, so a 7:00–7:25 call drew as a
        // slim pill from about 7:07 to 7:18.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Matches the Mac grid: free events keep the calendar colour but lose the solid fill and
        // the full-strength spine, so the column separates held slots from merely-noted ones.
        .background(
            color.opacity(paint.fillOpacity),
            in: RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous)
        )
        // Text never spills out of a short block onto the one below it.
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous))
        .overlay(alignment: .leading) {
            EventRibbons(colors: ribbons, opacity: paint.showsAsFree ? 0.4 : 1, cornerRadius: 1.5)
                .padding(.vertical, 2)
        }
        .freeBlockTreatment(paint.showsAsFree, tint: color, cornerRadius: DS.Radius.block)
        .eventReplyTreatment(tentative: paint.tentative, needsAction: paint.needsAction, tint: color, cornerRadius: DS.Radius.block)
        .opacity(paint.completed || paint.skipped ? 0.55 : 1)
    }
}
