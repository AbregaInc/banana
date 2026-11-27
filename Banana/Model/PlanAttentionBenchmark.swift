#if DEBUG && targetEnvironment(simulator)
import Darwin
import Foundation

/// Same-binary comparison, available only inside the isolated scale fixture.
@MainActor
enum PlanAttentionBenchmark {
    struct Sample: Codable {
        let events: Int
        let trial: Int
        let indexPayloadBytes: Int
        let phase: String
        let wallMS: Double
        let cpuMS: Double
        let checksum: Int
    }

    static func run(events: [Occurrence], to url: URL) throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        guard let routine = RoutineStore.shared.routines.first(where: { $0.cueType == .custom || $0.cueType == .workout }) else {
            preconditionFailure("Expected a seeded routine in the isolated scale fixture")
        }
        var ignored = routine
        ignored.id = UUID()
        ignored.cueType = .sleep
        let routines = [routine, ignored]
        var sample = Occurrence(id: "due", source: .authored, behavior: .cue,
                                schedule: .init(mode: .fixed), title: "", icon: "", tint: .blue,
                                start: now, routineID: routine.id)
        var mixed = [sample]
        sample.start = now.addingTimeInterval(60)
        mixed.append(sample)
        sample.routineID = ignored.id
        mixed.append(sample)
        sample.routineID = nil
        mixed.append(sample)
        sample.routineID = routine.id
        sample.start = now
        sample.completed = true
        mixed.append(sample)
        sample.completed = false
        sample.skipped = true
        mixed.append(sample)
        sample.skipped = false
        sample.hasScheduledTime = false
        mixed.append(sample)
        sample.title = "Dose"
        sample.behavior = .task
        sample.overdue = true
        mixed.append(sample)
        sample.completed = true
        mixed.append(sample)
        for i in mixed.indices { mixed[i].id = "attention-\(i)" }

        func original(_ rows: [Occurrence], at time: Date) -> Int {
            let due = rows.filter { item in
                guard item.behavior == .cue,
                      let owner = routines.first(where: { $0.id == item.routineID }),
                      owner.cueType == .custom || owner.cueType == .workout else { return false }
                return ActionItems.routineDueSince(start: item.start, hasTime: item.hasScheduledTime,
                    completed: item.completed, skipped: item.skipped, now: time) != nil
            }
            return rows.filter(\.isOverdueReminder).count + due.count
        }
        func count(_ index: PlanAttentionIndex, rows: [Occurrence], at time: Date) -> Int {
            var result = index.overdueReminders
            index.forEachDueRoutine(in: rows, routines: routines, now: time) { _, _ in result += 1 }
            return result
        }
        // Completing, skipping or rescheduling a cue replaces its occurrence snapshot.
        // A routine's kind can change independently, and the clock can also move backwards.
        var edited = mixed
        edited[0].completed = true
        edited[1].start = now
        edited[1].skipped = true
        edited.removeLast(2)
        OccurrenceStore.shared.verifyStressPlanAttentionReplacement(mixed, edited: edited, at: now)
        let editedIndex = PlanAttentionIndex(edited)
        precondition(count(editedIndex, rows: edited, at: now) == 0)
        var changedOwner = routine
        changedOwner.cueType = .sleep
        let mixedIndex = PlanAttentionIndex(mixed)
        #if BANANA_MODULE_FOOD
        precondition(mixedIndex.containsOpenReminder(named: "dose", in: mixed))
        precondition(!editedIndex.containsOpenReminder(named: "dose", in: edited))
        #endif
        var due = 0
        mixedIndex.forEachDueRoutine(in: mixed, routines: [changedOwner, ignored], now: now) { _, _ in due += 1 }
        precondition(due == 0)

        var samples: [Sample] = []
        for size in [0, 100, 9_000, 36_500] where size <= events.count {
            let rows = Array(events.prefix(size)) + mixed
            let index = PlanAttentionIndex(rows)
            var payloadBytes = index.cueOffsets.capacity * MemoryLayout<Int>.stride
            #if BANANA_MODULE_FOOD
            payloadBytes += index.openReminderOffsets.capacity * MemoryLayout<Int>.stride
            #endif
            let times = [-1.0, 0, 59, 60, -1].map { now.addingTimeInterval($0) }
            precondition(times.map { count(index, rows: rows, at: $0) } == [1, 2, 2, 3, 1])
            for trial in 0..<9 {
                let time = times[trial % times.count]
                let expected = original(rows, at: time)
                var phases = ["original", "cold", "warm"]
                #if BANANA_MODULE_FOOD
                phases += ["doseOriginal", "doseIndexed"]
                #endif
                if !trial.isMultiple(of: 2) { phases.reverse() }
                for phase in phases {
                    let cpu = clock()
                    let start = ProcessInfo.processInfo.systemUptime
                    let value: Int
                    switch phase {
                    case "original": value = original(rows, at: time)
                    case "cold": value = count(PlanAttentionIndex(rows), rows: rows, at: time)
                    #if BANANA_MODULE_FOOD
                    case "doseOriginal":
                        value = ["absent", "dOsE"].filter { name in
                            rows.contains { $0.behavior == .task && !$0.completed
                                && $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
                        }.count
                    case "doseIndexed":
                        value = ["absent", "dOsE"].filter { name in
                            index.containsOpenReminder(named: name, in: rows)
                        }.count
                    #endif
                    default: value = count(index, rows: rows, at: time)
                    }
                    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    let cpuMS = Double(clock() - cpu) * 1000 / Double(CLOCKS_PER_SEC)
                    precondition(value == (phase.hasPrefix("dose") ? 1 : expected))
                    samples.append(.init(events: size, trial: trial,
                                         indexPayloadBytes: payloadBytes,
                                         phase: phase, wallMS: elapsed,
                                         cpuMS: cpuMS, checksum: value))
                }
            }
        }
        try JSONEncoder().encode(samples).write(to: url, options: .atomic)
    }
}
#endif
