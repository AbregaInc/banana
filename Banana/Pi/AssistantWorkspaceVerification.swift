#if BANANA_AI
#if DEBUG
import Foundation

/// Runs the real model and native adapters in the existing isolated verification store.
@MainActor enum AssistantWorkspaceVerification {
    static func verifyAgendaTimes() throws {
        let cases: [(String, String, String)] = [
            ("America/New_York", "2026-11-05T15:00:00Z", "10:00 AM"),
            ("America/New_York", "2026-07-05T14:00:00Z", "10:00 AM"),
            ("Europe/London", "2026-11-05T15:00:00Z", "3:00 PM"),
            ("Europe/London", "2026-07-05T14:00:00Z", "3:00 PM"),
            ("Asia/Tokyo", "2026-11-05T15:00:00Z", "12:00 AM"),
            ("Asia/Kathmandu", "2026-11-05T15:00:00Z", "8:45 PM")
        ]
        for (zone, instant, expected) in cases {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
            let targetDay = AssistantNutrition.key(try Date(instant, strategy: .iso8601), calendar: calendar)
            let agenda = AssistantAgenda(date: targetDay, timeZone: zone, items: [], hasMore: false)
            let item = AssistantAgenda.Item(title: "Test", start: instant, end: "", kind: "meeting", hasScheduledTime: true)
            let actual = agenda.time(item, locale: Locale(identifier: "en_US"))
                .replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
            guard actual == expected else { throw AssistantFailure(message: "Wrong agenda time for \(zone): \(actual)") }
        }
        let fold = AssistantAgenda(date: "2026-11-01", timeZone: "America/New_York", items: [], hasMore: false)
        let repeated = AssistantAgenda.Item(title: "DST fold", start: "2026-11-01T05:30:00Z", end: "2026-11-01T06:30:00Z", kind: "meeting", hasScheduledTime: true)
        let label = fold.time(repeated, locale: Locale(identifier: "en_US"))
        guard label.contains("EDT"), label.contains("EST") else { throw AssistantFailure(message: "Repeated DST hour must identify both offsets") }
        let providerJSON = #"{"id":"flight-zone-test","summary":"JFK to LHR","start":{"dateTime":"2026-11-05T20:00:00-05:00","timeZone":"America/New_York"},"end":{"dateTime":"2026-11-06T08:00:00+00:00","timeZone":"Europe/London"}}"#
        let providerEvent = try JSONDecoder().decode(GoogleEvent.self, from: Data(providerJSON.utf8))
        let providerWindow = GoogleEventWindowBuilder.window(from: [.init(calendarID: "fixture", event: providerEvent)])
        guard let imported = providerWindow.meetings.first,
              imported.startTimeZone == "America/New_York", imported.endTimeZone == "Europe/London",
              imported.end!.timeIntervalSince(imported.start) == 7 * 3600 else {
            throw AssistantFailure(message: "Provider import lost flight zones or changed its duration")
        }
        let allDay = AssistantAgenda.Item(title: "Birthday", start: "2026-11-05T00:00:00Z", end: "", kind: "allDay", hasScheduledTime: false)
        guard fold.time(allDay) == "All day" else { throw AssistantFailure(message: "All-day entries must not display a shifted midnight") }
        #if PI_DEVELOPMENT
        for (clock, arrivalHour) in [("2026-10-25T12:00:00Z", 7), ("2026-11-02T12:00:00Z", 8)] {
            let flight = PiSampleData.flights(now: try Date(clock, strategy: .iso8601))[0]
            let decoded = try JSONDecoder().decode(MeetingInfo.self, from: JSONEncoder().encode(flight))
            var london = Calendar(identifier: .gregorian); london.timeZone = TimeZone(identifier: "Europe/London")!
            guard decoded == flight, london.component(.hour, from: flight.end!) == arrivalHour,
                  flight.end!.timeIntervalSince(flight.start) == 7 * 3600 else {
                throw AssistantFailure(message: "Flight zones/duration did not survive differing DST calendars")
            }
        }
        #endif
    }

