import SwiftUI

/// Nutrition pieces the phone's Food tab and the Mac's Nutrition page share, so a meal and a
/// day's macros read the same on both.

/// One macro's total: its symbol in a tinted tile, its name and its grams, on a faint wash of
/// its colour. The colour is in the tile, never a stripe (the standard, 2), and the number stays
/// primary: colour on every number stops meaning anything.
struct MacroTile: View {
    let name: String
    /// Nil: nothing to count yet ("—").
    let grams: Double?
    let color: Color

    /// The macro's own symbol, the same on every surface.
    private var symbol: String {
        switch name {
        case "Protein": "fork.knife"
        case "Carbs": "leaf.fill"
        default: "drop.fill"
        }
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            IconTile(systemImage: symbol, tint: color, style: .soft)
            StatValue(label: name, value: grams.map { $0.rounded().formatted(.number.precision(.fractionLength(0))) },
                      unit: "g", size: .row)
        }
        .padding(.vertical, DS.Space.s)
        .padding(.horizontal, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(DS.Tint.subtle), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Calories over the three macros' tiles: a food you're adding, a meal, a day. One figure
/// everywhere, so a food, a meal and a day read as the same kind of number. Nil macros: nothing
/// logged yet, every number "—".
struct NutritionSummary: View {
    var label: String? = nil
    let macros: NutritionMacros?
    var size: StatValue.Size = .hero

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            StatValue(label: label, value: macros.map { $0.calories.rounded().formatted(.number.precision(.fractionLength(0))) },
                      unit: "kcal", size: size)
            HStack(spacing: DS.Space.s) {
                MacroTile(name: "Protein", grams: macros?.proteinGrams, color: DS.Palette.Macro.protein)
                MacroTile(name: "Carbs", grams: macros?.carbohydrateGrams, color: DS.Palette.Macro.carbs)
                MacroTile(name: "Fat", grams: macros?.fatGrams, color: DS.Palette.Macro.fat)
            }
        }
    }
}

/// A meal on the day's timeline: its time in a column of its own, its photo when it has one,
/// what it was, its macros, its calories, and the chevron that says it opens.
struct MealRowLabel: View {
    let meal: MealEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Text(meal.date, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            if let photo = meal.photoIDs.first {
                MealPhotoThumb(id: photo, size: DS.Row.thumbnail)
                    .opensMealPhotos(meal.photoIDs)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 16 }
            }
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(NutritionText.mealTitle(meal)).font(.body).lineLimit(2)
                Text(NutritionText.macroLine(meal.totals))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.s)
            Text(NutritionText.kcal(meal.totals))
                .font(.subheadline.weight(.semibold).monospacedDigit())
            RowChevron()
        }
        .contentShape(Rectangle())
    }
}

/// The last seven days, each with its calories — a glance at the week, and a tap to go to a day.
struct NutritionWeekStrip: View {
    @Binding var day: Date
    let meals: [MealEntry]
    /// Days with backlog meals still to log get a dot.
    @ObservedObject private var inbox = MealInboxStore.shared

