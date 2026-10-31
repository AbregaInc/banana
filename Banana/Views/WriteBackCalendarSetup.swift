import SwiftUI

/// Which calendars receive availability busy blocks — the toggle list shared by onboarding
/// (iOS pages and the Mac gate) and Settings. Calendars you own default to ON. Calendars you can
/// edit but someone else owns default to OFF: every block written to one notifies the people it
/// is shared with, so writing there is a choice made per calendar.
struct WriteBackCalendarPicker: View {
    @EnvironmentObject private var smart: SmartScheduleStore
    @ObservedObject private var writeBack = CalendarWriteBack.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            let owned = writeBack.writableCalendars.filter(\.isOwner)
            let shared = writeBack.writableCalendars.filter { !$0.isOwner }
            // Grouped by account, so two "Work" calendars on two accounts can't be confused.
            ForEach(Self.accounts(of: owned), id: \.self) { account in
                group(account.isEmpty ? "Your calendars" : account) {
                    ForEach(owned.filter { $0.sourceTitle == account }) { calendar in
                        row(calendar, isOn: ownedBinding(for: calendar.id))
                    }
                }
            }
            if !shared.isEmpty {
                group("Shared with you") {
                    ForEach(shared) { calendar in
                        row(calendar, isOn: sharedBinding(for: calendar.id), tag: "Shared")
                    }
                }
                // Said only when there is a shared calendar to say it about.
                Text("A busy block on a shared calendar notifies everyone it\u{2019}s shared with.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { writeBack.refreshCalendars() }
    }

    static func accounts(of calendars: [CalendarWriteBack.WritableCalendar]) -> [String] {
        var seen: [String] = []
        for calendar in calendars where !seen.contains(calendar.sourceTitle) { seen.append(calendar.sourceTitle) }
        return seen
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            content()
        }
    }

    /// The calendar's own colour is the checkbox: one mark says both "on" and "which one".
    private func row(_ calendar: CalendarWriteBack.WritableCalendar, isOn: Binding<Bool>, tag: String? = nil) -> some View {
        let tint = smart.calendarColorHex[calendar.id].map { calendarTint($0) } ?? Color.secondary
        return Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: DS.Space.m) {
                ZStack {
                    Circle()
                        .strokeBorder(tint, lineWidth: 2)
                    if isOn.wrappedValue {
                        Circle().fill(tint)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 22, height: 22)
                Text(calendar.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s)
                if let tag {
                    Text(tag)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Space.s - 2)
                        .padding(.vertical, DS.Space.hair)
                        .background(Color.primary.opacity(DS.Tint.subtle), in: Capsule())
                }
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
        .accessibilityLabel("\(calendar.displayName)\(tag.map { ", \($0)" } ?? "")")
    }

    private func ownedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !smart.settings.writeBackExcludedCalendarIDs.contains(id) },
            set: { include in
                if include {
                    smart.settings.writeBackExcludedCalendarIDs.remove(id)
                } else {
                    smart.settings.writeBackExcludedCalendarIDs.insert(id)
                }
            }
        )
    }

    private func sharedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: {
                smart.settings.writeBackSharedCalendarIDs.contains(id)
                    && !smart.settings.writeBackExcludedCalendarIDs.contains(id)
            },
            set: { include in
                if include {
                    smart.settings.writeBackSharedCalendarIDs.insert(id)
                    smart.settings.writeBackExcludedCalendarIDs.remove(id)
                } else {
                    smart.settings.writeBackSharedCalendarIDs.remove(id)
                }
            }
        )
    }
}

/// Which calendars keep each other busy, with every calendar the person owns ticked. Asked
/// from the plan once a Google account is connected (`PlanPrompt.busyCalendars`), or from the
/// setup list. It stood between Google's sign-in and the plan; a step there is where people
/// are lost, so the plan now comes first and nothing is written until this is answered.
///
/// It was a sheet headed "Where should Banana write availability?" about "privacy-safe busy
/// blocks": the app's own words for it, put to someone who had not yet seen their day (review of
/// 9 Oct 2026). The question is the same. It is now asked in plain words, with an example.
struct WriteBackCalendarSetupSheet: View {
    let onDone: () -> Void
    @ObservedObject private var google = GoogleCalendarService.shared
    @State private var arrived = 0

    var body: some View {
        OnePage {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(DS.Palette.success)
                    .symbolEffect(.bounce, value: arrived)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text("Google Calendar connected")
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !accounts.isEmpty {
                        Text(accounts)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.top, DS.Space.l)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("Keep your calendars in step")
                    .font(.headline)
                Text("Busy time is copied to the calendars you tick. Only the time, never a title.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                BusyExample()
            }
            WriteBackCalendarPicker()
        } actions: {
            // Continue is the yes: busy blocks start only now, on what is ticked above.
            Button("Continue") {
                CalendarWriteBack.shared.answerQuestion()
                onDone()
            }
            .buttonStyle(.primaryCapsule)
            .accessibilityIdentifier("calendars.continue")
            // The first sign-in is one account; most people have more, and each account's
            // calendars should be here before choosing.
            Button {
                Task {
                    await GoogleCalendarService.shared.connect()
                    CalendarWriteBack.shared.refreshCalendars()
                }
            } label: {
                Label("Add another Google account", systemImage: "person.badge.plus")
            }
            .buttonStyle(.quiet)
            .disabled(google.isWorking)
        }
        #if os(macOS)
        .frame(width: 480, height: 640)
        #endif
        .presentationDetents([.large])
        .interactiveDismissDisabled()
        .onAppear { arrived += 1 }
        .sensoryFeedback(.success, trigger: arrived)
    }

    private var accounts: String {
        google.accounts.map(\.email).joined(separator: ", ")
    }
}

/// What "kept busy" looks like: a meeting on one calendar, the same time marked Busy on another.
private struct BusyExample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            row(calendar: "Work", title: "Design review", tint: DS.Palette.Brand.purple)
            row(calendar: "Personal", title: "Busy", tint: .secondary)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("For example: Design review, 2 to 3 PM, on Work shows as Busy, 2 to 3 PM, on Personal.")
    }

    private func row(calendar: String, title: String, tint: Color) -> some View {
        HStack(spacing: DS.Space.m) {
            Text(calendar)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            HStack(spacing: 0) {
                HStack(spacing: DS.Space.s) {
                    Text(title).font(.footnote.weight(.semibold))
                    Spacer(minLength: DS.Space.s)
                    Text("2\u{2013}3 PM").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs + 2)
            }
            .background(tint.opacity(DS.Event.fill))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous))
        }
    }
}
