#!/usr/bin/env node
/* Banana feed client: AGPL-3.0-only. Source and license: https://github.com/AbregaInc/banana
Bundled fflate license follows:
MIT License

Copyright (c) 2026 Arjun Barrett

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

// public/app/assets/workout-model.js
var swiftMillis = (v) => typeof v === "number" ? (v + 978307200) * 1e3 : v;
var pausedSeconds = (f) => (f.pauses ?? []).reduce((n2, p) => n2 + Math.max(0, p.end - p.start), 0);
var activeSeconds = (f) => Math.max(0, ((f.end ?? f.start) - f.start) / 1e3 - pausedSeconds(f));
function sourceRank(w, ownBundleID) {
  if (ownBundleID && w.sourceBundleID === ownBundleID) return 100;
  const s = String(w.source ?? "").toLowerCase();
  if (s === "banana") return 95;
  if (s.includes("apple watch") || s.includes("apple\xA0watch")) return 90;
  if (s.includes("workoutdoors")) return 80;
  if (["nike", "slopes", "daypart"].some((x2) => s.includes(x2))) return 70;
  if (s.includes("strava")) return 40;
  if (s.includes("whoop")) return 20;
  return 50;
}
var completeness = (w) => ((w.distanceMeters ?? 0) > 0 ? 4 : 0) + (w.avgHeartRate != null ? 2 : 0) + ((w.energyKcal ?? 0) > 0 ? 1 : 0);
function prefers(a, b, own) {
  const ar = sourceRank(a, own), br = sourceRank(b, own);
  if (ar !== br) return ar > br;
  const ac = completeness(a), bc = completeness(b);
  return ac !== bc ? ac > bc : String(a.id) < String(b.id);
}
function mergeWorkouts(records, payload, ownBundleID) {
  const summaries = records.map((r) => ({ ...r.fields, id: r.id })), hidden = new Set(payload?.hiddenWorkoutIDs ?? []);
  const health = (payload?.workouts ?? []).filter((w) => !hidden.has(w.id)).map((w) => ({ ...w, start: swiftMillis(w.start), end: swiftMillis(w.end) }));
  const buckets = [];
  const start = (e) => e.health?.start ?? e.summary?.start;
  const near = (t) => buckets.map((e, i2) => ({ i: i2, d: Math.abs(start(e) - t) })).filter((e) => e.d < 9e4).sort((a, b) => a.d - b.d)[0]?.i;
  for (const s of summaries) if (near(s.start) == null) buckets.push({ summary: s, health: null });
  for (const w of health) {
    const i2 = near(w.start);
    if (i2 == null) buckets.push({ health: w, summary: null });
    else if (!buckets[i2].health || prefers(w, buckets[i2].health, ownBundleID)) buckets[i2].health = w;
  }
  return buckets.map(({ health: h, summary: s }) => ({ id: s?.id ?? h.id, type: "workout.entry", summary: s, health: h, fields: {
    ...s,
    activity: h?.activity ?? s?.activity ?? "Workout",
    start: h?.start ?? s?.start,
    end: h?.end ?? s?.end,
    durationSeconds: h?.duration ?? activeSeconds(s),
    totalDistance: h?.distanceMeters ?? s?.totalDistance,
    totalEnergy: h?.energyKcal ?? s?.totalEnergy,
    avgHeartRate: h?.avgHeartRate ?? s?.avgHeartRate,
    maxHeartRate: h?.maxHeartRate,
    source: h?.source ?? "Banana",
    poolLengthMeters: s?.poolLengthMeters ?? h?.lapLengthMeters
  } })).sort((a, b) => b.fields.start - a.fields.start);
}

// public/app/assets/analysis-schema.js
var col = (type, description, unit = null, references = null) => ({ type, description, ...unit ? { unit } : {}, ...references ? { references } : {} });
var text = (description) => col("string", description);
var date = (description) => col("string", description, "ISO 8601 UTC");
var number = (description, unit) => col("number", description, unit);
var ref = (description, table) => col("string", description, null, table + ".id");
var macros = { energy_kcal: number("Food energy", "kcal"), protein_g: number("Protein", "g"), carbohydrate_g: number("Carbohydrates", "g"), fat_g: number("Fat", "g") };
var analysisSchema = {
  schema: "banana.analysis.v1",
  conventions: { null: "Unknown or absent, never inferred as zero.", dates: "UTC ISO 8601 strings; local calendar days remain YYYY-MM-DD and are not shifted to UTC.", ids: "Opaque case-sensitive strings. Join only through documented reference columns. IDs are stable within their source type.", numbers: "Decimal SI units except explicitly named kcal, bpm, hours, minutes, percent and counts.", scope: "Only selected feed types within the current grant and consent. Tables with no selected source types are omitted; selected empty datasets have headers and zero rows.", workouts: "Use workouts for counts and totals, not sourceRecords. Matches the shared website merge: starts less than 90 seconds apart pair, nearest start first; Health source ranking and completeness break ties. Summary ID wins; Health metrics take precedence. Workout plans/completions are not extra recorded workouts.", raw: "sourceRecords preserves every fetched source record. It is provenance, not an additional set of observations to sum.", versioning: "Additive columns may be introduced. Breaking unit/meaning/type changes require a new schema version. Consumers must ignore unknown columns.", consistency: "A complete pull checks contentVersion, access, selected types and workout preference on every page and again at the end. Calendar is a live external window, not an atomic transaction with synced records.", assets: "Credential-based asset URLs are private, expire within one hour and recheck access. Session-export asset URLs require the signed-in recipient/owner session, have null expiry, and stop working when session or access ends. Local archive paths remain readable offline. Downloaded copies cannot be revoked." },
  tables: {
    meals: { description: "One row per logged meal. Totals sum logged item macros, not per-100g reference values.", columns: { id: text("Meal record ID"), date: date("Logged meal instant"), name: text("Meal label"), note: text("Meal note"), source: text("manual, photo, barcode or text; preserve future values"), ...macros } },
    meal_items: { description: "One row per food item in a meal; do not add these totals to meal totals.", columns: { id: text("Item ID, or meal ID plus index when absent"), meal_id: ref("Parent meal", "meals"), position: number("Zero-based item position", "index"), name: text("Food name"), serving: text("Entered serving description"), grams: number("Logged portion weight", "g"), confidence: number("Confidence in food identification, not portion size", "fraction 0\u20131"), reference_id: text("Source food ID, for example myfood:<id>; not necessarily a shared saved food"), ...macros } },
    meal_photos: { description: "Links meals to available photo assets; multiple meals can refer to a photo.", columns: { meal_id: ref("Parent meal", "meals"), photo_id: text("Photo record ID"), asset_id: ref("Image asset", "assets") } },
    saved_foods: { description: "Nutrition values are per 100 g, not for the usual serving.", columns: { id: text("Saved food record ID"), name: text("Food name"), added_at: date("Creation instant"), serving_label: text("Usual serving description"), serving_g: number("Usual serving weight", "g"), package_g: number("Package weight", "g"), ...macros } },
    workouts: { description: "Merged recorded and Health workouts; same selection rules as the shared website. Not a medical or training score.", columns: { id: text("Stable summary ID when present, otherwise Health workout ID"), summary_id: text("Source health.workout ID; nullable"), health_id: text("Source Health workout ID; nullable"), activity: text("Source activity label"), start: date("Workout start"), end: date("Workout end"), duration_s: number("Active duration; Health duration wins, otherwise recorded elapsed minus pauses", "s"), distance_m: number("Total distance", "m"), energy_kcal: number("Active workout energy", "kcal"), avg_hr_bpm: number("Average heart rate", "bpm"), max_hr_bpm: number("Maximum heart rate, when Health supplies it", "bpm"), source: text("Chosen Health source or Banana"), pool_length_m: number("Pool or lap length", "m") } },
    workout_plans: { description: "Prescribed plans, not completed sessions.", columns: { id: text("Plan record ID"), title: text("Plan title"), created_at: date("Creation instant"), focus: text("strength, mobility, mixed; preserve future values"), target_minutes: number("Planned duration", "min"), rationale: text("Plan rationale") } },
    workout_exercises: { description: "Prescriptions in a workout plan.", columns: { id: text("Prescription ID or plan ID plus index"), plan_id: ref("Parent plan", "workout_plans"), position: number("Zero-based exercise position", "index"), exercise_id: text("Exercise catalog identifier"), sets: number("Prescribed sets", "count"), reps: number("Prescribed repetitions per set", "count"), duration_s: number("Prescribed time per set", "s"), rest_s: number("Rest between sets", "s") } },
    workout_completions: { description: "Plan-session completion records; do not add to recorded workout totals.", columns: { id: text("Completion record ID"), plan_id: ref("Referenced plan, possibly outside selected types", "workout_plans"), start: date("Session start"), end: date("Session end") } },
    completed_exercises: { description: "Exercise IDs checked off in a completed plan session.", columns: { completion_id: ref("Parent completion", "workout_completions"), exercise_id: text("Completed prescription ID") } },
    health_readings: { description: "Daily source measurements, not intraday samples. Body fat is normalized from a fraction to percent. No new aggregate or missing-day zero is invented.", columns: { snapshot_id: text("Source snapshot ID"), metric: text("Metric identifier; see metrics"), date: date("Source measurement instant; local day depends on consumer timezone"), value: number("Normalized source value", "see unit"), unit: text("Explicit measurement unit") } },
    sleep_nights: { description: "Source sleep-night summaries; not inferred from missing readings.", columns: { snapshot_id: text("Source snapshot ID"), id: text("Source snapshot ID plus night timestamp"), night: date("Morning the night belongs to"), bedtime: date("Sleep period start"), wake: date("Sleep period end"), asleep_min: number("Minutes asleep", "min") } },
    sleep_wakes: { description: "Awake stretches within a night.", columns: { night_id: ref("Parent night", "sleep_nights"), start: date("Wake stretch start"), end: date("Wake stretch end"), steps: number("Steps during stretch", "count"), kind: text("Source classification; preserve future values"), labelled: col("boolean", "Whether the owner supplied the label") } },
    routines: { description: "Routine definitions; no future occurrences or completion is inferred. Actual overrides are in routine_overrides.", columns: { id: text("Routine ID"), name: text("Routine name"), enabled: col("boolean", "Enabled state"), trigger: text("time, earliestMeeting, workoutStart, wakeUp, calendarMatch or manual; preserve future values"), hour: number("Fallback local clock hour", "0\u201323"), minute: number("Fallback local clock minute", "0\u201359"), duration_min: number("Nominal duration", "min"), lead_min: number("calendarMatch: minutes before the matching event; wakeUp: minutes after waking. Other triggers retain this field without implying a scheduled offset.", "min") } },
    routine_slots: { description: "Primary and additional routine time slots. weekday null means every day; 1=Sunday through 7=Saturday.", columns: { routine_id: ref("Parent routine", "routines"), slot_id: text("main or extra-slot ID"), weekday: number("Scheduled weekday, null for every day", "1\u20137"), hour: number("Local clock hour", "0\u201323"), minute: number("Local clock minute", "0\u201359") } },
    routine_keywords: { description: "Calendar-match keywords; only useful when relevant calendar events are also shared.", columns: { routine_id: ref("Parent routine", "routines"), keyword: text("Match keyword") } },
    alarms: { description: "One-off alarm definitions.", columns: { id: text("Alarm record ID"), label: text("Alarm label"), fire: date("Alarm instant") } },
    plan_extras: { description: "Additional routine occurrences.", columns: { id: text("Extra occurrence ID"), routine_id: ref("Routine reference", "routines"), start: date("Scheduled instant") } },
    routine_overrides: { description: "Explicit skip, reschedule or completion; ID encodes routine|slot|local-day. No row means no recorded override, not necessarily incomplete.", columns: { id: text("Override ID"), routine_id: ref("Routine reference", "routines"), slot_id: text("Slot ID"), local_day: text("YYYY-MM-DD local day from override ID"), status: text("completed, skipped, rescheduled or other"), completed_at: date("Recorded completion instant"), scheduled_start: date("Completed occurrence scheduled instant"), rescheduled_to: date("New scheduled instant") } },
    wake_days: { description: "Synced wake-plan days; no new schedule is generated by export.", columns: { plan_id: text("Source wake-plan ID"), date: date("Source planned day instant"), wake: date("Planned wake instant") } },
    calendar_events: { description: "Selected live calendar window. Busy-only records remain redacted. All-day end dates are exclusive.", columns: { id: text("Projected event ID"), title: text("Shared title or busy label"), start: date("Timed event start, null for all-day"), end: date("Timed event end, null for all-day"), start_day: text("All-day YYYY-MM-DD start"), end_day: text("Exclusive all-day YYYY-MM-DD end"), all_day: col("boolean", "All-day state"), calendar: text("Shared calendar label, nullable for redacted data"), location: text("Shared location, if permitted") } },
    assets: { description: "Private source attachments; file_path is populated only for images included in this archive.", columns: { id: text("Source type:record:field key"), record_type: text("Source record type"), record_id: text("Source record ID"), field: text("Source blob field"), url: text("Private expiring URL"), expires_at: date("URL expiry; null for authenticated session exports or owner preview"), file_path: text("Relative archive path, when downloaded"), media_type: text("Downloaded MIME type, when available") } }
  },
  metrics: { sleepHours: "hours", restingHR: "bpm", hrv: "ms", steps: "steps", vo2Max: "mL/kg/min", respiratory: "/min", bodyMassKg: "kg", bodyFatPercentage: "%", activeEnergyKcal: "kcal", exerciseMinutes: "min", walkingHeartRate: "bpm", basalEnergyKcal: "kcal", leanBodyMassKg: "kg", bodyMassIndex: "kg/m\xB2", heightMeters: "m", flightsClimbed: "flights", walkingSpeedMetersPerSecond: "m/s" }
};

// public/app/assets/analysis-model.js
var iso = (value, swift = false) => {
  if (value == null || !["string", "number"].includes(typeof value)) return null;
  const ms = swift ? swiftMillis(value) : value;
  const date2 = new Date(ms);
  return Number.isFinite(+date2) ? date2.toISOString() : null;
};
var n = (value) => typeof value === "number" && Number.isFinite(value) ? value : null;
var macroNames = { energy_kcal: "calories", protein_g: "proteinGrams", carbohydrate_g: "carbohydrateGrams", fat_g: "fatGrams" };
var macros2 = (f) => Object.fromEntries(Object.entries(macroNames).map(([to, from]) => [to, n(f?.[from])]));
var assetKey = (a) => `${a.type}:${a.id}:${a.field}`;
function normalizeAnalysis(records, { ownBundleID = null, access = null, types = [...new Set(records.map((r) => r.type))] } = {}) {
  const selected = new Set(types), tables = {}, warnings = [];
  const group = (type) => records.filter((r) => r.type === type);
  const add = (table, row) => {
    const columns = analysisSchema.tables[table].columns;
    (tables[table] ??= []).push(Object.fromEntries(Object.entries(columns).map(([key, column]) => {
      const value = row[key] ?? null;
      if (value !== null && (typeof value !== column.type || column.type === "number" && !Number.isFinite(value))) {
        const warning = `Invalid ${table}.${key} value was left null; the original remains in sourceRecords.`;
        if (!warnings.includes(warning)) warnings.push(warning);
        return [key, null];
      }
      return [key, value];
    })));
  };
  const enable = (source, names) => {
    if (source.some((t) => selected.has(t))) for (const name of names) tables[name] = [];
  };
  enable(["food.meal"], ["meals", "meal_items", "meal_photos"]);
  enable(["food.myFood"], ["saved_foods"]);
  enable(["health.workout", "health.snapshot"], ["workouts"]);
  enable(["health.workoutPlan"], ["workout_plans", "workout_exercises"]);
  enable(["health.workoutCompletion"], ["workout_completions", "completed_exercises"]);
  enable(["health.snapshot"], ["health_readings", "sleep_nights", "sleep_wakes"]);
  enable(["plan.routine"], ["routines", "routine_slots", "routine_keywords"]);
  enable(["plan.alarm"], ["alarms"]);
  enable(["plan.extra"], ["plan_extras"]);
  enable(["plan.override"], ["routine_overrides"]);
  enable(["core.wakePlan"], ["wake_days"]);
  enable(["calendar"], ["calendar_events"]);
  tables.assets = [];
  const seenAssets = /* @__PURE__ */ new Set();
  for (const r of records) for (const a of r.assets ?? []) {
    const id = assetKey(a);
    if (seenAssets.has(id)) continue;
    seenAssets.add(id);
    add("assets", { id, record_type: a.type, record_id: a.id, field: a.field, url: a.url, expires_at: a.expiresAt });
  }
  for (const r of group("food.meal")) {
    const f = r.data, items = f.items ?? [];
    const totals = Object.fromEntries(Object.keys(macroNames).map((k) => {
      const a = items.map((i2) => macros2(i2.macros)[k]).filter((v) => v != null);
      return [k, a.length === items.length && a.length ? a.reduce((a2, b) => a2 + b, 0) : null];
    }));
    add("meals", { id: r.id, date: iso(f.date), name: f.name, note: f.note, source: f.source, ...totals });
    items.forEach((i2, index) => add("meal_items", { id: i2.id ?? `${r.id}:${index}`, meal_id: r.id, position: index, name: i2.name, serving: i2.serving, grams: n(i2.grams), confidence: n(i2.confidence), reference_id: i2.reference?.id, ...macros2(i2.macros) }));
    for (const id of f.photoIDs ?? []) add("meal_photos", { meal_id: r.id, photo_id: id, asset_id: seenAssets.has(`food.mealPhoto:${id}:v`) ? `food.mealPhoto:${id}:v` : null });
  }
  for (const r of group("food.myFood")) {
    const f = r.data;
    add("saved_foods", { id: r.id, name: f.name, added_at: iso(f.addedAt), serving_label: f.servingLabel, serving_g: n(f.servingGrams), package_g: n(f.packageGrams), ...macros2(f.per100g) });
  }
  const snapshots = group("health.snapshot");
  if (snapshots.length > 1) warnings.push("Multiple Health snapshots were returned; workouts use the first snapshot in feed record order, as the shared website does. All snapshots remain in sourceRecords.");
  const snapshot = snapshots[0]?.data ?? null;
  const invalidSummaries = group("health.workout").filter((r) => n(r.data.start) == null);
  if (invalidSummaries.length) throw new Error("A recorded workout has an invalid start time. No partial analysis export was saved.");
  if ((snapshot?.workouts ?? []).some((w) => n(w.start) == null || n(w.end) == null)) throw new Error("A Health workout has invalid dates. No partial analysis export was saved.");
  const summaries = group("health.workout").filter((r) => n(r.data.start) != null).map((r) => ({ id: r.id, fields: r.data }));
  const payload = snapshot ? { ...snapshot, workouts: (snapshot.workouts ?? []).filter((w) => n(w.start) != null && n(w.end) != null) } : null;
  for (const r of mergeWorkouts(summaries, payload, ownBundleID)) {
    const f = r.fields;
    add("workouts", { id: r.id, summary_id: r.summary?.id, health_id: r.health?.id, activity: f.activity, start: iso(f.start), end: iso(f.end), duration_s: n(f.durationSeconds), distance_m: n(f.totalDistance), energy_kcal: n(f.totalEnergy), avg_hr_bpm: n(f.avgHeartRate), max_hr_bpm: n(f.maxHeartRate), source: f.source, pool_length_m: n(f.poolLengthMeters) });
  }
  if (snapshot) {
    const id = snapshots[0].id;
    for (const [key, points] of Object.entries(snapshot.trends ?? {})) {
      if (key === "nights") continue;
      if (!Object.hasOwn(analysisSchema.metrics, key)) {
        warnings.push(`Unrecognized Health metric ${key} is retained in sourceRecords only.`);
        continue;
      }
      for (const p of points ?? []) if (n(p.date) != null && n(p.value) != null) add("health_readings", { snapshot_id: id, metric: key, date: iso(p.date, true), value: p.value * (key === "bodyFatPercentage" ? 100 : 1), unit: analysisSchema.metrics[key] });
    }
    for (const night of snapshot.trends?.nights ?? []) {
      const nid = `${id}:${night.night ?? night.wake}`;
      add("sleep_nights", { snapshot_id: id, id: nid, night: iso(night.night, true), bedtime: iso(night.bedtime, true), wake: iso(night.wake, true), asleep_min: n(night.asleepMinutes) });
      for (const w of night.wakes ?? []) add("sleep_wakes", { night_id: nid, start: iso(w.start, true), end: iso(w.end, true), steps: n(w.steps), kind: w.kind, labelled: w.labelled });
    }
  }
  for (const r of group("health.workoutPlan")) {
    const f = r.data;
    add("workout_plans", { id: r.id, title: f.title, created_at: iso(f.createdAt), focus: f.focus, target_minutes: n(f.targetMinutes), rationale: f.rationale });
    (f.exercises ?? []).forEach((e, i2) => add("workout_exercises", { id: e.id ?? `${r.id}:${i2}`, plan_id: r.id, position: i2, exercise_id: e.exerciseID, sets: n(e.sets), reps: n(e.reps), duration_s: n(e.durationSeconds), rest_s: n(e.restSeconds) }));
  }
  for (const r of group("health.workoutCompletion")) {
    const f = r.data;
    add("workout_completions", { id: r.id, plan_id: f.planID, start: iso(f.startedAt), end: iso(f.endedAt) });
    for (const id of f.completedExerciseIDs ?? []) add("completed_exercises", { completion_id: r.id, exercise_id: id });
  }
  for (const r of group("plan.routine")) {
    const f = r.data;
    add("routines", { id: r.id, name: f.name, enabled: f.enabled, trigger: f.triggerKind, hour: n(f.hour), minute: n(f.minute), duration_min: n(f.durationMinutes), lead_min: n(f.leadMinutes) });
    for (const s of [{ id: "main", hour: f.hour, minute: f.minute, weekdays: f.weekdays }, ...f.extraSlots ?? []]) for (const day of s.weekdays?.length ? s.weekdays : [null]) add("routine_slots", { routine_id: r.id, slot_id: s.id, weekday: day, hour: n(s.hour), minute: n(s.minute) });
    for (const keyword of f.matchKeywords ?? []) add("routine_keywords", { routine_id: r.id, keyword });
  }
  for (const r of group("plan.alarm")) add("alarms", { id: r.id, label: r.data.label, fire: iso(r.data.fire) });
  for (const r of group("plan.extra")) add("plan_extras", { id: r.id, routine_id: r.data.seriesID, start: iso(r.data.start) });
  for (const r of group("plan.override")) {
    const f = r.data, [routine, slot, day] = r.id.split("|");
    add("routine_overrides", { id: r.id, routine_id: routine, slot_id: slot, local_day: day, status: f.completed ? "completed" : f.skip ? "skipped" : f.reschedule ? "rescheduled" : "other", completed_at: iso(f.completed?.at), scheduled_start: iso(f.completed?.scheduledStart), rescheduled_to: iso(f.reschedule?._0) });
  }
  for (const r of group("core.wakePlan")) for (const d of r.data.plan?.days ?? []) add("wake_days", { plan_id: r.id, date: iso(d.date), wake: iso(d.wake) });
  for (const r of group("calendar")) {
    const f = r.data;
    add("calendar_events", { id: r.id, title: f.title, start: f.start?.dateTime ? iso(f.start.dateTime) : null, end: f.end?.dateTime ? iso(f.end.dateTime) : null, start_day: f.start?.date, end_day: f.end?.date, all_day: f.allDay ?? Boolean(f.start?.date), calendar: f.calendar, location: f.location });
  }
  if (access && !access.sections.includes("workouts") && !selected.has("health.workout")) delete tables.workouts;
  if (access && !access.sections.includes("health")) for (const key of ["health_readings", "sleep_nights", "sleep_wakes"]) delete tables[key];
  return { schema: analysisSchema.schema, tables, warnings, sourceRecords: records };
}
function tableCSV(name, rows) {
  const headers = Object.keys(analysisSchema.tables[name].columns);
  const cell = (v) => {
    let s = v == null ? "" : String(v);
    if (typeof v === "string" && /^[\s\u0000-\u001f]*[=+@-]/.test(s)) s = "'" + s;
    return '"' + s.replaceAll('"', '""') + '"';
  };
  return "\uFEFF" + [headers.map(cell).join(","), ...rows.map((r) => headers.map((k) => cell(r[k])).join(","))].join("\r\n") + "\r\n";
}

