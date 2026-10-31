import SwiftUI

/// The rules that generate your day. v1: view/enable seeded routines, and reach the
/// existing smart-schedule + manual-alarm config. (Full per-routine editing next.)
struct RoutinesView: View {
    @EnvironmentObject var routines: RoutineStore
    @EnvironmentObject var smart: SmartScheduleStore
    @State private var editing: Routine?
    @State private var pickingTemplate = false
    @State private var pendingType: CueType?
    @State private var newDraft: Routine?
    /// On iOS this is a sheet under Plan's "…" menu, so it needs its own way out; the Mac
    /// sidebar hosts it directly and passes nothing.
    var showsDoneButton = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {

        let _ = RenderStats.note("RoutinesView")
        NavigationStack {
            List {
                Section {
                    smartScheduleRow
                }

                ForEach(routines.grouped(), id: \.group) { section in
                    Section(section.group.label) {
                        ForEach(section.items) { routine in
                            Button { editing = routine } label: { row(routine) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("Delete", role: .destructive) { DeleteUndo.routine(routine.id, in: routines) }
                                }
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) { DeleteUndo.routine(routine.id, in: routines) }
                                }
                        }
                    }
                }
                // In a sheet, adding is the last row of the list (`PageChrome`).
                if showsDoneButton {
                    Section {
                        Button { pickingTemplate = true } label: {
                            Label("Add routine", systemImage: "plus")
                        }
                        .accessibilityIdentifier("routines.add")
                    }
                }
            }
            // As a page of its own (an iPad, the Mac) it has the page's one +.
            .modifier(RoutinesAdd(inSheet: showsDoneButton) { pickingTemplate = true })
            // A column in the middle of an iPad or a wide window, not rows stretched across it.
            .readableColumn()
            .navigationTitle("Routines")
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                } else {
                    // As a page: "…" like every other page's, the way to Settings.
                    ToolbarItem(placement: .automatic) { MoreMenu() }
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(item: $editing) { RoutineEditorView(draft: $0, isNew: false) }
            // Pick a template first; present the editor only AFTER the picker fully dismisses
            // (onDismiss) so the two sheets never race.
            .sheet(isPresented: $pickingTemplate, onDismiss: {
                if let t = pendingType { pendingType = nil; newDraft = t.makeRoutine() }
            }) {
                CueTemplatePicker(missing: routines.missingBuiltInTypes) { type in
                    pendingType = type
                    pickingTemplate = false
                }
            }
            .sheet(item: $newDraft) { RoutineEditorView(draft: $0, isNew: true) }
        }
    }

    /// Smart Schedule, built like the routine rows below it rather than as a bare navigation
    /// label. It used to read as a section header: no state, no switch, and the only way to
    /// learn whether it was on was to navigate in and look. That mattered more than it sounds —
    /// `enabled` gates the whole wake/travel/bedtime engine (see performRecompute), so "is this
    /// on?" is the first question to ask when the day looks empty, and it was the one thing the
    /// screen wouldn't answer.
    /// The switch is the page's own first row (`SmartScheduleView`), so this row is only the
    /// way in: a chevron, not a chevron and a switch side by side.
    private var smartScheduleRow: some View {
        NavigationLink { SmartScheduleView() } label: {
            HStack(spacing: 12) {
                IconTile(systemImage: "calendar.badge.clock",
                         tint: smart.settings.enabled ? DS.Palette.accent : Color.secondary,
                         size: 34,
                         glyph: smart.settings.enabled ? DS.Palette.onAccent : nil)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Wake & bedtime").font(.body.weight(.medium))
                    Text(smartScheduleSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// One line that answers "is this doing anything, and what".
    private var smartScheduleSummary: String {
        guard smart.settings.enabled else { return "Off" }
        var parts: [String] = []
        if let wake = smart.plan?.days.first(where: { $0.wake != nil })?.wake {
            parts.append("Wake \(wake.formatted(.dateTime.hour().minute()))")
        }
        if smart.settings.accountForTravel { parts.append("travel") }
        if smart.settings.blockTravelTime { parts.append("blocks travel time") }
        if smart.settings.bedtimeRemindersEnabled { parts.append("bedtime") }
        return parts.isEmpty ? "On" : parts.joined(separator: " · ")
    }

    private func row(_ routine: Routine) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: routine.icon, tint: routine.color.color, size: 34)
            .opacity(routine.enabled ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 3) {
                Text(routine.name).font(.body.weight(.medium))
                detailLine(triggerIcon(routine.triggerKind), routine.triggerDescription)
                // Only when something is set to play; a "Not set" line said nothing.
                if let source = sourceLine(routine) {
                    detailLine("waveform", source)
                }
            }
            .opacity(routine.enabled ? 1 : 0.55)

            // The controls at the trailing edge, in one column down the list.
            Spacer(minLength: DS.Space.s)

            // Start it now, whatever its time: the way to run a Manual one at all.
            RoutineStartButton(routine: routine, compact: true)

            Toggle("", isOn: Binding(
                get: { routine.enabled },
                set: { routines.setEnabled(routine.id, $0) }
            ))
            .formControls()
            .labelsHidden()
        }
        .padding(.vertical, 3)
    }

    private func detailLine(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2).frame(width: 14)
            Text(text).font(.footnote)
        }
        .foregroundStyle(.secondary).lineLimit(1)
    }

    private func triggerIcon(_ kind: RoutineTriggerKind) -> String {
        switch kind {
        case .time:            return "clock"
        case .earliestMeeting: return "calendar.badge.clock"
        case .calendarMatch:   return "calendar"
        case .workoutStart:    return "figure.run"
        case .wakeUp:          return "sunrise"
        case .manual:          return "hand.tap"
        }
    }

    private func sourceLine(_ routine: Routine) -> String? {
        guard !routine.sourceLabel.isEmpty, routine.sourceLabel != "Not set" else { return nil }
        var s = routine.sourceLabel
        if let minutes = routine.sleepTimerMinutes { s += " · fade \(minutes)m" }
        return s
    }
}

/// The add-cue flow. Templates ARE the cue types: pick one and the parent instantiates a cue
/// pre-wired for it. Deleted built-in cues (Wake, Workout, …) resurface here as "re-add", so a
/// special cue the app hooks into is never permanently lost. Custom is always available.
struct CueTemplatePicker: View {
    let missing: [CueType]
    let onPick: (CueType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !missing.isEmpty {
                    Section {
                        ForEach(missing, id: \.self) { row($0) }
                    } header: {
                        Text("Re-add a built-in routine")
                    } footer: {
                        Text("These are the special cues Banana hooks into. You can only have one of each.")
                    }
                }
                Section("Start fresh") { row(.custom) }
            }
            .navigationTitle("New routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func row(_ type: CueType) -> some View {
        Button { onPick(type) } label: {
            HStack(spacing: 12) {
                IconTile(systemImage: type.icon, tint: type.accent.color, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(type.blurb).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }
}

/// The page's + when Routines is a page; nothing when it is a sheet, where its list ends with
/// "Add routine".
private struct RoutinesAdd: ViewModifier {
    let inSheet: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if inSheet {
            content
        } else {
            content.addButton(identifier: "routines.add", action: action)
        }
    }
}