    var body: some View {
        let calendar = Calendar.current
        HStack(spacing: DS.Space.xs) {
            ForEach(NutritionDays.window(for: day), id: \.self) { date in
                let selected = calendar.isDate(date, inSameDayAs: day)
                let total = NutritionDays.total(NutritionDays.meals(meals, on: date))
                Button { day = calendar.startOfDay(for: date) } label: {
                    VStack(spacing: DS.Space.hair) {
                        Text(date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(date.formatted(.dateTime.day()))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(calendar.isDateInToday(date) ? DS.Palette.accent : .primary)
                        Text(total.calories > 0
                             ? total.calories.rounded().formatted(.number.precision(.fractionLength(0)))
                             : DS.placeholder)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Circle()
                            .fill(DS.Palette.accent)
                            .frame(width: 5, height: 5)
                            .opacity(MealBacklogDays.items(inbox.items, on: date).isEmpty ? 0 : 1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.s)
                    .background(selected ? DS.Palette.accent.opacity(DS.Tint.soft) : Color.clear,
                                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(date.formatted(.dateTime.weekday(.wide).month().day())), \(Int(total.calories.rounded())) calories"
                                    + (MealBacklogDays.items(inbox.items, on: date).isEmpty ? "" : ", meals to log"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Your logs against your weight (`EnergyBalance`), worked out from Health's synced series and
/// the meals given. It reads Health here rather than the page doing it: HealthKitStore publishes
/// in bursts (an import, a sync), and only this should redraw for them, not the page's list.
/// Draws nothing until there's something to say.
struct EnergyBalanceReport<Content: View>: View {
    @EnvironmentObject private var health: HealthKitStore
    let meals: [MealEntry]
    @ViewBuilder let content: (EnergyBalance) -> Content

    var body: some View {
        if let balance = EnergyBalance.compute(meals: meals, weightKg: health.trends.bodyMassKg,
                                               activeKcal: health.trends.activeEnergyKcal,
                                               restingKcal: health.trends.basalEnergyKcal) {
            content(balance)
        }
    }
}

/// What `EnergyBalance` says, the same on the phone and the Mac: the answer, then how it was
/// reached. While there isn't enough yet, only the one quiet line saying what's missing. It's
/// about how complete the logs are, so nothing here is coloured as good or bad, and nothing
/// suggests eating differently.
struct EnergyBalanceCard: View {
    let balance: EnergyBalance

    static let title = "Your logs and your weight"
    /// Under the card once there's an answer: where the numbers come from, and that it's only a report.
    static let footnote = "Weight from Health, energy from your Watch. A report only \u{2014} it never changes a meal."

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if balance.status == .gathering {
                Text(balance.headline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(balance.headline)
                    .font(.body)
                if let detail = balance.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// "Logged Oatmeal · 320 kcal — Undo": a save confirms itself without a dialog, and a slip is
/// one tap to take back (DESIGN-SYSTEM.md, "Confirming and undoing").
enum MealLoggedToast {
    @MainActor
    static func offer(_ meal: MealEntry, in wellness: WellnessStore) {
        let name = meal.name.isEmpty ? (meal.items.first?.name ?? "Meal") : meal.name
        let kcal = Int(meal.totals.calories.rounded())
        Task {
            await ToastCenter.shared.offerUndo("Logged \u{201C}\(name)\u{201D} \u{00B7} \(kcal) kcal") {
                wellness.deleteMeal(meal.id)
                return nil
            }
        }
    }
}

/// One timing clash between two things taken today, with its fix: the phone's Taken tab and the
/// wide Nutrition page show the same card. (The wide page had none, while its editor promised
/// that Banana "can offer to move a supplement when its timing clashes".)
struct SupplementClashRow: View {
    @EnvironmentObject private var wellness: WellnessStore
    let conflict: SupplementInteractions.Conflict
    let fix: SupplementInteractions.Suggestion?
    /// Why it happens is worth reading once and is noise on every later look: behind the ⓘ.
    @State private var showingWhy = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: conflict.rule.severity == .notable ? "exclamationmark.triangle.fill" : "clock")
                    .foregroundStyle(conflict.rule.severity == .notable ? DS.Palette.warning : Color.secondary)
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text("\(conflict.earlier.name) and \(conflict.later.name)")
                        .font(.headline)
                    if conflict.rule.involvesMedication {
                        Text("Check timing with your doctor or pharmacist")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(Self.hours(conflict.actualSeparation)) apart \u{00B7} aim \(Self.hours(conflict.rule.separation))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: DS.Space.s)
                Button { showingWhy = true } label: { Image(systemName: "info.circle") }
                    .iconButton()
                    .accessibilityLabel("Why")
                    .popover(isPresented: $showingWhy) {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            if conflict.rule.involvesMedication {
                                Text("This combination may affect how medication is absorbed. Follow your prescription and check with your doctor or pharmacist before changing your schedule. Banana does not check every interaction or determine a safe medication schedule.")
                                Link("Look up your medicine (MedlinePlus)", destination: URL(string: "https://medlineplus.gov/druginformation.html")!)
                            } else {
                                Text(conflict.rule.because)
                                Text("General information, not medical advice. Check with your doctor or pharmacist before changing a supplement or medication schedule.")
                                Link("Dietary supplement information (NIH)", destination: URL(string: "https://ods.od.nih.gov/factsheets/list-all/")!)
                            }
                        }
                        .font(.callout)
                        .padding(DS.Space.l)
                        .frame(idealWidth: 320)
                        .fixedSize(horizontal: false, vertical: true)
                        .presentationCompactAdaptation(.popover)
                    }
            }
            if let fix, !conflict.rule.involvesMedication {
                Button {
                    move(fix)
                } label: {
                    Label("Move \(fix.supplementName) to \(Self.clock(fix.toMinuteOfDay))", systemImage: "clock.arrow.circlepath")
                }
                .font(.callout)
            }
        }
    }

    /// The fix for a clash, among the day's suggestions: the one that moves either of its two.
    static func fix(for conflict: SupplementInteractions.Conflict,
                    in suggestions: [SupplementInteractions.Suggestion]) -> SupplementInteractions.Suggestion? {
        suggestions.first { $0.supplementName == conflict.earlier.name || $0.supplementName == conflict.later.name }
    }

    private func move(_ suggestion: SupplementInteractions.Suggestion) {
        guard var target = wellness.supplements.first(where: { $0.name == suggestion.supplementName }) else { return }
        target.hour = suggestion.toMinuteOfDay / 60
        target.minute = suggestion.toMinuteOfDay % 60
        wellness.upsertSupplement(target)
    }

    static func hours(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let whole = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(whole)h" : "\(whole)h \(rest)m"
    }

    static func clock(_ minuteOfDay: Int) -> String {
        Calendar.current.date(from: .init(hour: minuteOfDay / 60, minute: minuteOfDay % 60))?
            .formatted(date: .omitted, time: .shortened) ?? ""
    }
}