// public/app/assets/feed-import.js
var FeedImportError = class extends Error {
  constructor(message, status = 0) {
    super(message);
    this.name = "FeedImportError";
    this.status = status;
  }
};
var delay = (ms, signal) => new Promise((resolve, reject) => {
  signal?.throwIfAborted();
  const done = () => {
    signal?.removeEventListener("abort", abort);
    resolve();
  };
  const id = setTimeout(done, ms);
  const abort = () => {
    clearTimeout(id);
    reject(new DOMException("Cancelled", "AbortError"));
  };
  signal?.addEventListener("abort", abort, { once: true });
});
var messages = { 400: "The feed request is invalid. Rebuild it using the feed controls.", 401: "The credential is invalid. Create a new connection.", 403: "Access or consent changed. Refresh the type list and start again.", 404: "The connection or attachment is unavailable, expired or revoked.", 409: "Data or access changed during the export. Start again; no partial download was saved.", 413: "The export page is too large. Reduce the page limit or selected types.", 429: "The request budget is busy. Wait and retry.", 503: "Shared data or a selected calendar is unavailable. Retry later." };
var signature = (page) => JSON.stringify([page.contentVersion, page.access, page.types, page.analysis ?? null]);
async function collectFeed(url, { fetcher = fetch, signal, onProgress = () => {
}, wait = delay, paceMs = 1100, maxBytes = 64 * 1024 * 1024, maxRecords = 1e5, token = null, credentials = "omit" } = {}) {
  const first = new URL(url);
  if (!["http:", "https:"].includes(first.protocol)) throw new FeedImportError("Use an HTTP or HTTPS feed URL.");
  first.searchParams.delete("view");
  first.searchParams.delete("cursor");
  first.searchParams.set("format", "json");
  if (token) first.searchParams.delete("signature");
  let bytes = 0, requests = 0, pages = 0, expected = null, initial = null;
  const seen = /* @__PURE__ */ new Set(), ids = /* @__PURE__ */ new Set(), records = [], calendarIssues = /* @__PURE__ */ new Map();
  async function request(target, binary = false) {
    const u = new URL(target);
    if (u.origin !== first.origin || u.username || u.password) throw new FeedImportError("The feed returned an unexpected URL origin.");
    for (let attempt = 0; attempt < 4; attempt++) {
      signal?.throwIfAborted();
      if (requests++) await wait(paceMs, signal);
      const response = await fetcher(u.href, { headers: token ? { Authorization: `Bearer ${token}` } : {}, credentials, cache: "no-store", signal, redirect: "error" });
      if (response.status === 429 && attempt < 3) {
        const raw = response.headers.get("Retry-After");
        const seconds = /^\d+$/.test(raw ?? "") ? Number(raw) : Math.ceil((Date.parse(raw) - Date.now()) / 1e3);
        const ms = Math.max(1e3, Math.min(36e5, (Number.isFinite(seconds) ? seconds : 60) * 1e3));
        onProgress({ stage: "waiting", pages, records: records.length, retryAfterSeconds: Math.ceil(ms / 1e3) });
        await wait(ms, signal);
        continue;
      }
      if (response.status === 503) {
        let detail = null;
        try {
          const reader2 = response.body?.getReader(), chunks2 = [];
          let size = 0;
          if (reader2) {
            try {
              for (; ; ) {
                const { value, done } = await reader2.read();
                if (done) break;
                size += value.byteLength;
                if (size > 16384) {
                  await reader2.cancel();
                  break;
                }
                chunks2.push(value);
              }
              if (size <= 16384) {
                const bytes2 = new Uint8Array(size);
                let offset2 = 0;
                for (const chunk of chunks2) {
                  bytes2.set(chunk, offset2);
                  offset2 += chunk.length;
                }
                detail = JSON.parse(new TextDecoder().decode(bytes2));
              }
            } finally {
              reader2.releaseLock();
            }
          }
        } catch {
        }
        if (detail?.error === "calendar_unavailable") {
          const issues = Array.isArray(detail.issues) ? detail.issues : [];
          const message = issues.some((i2) => i2.reason === "reconnect") ? "The owner needs to reconnect a selected Google account." : issues.some((i2) => i2.reason === "unavailable") ? "Google no longer provides access to a selected calendar. The owner must restore access or remove it from the share." : "A selected calendar is temporarily unavailable. Retry later.";
          const error = new FeedImportError(message + " You can also exclude calendar from the requested types. No partial export was saved.", 503);
          error.issues = issues;
          throw error;
        }
      }
      if (!response.ok) throw new FeedImportError(messages[response.status] ?? `Feed request failed (HTTP ${response.status}).`, response.status);
      const declared = Number(response.headers.get("Content-Length"));
      if (declared > maxBytes - bytes) throw new FeedImportError("The export exceeds the 64 MiB browser download limit. Select fewer types or use the developer importer with a larger maxBytes limit.");
      const chunks = [];
      let length = 0;
      const reader = response.body?.getReader();
      if (reader) {
        try {
          for (; ; ) {
            const { value, done } = await reader.read();
            if (done) break;
            length += value.byteLength;
            if (bytes + length > maxBytes) {
              await reader.cancel();
              throw new FeedImportError("The export exceeds the configured size limit. Select fewer types or increase maxBytes in the developer importer.");
            }
            chunks.push(value);
          }
        } finally {
          reader.releaseLock();
        }
      }
      bytes += length;
      const data = new Uint8Array(length);
      let offset = 0;
      for (const c of chunks) {
        data.set(c, offset);
        offset += c.length;
      }
      if (binary) return { bytes: data, mediaType: (response.headers.get("Content-Type") ?? "").split(";")[0] };
      try {
        return JSON.parse(new TextDecoder().decode(data));
      } catch {
        throw new FeedImportError("The feed did not return valid JSON.");
      }
    }
  }
  let next = first.href;
  while (next) {
    signal?.throwIfAborted();
    if (seen.has(next)) throw new FeedImportError("The feed repeated a page. No partial download was saved.");
    seen.add(next);
    const page = await request(next);
    if (page.schema !== "banana.feed.v2" || !Array.isArray(page.records) || !Array.isArray(page.types)) throw new FeedImportError("Unsupported feed response schema.");
    if (initial == null) {
      initial = page;
      expected = signature(page);
    } else if (signature(page) !== expected) throw new FeedImportError(messages[409], 409);
    for (const issue of page.calendarIssues ?? []) calendarIssues.set(issue.calendarRef ?? issue.calendarIndex, issue);
    for (const record of page.records) {
      if (!page.types.includes(record.type) || typeof record.id !== "string" || !record.data || typeof record.data !== "object" || Array.isArray(record.data)) throw new FeedImportError("The feed returned an invalid record.");
      const id = JSON.stringify([record.type, record.id]);
      if (ids.has(id)) throw new FeedImportError("Records changed or repeated while paging. Start again.", 409);
      ids.add(id);
      records.push(record);
      if (records.length > maxRecords) throw new FeedImportError("The export exceeds the configured record limit. Select fewer types or increase maxRecords in the developer importer.");
    }
    pages++;
    onProgress({ stage: "reading", pages, records: records.length, bytes });
    next = page.next;
    if (next != null && typeof next !== "string") throw new FeedImportError("The feed returned an invalid next-page URL.");
  }
  const verifyURL = new URL(first);
  if (initial.calendarWindow) {
    verifyURL.searchParams.delete("calendarDays");
    verifyURL.searchParams.set("from", initial.calendarWindow.from);
    verifyURL.searchParams.set("to", initial.calendarWindow.to);
  }
  const verify = await request(verifyURL.href);
  if (signature(verify) !== expected) throw new FeedImportError(messages[409], 409);
  const result = normalizeAnalysis(records, { types: initial.types, access: initial.access, ownBundleID: initial.analysis?.ownBundleID ?? null });
  result.generatedAt = (/* @__PURE__ */ new Date()).toISOString();
  result.access = initial.access;
  result.types = initial.types;
  result.calendarWindow = initial.calendarWindow ?? null;
  result.contentVersion = initial.contentVersion;
  if (calendarIssues.size) {
    result.calendarIssues = [...calendarIssues.values()];
    result.warnings.push("Calendar is incomplete. Preserve existing data for unavailable calendars when reconciling this export.");
  }
  result.collection = { pages, records: records.length, bytes, verifiedAt: result.generatedAt };
  return { result, request, verify: async () => {
    const page = await request(verifyURL.href);
    if (signature(page) !== expected) throw new FeedImportError(messages[409], 409);
  }, get bytes() {
    return bytes;
  } };
}
async function importFeed(url, options = {}) {
  return (await collectFeed(url, options)).result;
}