    static func run(_ assistant: AssistantStore) async {
        var report: [String: Any] = ["passed": false, "run": AssistantVerification.runIdentifier,
            "bundle": Bundle.main.bundleIdentifier ?? "", "model": assistant.modelIdentity]
        let wellness = WellnessStore.shared
        let marker = "Pi workspace " + UUID().uuidString.prefix(6)
        var noteID: UUID?
        var mealID: UUID?
        do {
            try AssistantVerification.requireIsolatedBuild()
            try verifyAgendaTimes()
            report["agendaTimezoneAndFlightChecks"] = true
            for (instant, zone, expected) in [
                ("2026-11-03T04:59:00Z", "America/New_York", "2026-11-03"),
                ("2026-11-03T05:01:00Z", "America/New_York", "2026-11-04"),
                ("2026-11-03T04:59:00Z", "Asia/Tokyo", "2026-11-04"),
                ("2026-03-08T06:59:00Z", "America/New_York", "2026-03-09")
            ] {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: zone)!
                let now = try Date(instant, strategy: .iso8601)
                guard AssistantLocalDay.key("tmrw", now: now, calendar: calendar) == expected else {
                    throw AssistantFailure(message: "Relative day did not follow the execution clock")
                }
            }
            report["relativeDaysRefreshAcrossMidnightAndTimezones"] = true
            // Fixed clocks cover the evening regression independently of test run time.
            let cal = AssistantNutrition.calendar()
            let base = try AssistantNutrition.date("2026-11-02")
            let evening = cal.date(bySettingHour: 22, minute: 0, second: 0, of: base)!
            let morning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: base)!
            let fields: [String: Any] = ["kind": "event", "title": "Dinner", "time": "17:00"]
            let next = try AssistantWorkspace.prepare(fields, operation: UUID().uuidString, now: evening)
            let same = try AssistantWorkspace.prepare(fields, operation: UUID().uuidString, now: morning)
            let explicit = try AssistantWorkspace.prepare(fields.merging(["day": "today"]) { _, new in new }, operation: UUID().uuidString, now: evening)
            guard next.day == "2026-11-03", same.day == "2026-11-02", explicit.day == "2026-11-02" else {
                throw AssistantFailure(message: "Time-only events must use the next occurrence, preserving explicit days")
            }
            report["timeOnlyEventUsesNextOccurrence"] = true
            await wellness.whenLoaded()
            try await wait { assistant.available && assistant.selected != nil }
            report["model"] = assistant.modelIdentity
            await assistant.stop(); try await wait { !assistant.busy }
            let initialMeals = wellness.meals.count
            await assistant.newConversation()
            let mealTiming = try await send("Log a new meal for today: 2 eggs and 1 banana. Prepare it for review; do not save it yet.", assistant)
            guard let meal = assistant.workspace?.action, meal.kind == .meal,
                  meal.day == AssistantNutrition.key(Date()), meal.foods?.count == 2,
                  wellness.meals.count == initialMeals else { throw AssistantFailure(message: "New meal was not prepared without saving") }
            report["newMealFromWords"] = true; report["mealMilliseconds"] = mealTiming
            let resolved = AssistantWorkspace.mealItems(meal)
            guard resolved.count == 2, resolved.allSatisfy({ $0.macros.calories.isFinite }) else { throw AssistantFailure(message: "Native meal grounding failed") }
            report["nativeMealResolution"] = true
            try await assistant.verifyColdReopen()
            guard assistant.workspace?.action == meal else { throw AssistantFailure(message: "Cold reopen lost the meal draft") }
            report["mealDraftRestored"] = true
            // The same native commit path as the shared editor, with its stable Pi draft ID.
            guard let operation = UUID(uuidString: meal.id) else { throw AssistantFailure(message: "Missing meal identity") }
            mealID = operation
            let saved = MealEntry(id: operation, date: try AssistantNutrition.date(meal.day!), items: resolved.map { $0.asMealItem() }, source: .manual, name: meal.title)
            try wellness.addAssistantMeal(saved); try wellness.addAssistantMeal(saved)
            guard wellness.meals.filter({ $0.id == operation }).count == 1 else { throw AssistantFailure(message: "Meal save duplicated") }
            report["newMealSaveDeduplicated"] = true
            let stored = try JSONDecoder().decode(WellnessSnapshot.self, from: Data(contentsOf: AppSupport.directory.appendingPathComponent("wellness.json")))
            guard stored.meals.contains(where: { $0.id == operation }) else { throw AssistantFailure(message: "Meal save not persisted") }
            report["newMealSavePersisted"] = true
            await assistant.newConversation()
            guard assistant.workspace?.action == nil else { throw AssistantFailure(message: "Draft leaked into another conversation") }
            let eventRequest = "Create a calendar event called Pi Integration Lunch tomorrow at 13:00 for 30 minutes at Test Cafe. Prepare it for review, do not save."
            let eventTiming = try await send(eventRequest, assistant)
            guard let event = assistant.workspace?.action, event.kind == .event, event.sourceRequest == eventRequest,
                  let start = event.start.flatMap({ try? Date($0, strategy: .iso8601) }),
                  let end = event.end.flatMap({ try? Date($0, strategy: .iso8601) }),
                  Calendar.current.isDateInTomorrow(start), Calendar.current.component(.hour, from: start) == 13,
                  Calendar.current.component(.minute, from: start) == 0, end.timeIntervalSince(start) == 1800,
                  event.title.localizedCaseInsensitiveContains("Pi Integration Lunch") else { throw AssistantFailure(message: "The event draft has incorrect native date/time or title") }
            report["eventFromWords"] = true; report["eventMilliseconds"] = eventTiming
            try await assistant.verifyColdReopen()
            guard assistant.workspace?.action == event else { throw AssistantFailure(message: "Cold reopen changed event dates") }
            report["eventDraftRestored"] = true
            await assistant.dismissWorkspace()
            guard assistant.workspace?.action == nil else { throw AssistantFailure(message: "Dismiss did not clear the event draft") }
            report["nativeDraftDismissed"] = true
            await assistant.newConversation()
            let beforeDinner = Date()
            try await send("Dinner at 5pm", assistant)
            guard let dinner = assistant.workspace?.action, dinner.kind == .event,
                  let dinnerStart = dinner.start.flatMap({ try? Date($0, strategy: .iso8601) }),
                  dinnerStart > beforeDinner,
                  dinnerStart.timeIntervalSince(beforeDinner) <= 25 * 3600,
                  Calendar.current.component(.hour, from: dinnerStart) == 17 else {
                throw AssistantFailure(message: "Dinner at 5pm must prepare the next future 5pm")
            }
            report["timeOnlyEventFromWords"] = true
            await assistant.dismissWorkspace()
            let id = UUID(); noteID = id
            try VoiceNoteStore.shared.addAssistantNote(id: id, text: marker + " search evidence")
            await assistant.newConversation()
            try await send("Search Banana for \"\(marker)\".", assistant)
            guard let search = assistant.workspace?.action, search.kind == .search,
                  search.results?.contains(where: { $0.id == "note:\(id)" }) == true else { throw AssistantFailure(message: "Global search did not return the actual native note") }
            report["localSearchGrounded"] = true
            let routed = AssistantWorkspace.routedState(.notes, itemID: "note:\(id)", from: ShellState(), meals: wellness.meals)
            guard routed.notes == [id] else { throw AssistantFailure(message: "Search link did not select the real note") }
            report["searchUsesAppNavigation"] = true
            await assistant.newConversation()
            try await send("Open the Nutrition page.", assistant)
            guard assistant.workspace?.action?.kind == .navigation, assistant.workspace?.action?.section == "nutrition" else { throw AssistantFailure(message: "Page navigation was not offered") }
            report["pageNavigation"] = true
            // A nutrition chart replaces an older action card in the same conversation.
            try await send("Show my protein this month", assistant)
            guard assistant.surface?.metric == .protein, assistant.workspace?.action == nil else { throw AssistantFailure(message: "Nutrition did not supersede the prior workspace") }
            report["workspaceTransitions"] = true
            var rejected = 0
            let invalidFields: [[String: Any]] = [
                ["kind": "event", "title": "Bad", "time": "25:00"],
                ["kind": "event", "title": "Bad", "time": "13:00", "durationMinutes": 0],
                ["kind": "event", "title": "Bad", "time": "13:00", "relativeDay": "date", "day": "2026-02-30"],
                ["kind": "meal", "foods": []], ["kind": "navigation", "section": "unknown"]
            ]
            for fields in invalidFields {
                do { _ = try AssistantWorkspace.prepare(fields, operation: UUID().uuidString) }
                catch { rejected += 1 }
            }
            guard rejected == 5 else { throw AssistantFailure(message: "Native workspace validation accepted malformed fields") }
            report["nativeInvalidInputsRejected"] = rejected
            // Exercise the ambiguity missed by smaller models in one-turn probes,
            // through Pi's actual tool validation and continuation loop.
            await assistant.newConversation()
            try await send("Create an event called Pi Integration Dinner tomorrow.", assistant, allowRecoveredToolError: true)
            let clarification = assistant.messages.last(where: { $0.role == "assistant" })?.text ?? ""
            guard assistant.workspace?.action == nil,
                  clarification.localizedCaseInsensitiveContains("time") || clarification.localizedCaseInsensitiveContains("when") else {
                throw AssistantFailure(message: "An event without a chosen time did not ask for clarification without a draft")
            }
            report["missingTimeClarifiedWithoutDraft"] = true
            report["clarificationToolErrors"] = assistant.messages.filter { $0.role == "error" }.count
            try await send("At 19:00 for 45 minutes.", assistant)
            guard let dinner = assistant.workspace?.action, dinner.kind == .event,
                  let start = dinner.start.flatMap({ try? Date($0, strategy: .iso8601) }),
                  let end = dinner.end.flatMap({ try? Date($0, strategy: .iso8601) }),
                  Calendar.current.isDateInTomorrow(start), Calendar.current.component(.hour, from: start) == 19,
                  Calendar.current.component(.minute, from: start) == 0, end.timeIntervalSince(start) == 2700,
                  dinner.title.localizedCaseInsensitiveContains("Pi Integration Dinner") else {
                throw AssistantFailure(message: "The clarification follow-up lost the event details")
            }
            report["eventClarificationContinuation"] = true
            report["conversationIsolation"] = true
            #if PI_DEVELOPMENT
            OccurrenceStore.shared.injectSampleForPreview(meetings: PiSampleData.flights())
            #else
            OccurrenceStore.shared.injectSampleForPreview(meetings: [])
            #endif
            await assistant.newConversation()
            await assistant.updateSurface(["period": "this_month", "metric": "protein"])
            try await send("What is going on tomorrow?", assistant)
            guard let agenda = assistant.messages.compactMap(\.agenda).last,
                  agenda.date == AssistantNutrition.key(Calendar.current.date(byAdding: .day, value: 1, to: Date())!),
                  agenda.timeZone == TimeZone.current.identifier, assistant.surface == nil,
                  assistant.workspace?.action == nil else {
                throw AssistantFailure(message: "Tomorrow must produce a native agenda in the device timezone")
            }
            try await assistant.verifyColdReopen()
            guard assistant.messages.contains(where: { $0.agenda == agenda }) else {
                throw AssistantFailure(message: "Agenda did not survive conversation reopen")
            }
            report["nativeAgendaFromWordsAndRestored"] = true
            let noteCount = VoiceNoteStore.shared.notes.count
            let reviewedText = "Review before saving " + marker
            await assistant.newConversation()
            let noteRequest = "Create a note with this exact text: \"\(reviewedText)\""
            try await send(noteRequest, assistant)
            guard let noteDraft = assistant.workspace?.action, noteDraft.kind == .note,
                  noteDraft.notes == reviewedText, noteDraft.sourceRequest == noteRequest, let reviewedID = UUID(uuidString: noteDraft.id),
                  VoiceNoteStore.shared.notes.count == noteCount else {
                throw AssistantFailure(message: "Preparing a note must not silently save a record")
            }
            defer { VoiceNoteStore.shared.delete(reviewedID) }
            try await assistant.verifyColdReopen()
            guard assistant.workspace?.action == noteDraft else { throw AssistantFailure(message: "Note review draft was not restored") }
            try VoiceNoteStore.shared.addAssistantNote(id: reviewedID, text: reviewedText)
            try VoiceNoteStore.shared.addAssistantNote(id: reviewedID, text: reviewedText)
            guard VoiceNoteStore.shared.notes.filter({ $0.id == reviewedID }).count == 1 else {
                throw AssistantFailure(message: "Saving the reviewed note duplicated it")
            }
            report["noteDraftDoesNotWrite"] = true
            report["noteReviewedSaveDeduplicated"] = true
            let activitiesBefore = assistant.messages.filter { $0.role == "activity" }.count
            try await send("Pause my podcast.", assistant)
            let unrelatedReply = assistant.messages.last(where: { $0.role == "assistant" })?.text ?? ""
            guard assistant.workspace?.action == noteDraft,
                  assistant.messages.filter({ $0.role == "activity" }).count == activitiesBefore,
                  unrelatedReply.contains("can’t") || unrelatedReply.contains("cannot") || unrelatedReply.contains("can't") else {
                throw AssistantFailure(message: "An unrelated unsupported request changed the existing draft or its provenance")
            }
            report["draftProvenanceSurvivesUnrelatedRequest"] = true


