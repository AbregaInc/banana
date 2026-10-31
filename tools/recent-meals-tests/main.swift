import Foundation

var checks = 0
func expect(_ condition: Bool, _ name: String) {
    guard condition else { fatalError("FAILED: " + name) }
    checks += 1
}
let now = Date(timeIntervalSince1970: 1_792_700_000)
let item = MealItem(name: "Greek yogurt", serving: "200 g", macros: .init(calories: 150, proteinGrams: 20, carbohydrateGrams: 10, fatGrams: 4), confidence: 0.8, grams: 200)
let past = MealEntry(date: now.addingTimeInterval(-86_400), items: [item], note: "Breakfast yesterday", source: .photo, name: "Café breakfast", photoIDs: [UUID()])
let copy = RecentMeals.entry(from: past, at: now)
expect(copy.id != past.id && copy.items[0].id != item.id, "copy has independent entry and item identities")
expect(copy.date == now && past.date != now, "copy uses requested time; original unchanged")
expect(copy.items[0].macros == item.macros && copy.items[0].grams == item.grams && copy.items[0].serving == item.serving, "copy preserves nutrition and portions")
expect(copy.items[0].confidence == 0.8, "uncertain estimates do not gain confidence")
expect(copy.photoIDs.isEmpty && copy.estimate == nil && copy.source == .manual && copy.note.isEmpty, "old photo and dated phrase are not new evidence")
expect(RecentMeals.choices(in: [past, copy], query: "").map(\.id) == [copy.id], "same meal repeated is offered once, newest first")
expect(RecentMeals.choices(in: [past], query: "cafe YOGURT").count == 1, "name and food tokens search live without accents/case")
expect(RecentMeals.choices(in: [past], query: "chicken").isEmpty, "nonmatches are excluded")
expect(RecentMeals.choices(in: [past], query: "", hiddenIDs: [past.id.uuidString]).isEmpty, "pending deletions are excluded")
var larger = copy; larger.id = UUID(); larger.items[0] = item.withGrams(300)
expect(RecentMeals.choices(in: [past, larger], query: "").count == 2, "different portions remain separate choices")
let empty = MealEntry(items: [], name: "Empty")
expect(RecentMeals.choices(in: [empty], query: "").isEmpty, "empty entries cannot be repeated")
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("banana-meal-repeat-" + UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let url = folder.appendingPathComponent("wellness.json")
var before = WellnessSnapshot(); before.meals = [past]
try JSONEncoder().encode(before).write(to: url)
var after = before; after.meals.insert(copy, at: 0)
let staged = try MealRepeatPersistence.stage(after, beside: url)
expect(try JSONDecoder().decode(WellnessSnapshot.self, from: Data(contentsOf: url)).meals == [past], "staging cannot alter saved history")
try MealRepeatPersistence.commit(staged, replacing: url)
expect(try JSONDecoder().decode(WellnessSnapshot.self, from: Data(contentsOf: url)).meals == [copy, past], "atomic commit retains original and new log")
expect(!FileManager.default.fileExists(atPath: staged.path), "commit consumes staging file")
let retry = try MealRepeatPersistence.stage(before, beside: url)
do { try MealRepeatPersistence.commit(retry, replacing: folder.appendingPathComponent("missing/file")); fatalError("commit should fail") } catch {}
expect(FileManager.default.fileExists(atPath: retry.path), "failed commit retains retry input")
expect(try JSONDecoder().decode(WellnessSnapshot.self, from: Data(contentsOf: url)).meals == [copy, past], "failed commit never changes existing history")
try MealRepeatPersistence.commit(retry, replacing: url)
expect(try JSONDecoder().decode(WellnessSnapshot.self, from: Data(contentsOf: url)).meals == [past], "durable Undo restores previous saved contents")
do { _ = try MealRepeatPersistence.stage(before, beside: folder.appendingPathComponent("missing/file")); fatalError("stage should fail") } catch {}
expect(try JSONDecoder().decode(WellnessSnapshot.self, from: Data(contentsOf: url)).meals == [past], "failed staging leaves saved contents alone")
let abandoned = try MealRepeatPersistence.stage(after, beside: url)
let unrelated = folder.appendingPathComponent(".meal-not-ours.tmp"); try Data("keep".utf8).write(to: unrelated)
MealRepeatPersistence.cleanAbandonedStages(beside: url, before: Date(timeIntervalSince1970: 0))
expect(FileManager.default.fileExists(atPath: abandoned.path), "startup cleanup cannot remove a newer in-flight stage")
MealRepeatPersistence.cleanAbandonedStages(beside: url)
expect(!FileManager.default.fileExists(atPath: abandoned.path) && FileManager.default.fileExists(atPath: unrelated.path), "crash cleanup removes only owned staging files")
var history = before
history.meals = (0..<2_001).map { index in var meal = copy; meal.id = UUID(); meal.date = now.addingTimeInterval(Double(-index)); return meal }
let retained = try MealRepeatPersistence.stage(history, beside: url)
try MealRepeatPersistence.commit(retained, replacing: url)
expect(try JSONDecoder().decode(WellnessSnapshot.self, from: Data(contentsOf: url)).meals.count == 2_001, "durable history is not capped at 1500")
print("Passed \(checks) recent-meal correctness and persistence checks")