// public/app/assets/vendor/fflate.js
var u8 = Uint8Array;
var u16 = Uint16Array;
var i32 = Int32Array;
var fleb = new u8([
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  1,
  1,
  1,
  2,
  2,
  2,
  2,
  3,
  3,
  3,
  3,
  4,
  4,
  4,
  4,
  5,
  5,
  5,
  5,
  0,
  /* unused */
  0,
  0,
  /* impossible */
  0
]);
var fdeb = new u8([
  0,
  0,
  0,
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  4,
  4,
  5,
  5,
  6,
  6,
  7,
  7,
  8,
  8,
  9,
  9,
  10,
  10,
  11,
  11,
  12,
  12,
  13,
  13,
  /* unused */
  0,
  0
]);
var clim = new u8([16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]);
var freb = function(eb, start) {
  var b = new u16(31);
  for (var i2 = 0; i2 < 31; ++i2) {
    b[i2] = start += 1 << eb[i2 - 1];
  }
  var r = new i32(b[30]);
  for (var i2 = 1; i2 < 30; ++i2) {
    for (var j = b[i2]; j < b[i2 + 1]; ++j) {
      r[j] = j - b[i2] << 5 | i2;
    }
  }
  return { b, r };
};
var _a = freb(fleb, 2);
var fl = _a.b;
var revfl = _a.r;
fl[28] = 258, revfl[258] = 28;
var _b = freb(fdeb, 0);
var fd = _b.b;
var revfd = _b.r;
var rev = new u16(32768);
for (i = 0; i < 32768; ++i) {
  x = (i & 43690) >> 1 | (i & 21845) << 1;
  x = (x & 52428) >> 2 | (x & 13107) << 2;
  x = (x & 61680) >> 4 | (x & 3855) << 4;
  rev[i] = ((x & 65280) >> 8 | (x & 255) << 8) >> 1;
}
var x;
var i;
var hMap = (function(cd, mb, r) {
  var s = cd.length;
  var i2 = 0;
  var l = new u16(mb);
  for (; i2 < s; ++i2) {
    if (cd[i2])
      ++l[cd[i2] - 1];
  }
  var le = new u16(mb);
  for (i2 = 1; i2 < mb; ++i2) {
    le[i2] = le[i2 - 1] + l[i2 - 1] << 1;
  }
  var co;
  if (r) {
    co = new u16(1 << mb);
    var rvb = 15 - mb;
    for (i2 = 0; i2 < s; ++i2) {
      if (cd[i2]) {
        var sv = i2 << 4 | cd[i2];
        var r_1 = mb - cd[i2];
        var v = le[cd[i2] - 1]++ << r_1;
        for (var m = v | (1 << r_1) - 1; v <= m; ++v) {
          co[rev[v] >> rvb] = sv;
        }
      }
    }
  } else {
    co = new u16(s);
    for (i2 = 0; i2 < s; ++i2) {
      if (cd[i2]) {
        co[i2] = rev[le[cd[i2] - 1]++] >> 15 - cd[i2];
      }
    }
  }
  return co;
});
var flt = new u8(288);
for (i = 0; i < 144; ++i)
  flt[i] = 8;
