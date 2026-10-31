import SwiftUI

/// What a tap on a routine moment in the calendar opens — tomorrow's wake-up, a workout cue: its
/// exact time and day, and what set it. It used to open the routine's settings, which describe
/// the rule ("Before your first meeting") but never the time it came to.
struct CueOccurrenceSheet: View {
    enum Action { case move, edit, addAnother }

    let occurrence: Occurrence
    let routine: Routine
    /// The wake plan, for why a meeting-timed cue lands where it does.
    let plan: WakePlan?
    var onAction: (Action) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: DS.Space.m) {
                        IconTile(systemImage: routine.icon, tint: routine.color.color, size: DS.Row.glyphTile)
                        VStack(alignment: .leading, spacing: DS.Space.hair) {
                            Text(occurrence.hasScheduledTime
                                 ? occurrence.start.formatted(date: .omitted, time: .shortened)
                                 : "When it starts")
                                .font(.title2.weight(.semibold).monospacedDigit())
                                .accessibilityIdentifier("cueSheet.time")
                            Text(CueTimeText.day(occurrence.start))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, DS.Space.xs)
                    if occurrence.completed {
                        Label("Completed", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    }
                    if occurrence.skipped {
                        Label("Skipped", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(CueTimeText.reason(triggerIsWakePlan: routine.triggerKind == .earliestMeeting,
                                            ruleDescription: routine.triggerDescription,
                                            date: occurrence.start, plan: plan))
                }
                Section {
                    RoutineStartButton(routine: routine) { dismiss() }
                }
                if occurrence.occurrenceKey != nil {
                    Section {
                        if !occurrence.skipped {
                            Button(occurrence.completed ? "Mark not completed" : "Mark completed", systemImage: occurrence.completed ? "circle" : "checkmark.circle") {
                                CueCompletion.toggle(occurrence)
                                dismiss()
                            }
                            .accessibilityIdentifier("cue.complete")
                        }
                        if occurrence.skipped {
                            Button("Restore", systemImage: "arrow.uturn.backward") {
                                CueSkip.restore(occurrence)
                                dismiss()
                            }
                        } else if !occurrence.completed {
                            Button("Skip this one", systemImage: "xmark.circle") {
                                CueSkip.skip(occurrence)
                                dismiss()
                            }
                            Button("Move…", systemImage: "clock.arrow.circlepath") { finish(.move) }
                        }
                    }
                }
                Section {
                    Button("Edit \(routine.name)…", systemImage: "pencil") { finish(.edit) }
                    Button("Add another…", systemImage: "plus.circle") { finish(.addAnother) }
                } footer: {
                    Text(RoutineWording.sheetFooter(sourceLabel: routine.sourceLabel))
                }
            }
            .navigationTitle(routine.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The next sheet opens once this one has gone (`onDismiss` in the calendar).
    private func finish(_ action: Action) {
        onAction(action)
        dismiss()
    }
}
