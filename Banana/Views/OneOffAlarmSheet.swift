import SwiftUI

/// Set a one-off alarm for a specific moment ("wake me at 4pm"). The ad-hoc escape hatch the
/// automated system doesn't cover; recurring alarms live as cues in Routines.
///
/// The list is the same on every device. The phone rings them (a one-shot AlarmKit alarm); on an
/// iPad or the Mac an alarm is added to the list for the phone to arm, and each row says whether
/// it has yet.
struct OneOffAlarmSheet: View {
    @EnvironmentObject var alarms: AlarmStore
    @ObservedObject private var hub = HubStatusStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var fire: Date = Date().addingTimeInterval(3600)
    @State private var label: String = ""
    @State private var busy = false

    private let onHub = DeviceRole.current.isHub

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MomentField("Time", selection: $fire, from: Date())
                    TextField("Label (optional)", text: $label)
                    Button {
                        busy = true
                        Task {
                            if await alarms.addOneOff(at: fire, label: label) { label = "" }
                            busy = false
                        }
                    } label: {
                        HStack {
                            Label("Set alarm", systemImage: "alarm.waves.left.and.right")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy)
                } header: {
                    Text("New alarm")
                } footer: {
                    Text(onHub
                         ? "Rings once, then clears itself. For something that repeats, add a routine in Routines."
                         : "Rings once on your iPhone, then clears itself. For something that repeats, add a routine in Routines.")
                }

                if !alarms.oneOffAlarms.isEmpty {
                    Section("Scheduled") {
                        ForEach(alarms.oneOffAlarms) { alarm in
                            row(alarm)
                        }
                    }
                }
            }
            .editingFormStyle()
            .navigationTitle("Alarms")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Alarm", isPresented: Binding(
                get: { alarms.errorMessage != nil },
                set: { if !$0 { alarms.errorMessage = nil } }
            )) { Button("OK", role: .cancel) { alarms.errorMessage = nil } }
            message: { Text(alarms.errorMessage ?? "") }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func row(_ alarm: OneOffAlarm) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "alarm").foregroundStyle(DS.Palette.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(alarm.fire, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.body).monospacedDigit()
                if !alarm.label.isEmpty {
                    Text(alarm.label).font(.caption).foregroundStyle(.secondary)
                }
                if !onHub {
                    Text(PhoneStatusText(status: hub.status).alarmLine(alarm.id))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { DeleteUndo.alarm(alarm.id, in: alarms) } label: {
                Image(systemName: "trash")
            }
            .iconButton()
            .accessibilityLabel("Delete")
        }
    }
}