var i;
for (i = 144; i < 256; ++i)
  flt[i] = 9;
var i;
for (i = 256; i < 280; ++i)
  flt[i] = 7;
var i;
for (i = 280; i < 288; ++i)
  flt[i] = 8;
var i;
var fdt = new u8(32);
for (i = 0; i < 32; ++i)
  fdt[i] = 5;
var i;
var flm = /* @__PURE__ */ hMap(flt, 9, 0);
var fdm = /* @__PURE__ */ hMap(fdt, 5, 0);
var shft = function(p) {
  return (p + 7) / 8 | 0;
};
var slc = function(v, s, e) {
  if (s == null || s < 0)
    s = 0;
  if (e == null || e > v.length)
    e = v.length;
  return new u8(v.subarray(s, e));
};
var ec = [
  "unexpected EOF",
  "invalid block type",
  "invalid length/literal",
  "invalid distance",
  "stream finished",
  "no stream handler",
  ,
  // determined by compression function
  "no callback",
  "invalid UTF-8 data",
  "extra field too long",
  "date not in range 1980-2099",
  "filename too long",
  "stream finishing",
  "invalid zip data"
  // determined by unknown compression method
];
var err = function(ind, msg, nt) {
  var e = new Error(msg || ec[ind]);
  e.code = ind;
  if (Error.captureStackTrace)
    Error.captureStackTrace(e, err);
  if (!nt)
    throw e;
  return e;
};
var wbits = function(d, p, v) {
  v <<= p & 7;
  var o = p / 8 | 0;
  d[o] |= v;
  d[o + 1] |= v >> 8;
};
var wbits16 = function(d, p, v) {
  v <<= p & 7;
  var o = p / 8 | 0;
  d[o] |= v;
  d[o + 1] |= v >> 8;
  d[o + 2] |= v >> 16;
};
var hTree = function(d, mb) {
  var t = [];
  for (var i2 = 0; i2 < d.length; ++i2) {
    if (d[i2])
      t.push({ s: i2, f: d[i2] });
  }
  var s = t.length;
  var t2 = t.slice();
  if (!s)
    return { t: et, l: 0 };
  if (s == 1) {
    var v = new u8(t[0].s + 1);
    v[t[0].s] = 1;
    return { t: v, l: 1 };
  }
  t.sort(function(a, b) {
    return a.f - b.f;
  });
  t.push({ s: -1, f: 25001 });
  var l = t[0], r = t[1], i0 = 0, i1 = 1, i22 = 2;
  t[0] = { s: -1, f: l.f + r.f, l, r };
  while (i1 != s - 1) {
    l = t[t[i0].f < t[i22].f ? i0++ : i22++];
    r = t[i0 != i1 && t[i0].f < t[i22].f ? i0++ : i22++];
    t[i1++] = { s: -1, f: l.f + r.f, l, r };
  }
  var maxSym = t2[0].s;
  for (var i2 = 1; i2 < s; ++i2) {
    if (t2[i2].s > maxSym)
      maxSym = t2[i2].s;
  }
  var tr = new u16(maxSym + 1);
  var mbt = ln(t[i1 - 1], tr, 0);
  if (mbt > mb) {
    var i2 = 0, dt = 0;
    var lft = mbt - mb, cst = 1 << lft;
    t2.sort(function(a, b) {
      return tr[b.s] - tr[a.s] || a.f - b.f;
    });
    for (; i2 < s; ++i2) {
      var i2_1 = t2[i2].s;
      if (tr[i2_1] > mb) {
        dt += cst - (1 << mbt - tr[i2_1]);
        tr[i2_1] = mb;
      } else
        break;
    }
    dt >>= lft;
    while (dt > 0) {
      var i2_2 = t2[i2].s;
      if (tr[i2_2] < mb)
        dt -= 1 << mb - tr[i2_2]++ - 1;
      else
        ++i2;
    }
    for (; i2 >= 0 && dt; --i2) {
      var i2_3 = t2[i2].s;
      if (tr[i2_3] == mb) {
        --tr[i2_3];
        ++dt;
      }
    }
    mbt = mb;
  }
  return { t: new u8(tr), l: mbt };
};
var ln = function(n2, l, d) {
  return n2.s == -1 ? Math.max(ln(n2.l, l, d + 1), ln(n2.r, l, d + 1)) : l[n2.s] = d;
};
var lc = function(c) {
  var s = c.length;
  while (s && !c[--s])
    ;
  var cl = new u16(++s);
  var cli = 0, cln = c[0], cls = 1;
  var w = function(v) {
    cl[cli++] = v;
  };
  for (var i2 = 1; i2 <= s; ++i2) {
    if (c[i2] == cln && i2 != s)
      ++cls;
    else {
      if (!cln && cls > 2) {
        for (; cls > 138; cls -= 138)
          w(32754);
        if (cls > 2) {
          w(cls > 10 ? cls - 11 << 5 | 28690 : cls - 3 << 5 | 12305);
          cls = 0;
        }
      } else if (cls > 3) {
        w(cln), --cls;
        for (; cls > 6; cls -= 6)
          w(8304);
        if (cls > 2)
          w(cls - 3 << 5 | 8208), cls = 0;
      }
      while (cls--)
        w(cln);
      cls = 1;
      cln = c[i2];
    }
  }
  return { c: cl.subarray(0, cli), n: s };
};
var clen = function(cf, cl) {
  var l = 0;
  for (var i2 = 0; i2 < cl.length; ++i2)
    l += cf[i2] * cl[i2];
  return l;
};
var wfblk = function(out, pos, dat) {
  var s = dat.length;
  var o = shft(pos + 2);
  out[o] = s & 255;
  out[o + 1] = s >> 8;
  out[o + 2] = out[o] ^ 255;
  out[o + 3] = out[o + 1] ^ 255;
  for (var i2 = 0; i2 < s; ++i2)
    out[o + i2 + 4] = dat[i2];
  return (o + 4 + s) * 8;
};
var wblk = function(dat, out, final, syms, lf, df, eb, li, bs, bl, p) {
  wbits(out, p++, final);
  ++lf[256];
  var _a2 = hTree(lf, 15), dlt = _a2.t, mlb = _a2.l;
  var _b2 = hTree(df, 15), ddt = _b2.t, mdb = _b2.l;
  var _c = lc(dlt), lclt = _c.c, nlc = _c.n;
  var _d = lc(ddt), lcdt = _d.c, ndc = _d.n;
  var lcfreq = new u16(19);
  for (var i2 = 0; i2 < lclt.length; ++i2)
    ++lcfreq[lclt[i2] & 31];
  for (var i2 = 0; i2 < lcdt.length; ++i2)
    ++lcfreq[lcdt[i2] & 31];
  var _e = hTree(lcfreq, 7), lct = _e.t, mlcb = _e.l;
  var nlcc = 19;
  for (; nlcc > 4 && !lct[clim[nlcc - 1]]; --nlcc)
    ;
  var flen = bl + 5 << 3;
  var ftlen = clen(lf, flt) + clen(df, fdt) + eb;
  var dtlen = clen(lf, dlt) + clen(df, ddt) + eb + 14 + 3 * nlcc + clen(lcfreq, lct) + 2 * lcfreq[16] + 3 * lcfreq[17] + 7 * lcfreq[18];
  if (bs >= 0 && flen <= ftlen && flen <= dtlen)
    return wfblk(out, p, dat.subarray(bs, bs + bl));
  var lm, ll, dm, dl;
  wbits(out, p, 1 + (dtlen < ftlen)), p += 2;
  if (dtlen < ftlen) {
    lm = hMap(dlt, mlb, 0), ll = dlt, dm = hMap(ddt, mdb, 0), dl = ddt;
    var llm = hMap(lct, mlcb, 0);
    wbits(out, p, nlc - 257);
    wbits(out, p + 5, ndc - 1);
    wbits(out, p + 10, nlcc - 4);
    p += 14;
    for (var i2 = 0; i2 < nlcc; ++i2)
      wbits(out, p + 3 * i2, lct[clim[i2]]);
    p += 3 * nlcc;
    var lcts = [lclt, lcdt];
    for (var it = 0; it < 2; ++it) {
      var clct = lcts[it];
      for (var i2 = 0; i2 < clct.length; ++i2) {
        var len = clct[i2] & 31;
        wbits(out, p, llm[len]), p += lct[len];
        if (len > 15)
          wbits(out, p, clct[i2] >> 5 & 127), p += clct[i2] >> 12;
      }
    }
  } else {
    lm = flm, ll = flt, dm = fdm, dl = fdt;
  }
  for (var i2 = 0; i2 < li; ++i2) {
    var sym = syms[i2];
    if (sym > 255) {
      var len = sym >> 18 & 31;
      wbits16(out, p, lm[len + 257]), p += ll[len + 257];
      if (len > 7)
        wbits(out, p, sym >> 23 & 31), p += fleb[len];
      var dst = sym & 31;
      wbits16(out, p, dm[dst]), p += dl[dst];
      if (dst > 3)
        wbits16(out, p, sym >> 5 & 8191), p += fdeb[dst];
    } else {
      wbits16(out, p, lm[sym]), p += ll[sym];
    }
  }
  wbits16(out, p, lm[256]);
  return p + ll[256];
};
var deo = /* @__PURE__ */ new i32([65540, 131080, 131088, 131104, 262176, 1048704, 1048832, 2114560, 2117632]);
var et = /* @__PURE__ */ new u8(0);
var dflt = function(dat, lvl, plvl, pre, post, st) {
  var s = st.z || dat.length;
  var o = new u8(pre + s + 5 * (1 + Math.ceil(s / 7e3)) + post);
  var w = o.subarray(pre, o.length - post);
  var lst = st.l;
  var pos = (st.r || 0) & 7;
  if (lvl) {
    if (pos)
      w[0] = st.r >> 3;
    var opt = deo[lvl - 1];
    var n2 = opt >> 13, c = opt & 8191;
    var msk_1 = (1 << plvl) - 1;
    var prev = st.p || new u16(32768), head = st.h || new u16(msk_1 + 1);
    var bs1_1 = Math.ceil(plvl / 3), bs2_1 = 2 * bs1_1;
    var hsh = function(i3) {
      return (dat[i3] ^ dat[i3 + 1] << bs1_1 ^ dat[i3 + 2] << bs2_1) & msk_1;
    };
    var syms = new i32(25e3);
    var lf = new u16(288), df = new u16(32);
    var lc_1 = 0, eb = 0, i2 = st.i || 0, li = 0, wi = st.w || 0, bs = 0;
    for (; i2 + 2 < s; ++i2) {
      var hv = hsh(i2);
      var imod = i2 & 32767, pimod = head[hv];
      prev[imod] = pimod;
      head[hv] = imod;
      if (wi <= i2) {
        var rem = s - i2;
        if ((lc_1 > 7e3 || li > 24576) && (rem > 423 || !lst)) {
          pos = wblk(dat, w, 0, syms, lf, df, eb, li, bs, i2 - bs, pos);
          li = lc_1 = eb = 0, bs = i2;
          for (var j = 0; j < 286; ++j)
            lf[j] = 0;
          for (var j = 0; j < 30; ++j)
            df[j] = 0;
        }
        var l = 2, d = 0, ch_1 = c, dif = imod - pimod & 32767;
        if (rem > 2 && hv == hsh(i2 - dif)) {
          var maxn = Math.min(n2, rem) - 1;
          var maxd = Math.min(32767, i2);
          var ml = Math.min(258, rem);
          while (dif <= maxd && --ch_1 && imod != pimod) {
            if (dat[i2 + l] == dat[i2 + l - dif]) {
              var nl = 0;
              for (; nl < ml && dat[i2 + nl] == dat[i2 + nl - dif]; ++nl)
                ;
              if (nl > l) {
                l = nl, d = dif;
                if (nl > maxn)
                  break;
                var mmd = Math.min(dif, nl - 2);
                var md = 0;
                for (var j = 0; j < mmd; ++j) {
                  var ti = i2 - dif + j & 32767;
                  var pti = prev[ti];
                  var cd = ti - pti & 32767;
                  if (cd > md)
                    md = cd, pimod = ti;
                }
              }
            }
            imod = pimod, pimod = prev[imod];
            dif += imod - pimod & 32767;
          }
        }
        if (d) {
          syms[li++] = 268435456 | revfl[l] << 18 | revfd[d];
          var lin = revfl[l] & 31, din = revfd[d] & 31;
          eb += fleb[lin] + fdeb[din];
          ++lf[257 + lin];
          ++df[din];
          wi = i2 + l;
          ++lc_1;
        } else {
          syms[li++] = dat[i2];
          ++lf[dat[i2]];
        }
      }
    }
    for (i2 = Math.max(i2, wi); i2 < s; ++i2) {
      syms[li++] = dat[i2];
      ++lf[dat[i2]];
    }
    pos = wblk(dat, w, lst, syms, lf, df, eb, li, bs, i2 - bs, pos);
    if (!lst) {
      st.r = pos & 7 | w[pos / 8 | 0] << 3;
      pos -= 7;
      st.h = head, st.p = prev, st.i = i2, st.w = wi;
    }
  } else {
    for (var i2 = st.w || 0; i2 < s + lst; i2 += 65535) {
      var e = i2 + 65535;
      if (e >= s) {
        w[pos / 8 | 0] = lst;
        e = s;
      }
      pos = wfblk(w, pos + 1, dat.subarray(i2, e));
    }
    st.i = s;
  }
  return slc(o, 0, pre + shft(pos) + post);
};
var crct = /* @__PURE__ */ (function() {
  var t = new Int32Array(256);
  for (var i2 = 0; i2 < 256; ++i2) {
    var c = i2, k = 9;
    while (--k)
      c = (c & 1 && -306674912) ^ c >>> 1;
    t[i2] = c;
  }
  return t;
})();
var crc = function() {
  var c = -1;
  return {
    p: function(d) {
      var cr = c;
      for (var i2 = 0; i2 < d.length; ++i2)
        cr = crct[cr & 255 ^ d[i2]] ^ cr >>> 8;
      c = cr;
    },
    d: function() {
      return ~c;
    }
  };
};
var dopt = function(dat, opt, pre, post, st) {
  if (!st) {
    st = { l: 1 };
    if (opt.dictionary) {
      var dict = opt.dictionary.subarray(-32768);
      var newDat = new u8(dict.length + dat.length);
      newDat.set(dict);
      newDat.set(dat, dict.length);
      dat = newDat;
      st.w = dict.length;
    }
  }
  return dflt(dat, opt.level == null ? 6 : opt.level, opt.mem == null ? st.l ? Math.ceil(Math.max(8, Math.min(13, Math.log(dat.length))) * 1.5) : 20 : 12 + opt.mem, pre, post, st);
};
var mrg = function(a, b) {
  var o = {};
  for (var k in a)
    o[k] = a[k];
  for (var k in b)
    o[k] = b[k];
  return o;
};
var wbytes = function(d, b, v) {
  for (; v; ++b)
    d[b] = v, v >>>= 8;
};
function deflateSync(data, opts) {
  return dopt(data, opts || {}, 0, 0);
}
var fltn = function(d, p, t, o) {
  for (var k in d) {
    var val = d[k], n2 = p + k, op = o;
    if (Array.isArray(val))
      op = mrg(o, val[1]), val = val[0];
    if (ArrayBuffer.isView(val))
      t[n2] = [val, op];
    else {
      t[n2 += "/"] = [new u8(0), op];
      fltn(val, n2, t, o);
    }
  }
};
var te = typeof TextEncoder != "undefined" && /* @__PURE__ */ new TextEncoder();
var td = typeof TextDecoder != "undefined" && /* @__PURE__ */ new TextDecoder();
var tds = 0;
try {
  td.decode(et, { stream: true });
  tds = 1;
} catch (e) {
}
function strToU8(str, latin1) {
  if (latin1) {
    var ar_1 = new u8(str.length);
    for (var i2 = 0; i2 < str.length; ++i2)
      ar_1[i2] = str.charCodeAt(i2);
    return ar_1;
  }
  if (te)
    return te.encode(str);
  var l = str.length;
  var ar = new u8(str.length + (str.length >> 1));
  var ai = 0;
  var w = function(v) {
    ar[ai++] = v;
  };
  for (var i2 = 0; i2 < l; ++i2) {
    if (ai + 5 > ar.length) {
      var n2 = new u8(ai + 8 + (l - i2 << 1));
      n2.set(ar);
      ar = n2;
    }
    var c = str.charCodeAt(i2);
    if (c < 128 || latin1)
      w(c);
    else if (c < 2048)
      w(192 | c >> 6), w(128 | c & 63);
    else if (c > 55295 && c < 57344)
      c = 65536 + (c & 1023 << 10) | str.charCodeAt(++i2) & 1023, w(240 | c >> 18), w(128 | c >> 12 & 63), w(128 | c >> 6 & 63), w(128 | c & 63);
    else
      w(224 | c >> 12), w(128 | c >> 6 & 63), w(128 | c & 63);
  }
  return slc(ar, 0, ai);
}
var exfl = function(ex) {
  var le = 0;
  if (ex) {
    for (var k in ex) {
      var l = ex[k].length;
      if (l > 65535)
        err(9);
      le += l + 4;
    }
  }
  return le;
};
var wzh = function(d, b, f, fn, u, c, ce, co) {
  var fl2 = fn.length, ex = f.extra, col2 = co && co.length;
  var exl = exfl(ex);
  wbytes(d, b, ce != null ? 33639248 : 67324752), b += 4;
  if (ce != null)
    d[b++] = 20, d[b++] = f.os;
  d[b] = 20, b += 2;
  d[b++] = f.flag << 1 | (c < 0 && 8), d[b++] = u && 8;
  d[b++] = f.compression & 255, d[b++] = f.compression >> 8;
  var dt = new Date(f.mtime == null ? Date.now() : f.mtime), y = dt.getFullYear() - 1980;
  if (y < 0 || y > 119)
    err(10);
  wbytes(d, b, y << 25 | dt.getMonth() + 1 << 21 | dt.getDate() << 16 | dt.getHours() << 11 | dt.getMinutes() << 5 | dt.getSeconds() >> 1), b += 4;
  if (c != -1) {
    wbytes(d, b, f.crc);
    wbytes(d, b + 4, c < 0 ? -c - 2 : c);
    wbytes(d, b + 8, f.size);
  }
  wbytes(d, b + 12, fl2);
  wbytes(d, b + 14, exl), b += 16;
  if (ce != null) {
    wbytes(d, b, col2);
    wbytes(d, b + 6, f.attrs);
    wbytes(d, b + 10, ce), b += 14;
  }
  d.set(fn, b);
  b += fl2;
  if (exl) {
    for (var k in ex) {
      var exf = ex[k], l = exf.length;
      wbytes(d, b, +k);
      wbytes(d, b + 2, l);
      d.set(exf, b + 4), b += 4 + l;
    }
  }
  if (col2)
    d.set(co, b), b += col2;
  return b;
};
var wzf = function(o, b, c, d, e) {
  wbytes(o, b, 101010256);
  wbytes(o, b + 8, c);
  wbytes(o, b + 10, c);
  wbytes(o, b + 12, d);
  wbytes(o, b + 16, e);
};
function zipSync(data, opts) {
  if (!opts)
    opts = {};
  var r = {};
  var files = [];
  fltn(data, "", r, opts);
  var o = 0;
  var tot = 0;
  for (var fn in r) {
    var _a2 = r[fn], file = _a2[0], p = _a2[1];
    var compression = p.level == 0 ? 0 : 8;
    var f = strToU8(fn), s = f.length;
    var com = p.comment, m = com && strToU8(com), ms = m && m.length;
    var exl = exfl(p.extra);
    if (s > 65535)
      err(11);
    var d = compression ? deflateSync(file, p) : file, l = d.length;
    var c = crc();
    c.p(file);
    files.push(mrg(p, {
      size: file.length,
      crc: c.d(),
      c: d,
      f,
      m,
      u: s != fn.length || m && com.length != ms,
      o,
      compression
    }));
    o += 30 + s + exl + l;
    tot += 76 + 2 * (s + exl) + (ms || 0) + l;
  }
  var out = new u8(tot + 22), oe = o, cdl = tot - o;
  for (var i2 = 0; i2 < files.length; ++i2) {
    var f = files[i2];
    wzh(out, f.o, f, f.f, f.u, f.c.length);
    var badd = 30 + f.f.length + exfl(f.extra);
    out.set(f.c, f.o + badd);
    wzh(out, o, f, f.f, f.u, f.c.length, f.o, f.m), o += 16 + badd + (f.m ? f.m.length : 0);
  }
  wzf(out, o, files.length, cdl, oe);
  return out;
}