            #if PI_DEVELOPMENT
            let flight = PiSampleData.flights()[0]
            await assistant.newConversation()
            let flightDay = AssistantNutrition.key(flight.start)
            try await send("What is on my schedule on \(flightDay)?", assistant)
            guard let travel = assistant.messages.compactMap(\.agenda).last,
                  let displayed = travel.items.first(where: { $0.title == flight.title }),
                  displayed.startTimeZone == "America/New_York", displayed.endTimeZone == "Europe/London",
                  displayed.start == flight.start.ISO8601Format(), displayed.end == flight.end!.ISO8601Format() else {
                throw AssistantFailure(message: "Flight agenda lost an instant or source timezone")
            }
            report["flightAgendaFromWords"] = true
            #endif
            // These are outcome classes, not exact copies of the development corpus.
            let blockedRequests = [
                "Please cancel my appointment with the optometrist tomorrow.",
                "Record that I completed my stretching routine.",
                "I ran for twenty minutes. Add it to my workout history.",
                "Make a recurring calendar event every Friday at noon for lunch.",
                "Add a flight from New York to London tomorrow, departing 8pm New York and arriving 8am London the following day.",
                "Update my latest note to say Pack light.",
                "How many hours did I sleep yesterday?"
            ]
            let beforeNotes = VoiceNoteStore.shared.notes.count
            let beforeMeals = wellness.meals.count
            for words in blockedRequests {
                await assistant.newConversation()
                try await send(words, assistant)
                let answer = assistant.messages.last(where: { $0.role == "assistant" })?.text ?? ""
                guard assistant.workspace?.action == nil, assistant.surface == nil,
                      !assistant.messages.contains(where: { $0.role == "activity" }),
                      answer.contains("can’t") || answer.contains("cannot") || answer.contains("can't") else {
                    throw AssistantFailure(message: "Unavailable outcome produced an unrelated tool or unsupported promise: \(words)")
                }
            }
            guard VoiceNoteStore.shared.notes.count == beforeNotes, wellness.meals.count == beforeMeals else {
                throw AssistantFailure(message: "Unavailable requests changed records")
            }
            report["unavailableOutcomesHaveNoToolEffects"] = blockedRequests.count
            await assistant.newConversation()
            try await send("I ate some rice. Ask me how much before preparing a meal.", assistant)
            guard assistant.workspace?.action == nil,
                  assistant.messages.last(where: { $0.role == "assistant" })?.text.localizedCaseInsensitiveContains("how much") == true else {
                throw AssistantFailure(message: "Missing meal amount did not ask for clarification")
            }
            report["missingMealAmountDoesNotDraft"] = true
            report["externalCalendarWritesAttempted"] = false
            report["passed"] = true
        } catch { report["error"] = error.localizedDescription; report["assistantError"] = assistant.error ?? "" }
        if let noteID { VoiceNoteStore.shared.delete(noteID) }
        if let mealID { wellness.deleteMeal(mealID) }
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: AssistantVerification.reportURL("pi-app-integration.json"), options: .atomic) }
        catch { print("Could not save workspace report: \(error)") }
        AssistantVerification.finishHeadless(passed: report["passed"] as? Bool == true)
    }

    @discardableResult private static func send(_ text: String, _ assistant: AssistantStore, allowRecoveredToolError: Bool = false) async throws -> Int {
        let start = Date(), revision = assistant.workspace?.revision
        let surfaceRevision = assistant.surface?.revision
        let messages = assistant.messages
        let assistantCount = messages.filter { $0.role == "assistant" || $0.role == "agenda" || $0.role == "error" }.count
        guard await assistant.send(text) else { throw AssistantFailure(message: assistant.error ?? "Input not admitted") }
        try await wait { !assistant.busy && (assistant.messages.filter { $0.role == "assistant" || $0.role == "agenda" || $0.role == "error" }.count > assistantCount || assistant.workspace?.revision != revision || assistant.surface?.revision != surfaceRevision) }
        if let error = assistant.error { throw AssistantFailure(message: error) }
        if !allowRecoveredToolError && assistant.messages.contains(where: { $0.role == "error" && !messages.contains($0) }) {
            throw AssistantFailure(message: assistant.messages.last(where: { $0.role == "error" })?.text ?? "Tool failed")
        }
        return Int(Date().timeIntervalSince(start) * 1000)
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(120)
        while !condition() {
            guard Date() < deadline else { throw AssistantFailure(message: "Timed out waiting for integrated workspace") }
            try await Task.sleep(for: .milliseconds(75))
        }
    }
}
#endif

#endif