// public/app/assets/feed-archive.js
function buildArchive(result, images = {}) {
  const counts = Object.fromEntries(Object.entries(result.tables).map(([name, rows]) => [name, rows.length]));
  const files = { "analysis.json": strToU8(JSON.stringify(result)), "schema.json": strToU8(JSON.stringify(analysisSchema, null, 2)), "manifest.json": strToU8(JSON.stringify({ schema: result.schema, generatedAt: result.generatedAt, access: result.access, types: result.types, calendarWindow: result.calendarWindow, collection: result.collection, rows: counts, calendarIssues: result.calendarIssues, warnings: result.warnings }, null, 2)), ...images };
  for (const [name, rows] of Object.entries(result.tables)) files[`tables/${name}.csv`] = strToU8(tableCSV(name, rows));
  files["README.txt"] = strToU8(`Banana analysis export \u2014 ${result.schema}

Open tables/*.csv in Excel, Numbers or your analysis tool. Each file has fixed column names, even when empty. schema.json defines every column, unit and relationship. Dates are ISO 8601 UTC; local-day fields stay local. Blank means unknown, not zero. UTF-8 CSV has a BOM and escapes formula-like text.

Use workouts.csv for recorded workout counts and totals. It merges Health and recorded sessions exactly as the shared website does (starts less than 90 seconds apart, nearest first, preferred source wins). Do not add sourceRecords workouts or plan completions to those totals. Meals and meal_items are alternative levels of the same food, not additional energy. Saved foods are per 100 g.

analysis.json contains the same normalized tables plus every fetched source record, including any selected sections without a normalized fitness table. sourceRecords preserves provenance and additional native fields; do not sum it with normalized tables. Synced fields normally use Unix milliseconds. Health snapshot dates use seconds since 2001-01-01. The normalized tables remove this distinction.

Photos: assets.csv lists private expiring URLs and local image paths when included. meal_photos.csv links meal IDs to assets.id. When a local path is blank, an image was not included. Credential-based remote links expire within one hour. Links with null expiry require the current signed-in browser session and stop working when that session or share access ends; they cannot be used by an external system. Source attachments other than meal photos remain remote. Keep this entire archive private. Downloaded copies survive access revocation.

manifest.json contains counts, scope, selected types, collection time and warnings. The collector reads every page and verifies synced content/access again after image downloads. If data changed or a request failed, no archive is saved. Calendar is a live external window, not an atomic snapshot with synced records. For complete datasets, reconcile deletions by ID. If calendarIssues is present, preserve existing calendar data for the affected window because some calendars were unreadable.

Warnings:
${result.warnings.length ? result.warnings.map((w) => "- " + w).join("\n") : "None"}
`);
  return zipSync(files, { level: 0 });
}

// public/app/assets/feed-export.js
async function exportFeed(url, { images = true, onProgress = () => {
}, ...options } = {}) {
  const collected = await collectFeed(url, { ...options, onProgress });
  const { result } = collected, files = {};
  let done = 0;
  if (images) {
    const assets = result.tables.assets.filter((a) => a.record_type === "food.mealPhoto");
    for (const a of assets) {
      const downloaded = await collected.request(a.url, true);
      if (!/^image\/(jpeg|png|webp|heic|heif|gif)$/.test(downloaded.mediaType)) throw new Error("A shared photo did not return a supported image. No partial download was saved.");
      const ext = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic", "image/heif": "heif", "image/gif": "gif" }[downloaded.mediaType];
      const path = `images/photo-${++done}.${ext}`;
      files[path] = downloaded.bytes;
      a.file_path = path;
      a.media_type = downloaded.mediaType;
      onProgress({ stage: "images", completed: done, total: assets.length, pages: result.collection.pages, records: result.collection.records });
    }
  }
  await collected.verify();
  result.collection.bytes = collected.bytes;
  result.collection.verifiedAt = (/* @__PURE__ */ new Date()).toISOString();
  onProgress({ stage: "packaging", records: result.collection.records, calendarIncomplete: Boolean(result.calendarIssues?.length) });
  return buildArchive(result, files);
}

// tools/feed-client-entry.mjs
var isMain = typeof process !== "undefined" && process.argv?.[1] && import.meta.url === (await import("node:url")).pathToFileURL(process.argv[1]).href;
if (isMain) {
  const { writeFile, rename, rm } = await import("node:fs/promises");
  const { resolve } = await import("node:path");
  let scratch = null;
  try {
    const args = process.argv.slice(2);
    let output = "banana-analysis.zip", images = true, maxBytes = 64 * 1024 * 1024;
    for (let i2 = 0; i2 < args.length; i2++) {
      if (args[i2] === "--output" && args[i2 + 1]) output = args[++i2];
      else if (args[i2] === "--no-images") images = false;
      else if (args[i2] === "--max-mib" && /^\d+$/.test(args[i2 + 1] ?? "") && Number(args[i2 + 1]) >= 1 && Number(args[i2 + 1]) <= 1024) maxBytes = Number(args[++i2]) * 1024 * 1024;
      else throw new Error("Usage: BANANA_FEED_URL=<private URL> [BANANA_FEED_TOKEN=<token>] node banana-feed.mjs [--output file.zip] [--no-images] [--max-mib 1..1024]");
    }
    if (!process.env.BANANA_FEED_URL) throw new Error("Set BANANA_FEED_URL to your private feed URL. For bearer authentication, remove signature and set BANANA_FEED_TOKEN.");
    const bytes = await exportFeed(process.env.BANANA_FEED_URL, { token: process.env.BANANA_FEED_TOKEN || null, images, maxBytes, onProgress: (p) => process.stderr.write(p.stage === "reading" ? `Read ${p.records} records across ${p.pages} pages.
` : p.stage === "images" ? `Downloaded ${p.completed}/${p.total} images.
` : p.stage === "waiting" ? `Rate limited; waiting ${p.retryAfterSeconds}s.
` : "Preparing archive.\n") });
    const path = resolve(output);
    scratch = path + ".partial-" + process.pid;
    await writeFile(scratch, bytes, { flag: "wx", mode: 384 });
    await rename(scratch, path);
    scratch = null;
    process.stderr.write("Complete archive saved.\n");
  } catch (error) {
    if (scratch) await rm(scratch, { force: true });
    process.stderr.write(error.message + "\n");
    process.exitCode = 1;
  }
}
export {
  analysisSchema,
  exportFeed,
  importFeed,
  normalizeAnalysis
};
