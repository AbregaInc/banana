import SwiftUI

/// The instant a tap on the weather stripe resolved to. Identifiable so it can drive a sheet.
struct WeatherFocus: Identifiable, Hashable {
    let id: Date
    var date: Date { id }
}

/// The full forecast behind the stripe. You arrive here by tapping the stripe beside your day,
/// and you land on the hour your finger was on — so the question "what's the weather when I'm
/// doing this?" is answered by pointing at the thing.
struct WeatherDetailView: View {
    let focus: Date

    @EnvironmentObject var weather: WeatherStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selected: Date

    /// Resolved ONCE from the tapped instant: which location you were in then, and its whole week.
    /// So tapping the post-landing stretch of the stripe opens Miami's forecast, not home's.
    private let resolvedDays: [DayForecast]
    private let resolvedPlace: String?

    init(focus: Date) {
        self.focus = focus
        _selected = State(initialValue: focus)
        let r = WeatherStore.shared.located(at: focus)
        resolvedDays = r.days
        resolvedPlace = r.placeName
    }

    private var day: DayForecast? {
        resolvedDays.first { Calendar.current.isDate($0.date, inSameDayAs: selected) }
    }
    private var hour: HourlyWeather? { day?.hour(at: selected) }

    var body: some View {
        NavigationStack {
            Group {
                if let day, let hour {
                    ScrollView {
                        VStack(spacing: 22) {
                            hero(hour, in: day)
                            hourStrip(day)
                            details(hour, in: day)
                            week
                            footer
                        }
                        .padding(.vertical, DS.Space.s)
                    }
                } else {
                    ContentUnavailableView("No forecast",
                                           systemImage: "cloud.slash",
                                           description: Text("There's no forecast for this day yet."))
                }
            }
            .navigationTitle(resolvedPlace ?? "Weather")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }

    // MARK: - Hero

    private func hero(_ hour: HourlyWeather, in day: DayForecast) -> some View {
        VStack(spacing: 6) {
            Text(label(selected, "EEEE MMM d", day.timeZone))
                .font(.subheadline).foregroundStyle(.secondary)

            Image(systemName: hour.symbol)
                .font(.system(size: 54))
                .symbolRenderingMode(.multicolor)
                .padding(.vertical, 2)

            Text("\(Int(hour.tempF.rounded()))°")
                .font(.system(size: 64, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)

            Text(hour.condition).font(.headline)

            Text("\(label(hour.date, "jmm", day.timeZone)) · Feels like \(Int(hour.feelsF.rounded()))°")
                .font(.subheadline).foregroundStyle(.secondary)

            Text("High \(Int(day.highF.rounded()))°  ·  Low \(Int(day.lowF.rounded()))°")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    // MARK: - Hours

    /// Every hour of the day, with the tapped one selected. Tapping another moves the whole page
    /// to it, so this doubles as the scrubber.
    private func hourStrip(_ day: DayForecast) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(day.hours) { h in
                        let isSelected = h.hour == day.calendar.component(.hour, from: selected)
                        VStack(spacing: 6) {
                            Text(label(h.date, "ha", day.timeZone)).font(.caption2)
                                .foregroundStyle(isSelected ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(.secondary))
                            Image(systemName: h.symbol)
                                .font(.system(size: 17))
                                .symbolRenderingMode(.multicolor)
                                .frame(height: 20)
                            Text("\(Int(h.tempF.rounded()))°")
                                .font(.footnote.weight(isSelected ? .bold : .regular))
                                .foregroundStyle(isSelected ? DS.Palette.accent : Color.primary)
                            if h.precip > 0.05 {
                                Text("\(Int((h.precip * 100).rounded()))%")
                                    .font(.system(size: 9)).foregroundStyle(DS.Palette.info)
                            } else {
                                Text(" ").font(.system(size: 9))
                            }
                        }
                        .frame(width: 46)
                        .padding(.vertical, DS.Space.s)
                        .background(isSelected ? DS.Palette.accent.opacity(DS.Tint.soft) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .id(h.hour)
                        .onTapGesture { selected = h.date }
                    }
                }
                .padding(.horizontal, DS.Space.l)
            }
            .onAppear { proxy.scrollTo(day.calendar.component(.hour, from: selected), anchor: .center) }
        }
    }

    // MARK: - Detail grid

    private func details(_ hour: HourlyWeather, in day: DayForecast) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Space.m) {
            tile("Chance of rain", "\(Int((hour.precip * 100).rounded()))%", "umbrella.fill")
            tile("Wind", "\(Int(hour.windMph.rounded())) mph", "wind")
            tile("Humidity", "\(Int((hour.humidity * 100).rounded()))%", "humidity.fill")
            tile("Feels like", "\(Int(hour.feelsF.rounded()))°", "thermometer.medium")
            if let sunrise = day.sunrise { tile("Sunrise", label(sunrise, "jmm", day.timeZone), "sunrise.fill") }
            if let sunset = day.sunset { tile("Sunset", label(sunset, "jmm", day.timeZone), "sunset.fill") }
        }
        .padding(.horizontal, DS.Space.l)
    }

    private func tile(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: symbol)
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value).font(.title3.weight(.medium))
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    // MARK: - Week

    private var week: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The week").font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.s)

            VStack(spacing: 0) {
                ForEach(Array(resolvedDays.enumerated()), id: \.element.id) { i, d in
                    if i > 0 { Divider().padding(.leading, DS.Space.l) }
                    Button {
                        // Keep the hour, move the day — you're usually comparing like for like.
                        selected = sameHour(as: selected, on: d)
                    } label: {
                        weekRow(d)
                    }
                    .buttonStyle(.plain)
                }
            }
            .dsCard()
            .padding(.horizontal, DS.Space.l)
        }
    }

    private func weekRow(_ d: DayForecast) -> some View {
        let isSelected = d.calendar.isDate(d.date, inSameDayAs: selected)
        return HStack(spacing: 12) {
            Text(d.calendar.isDateInToday(d.date) ? "Today" : label(d.date, "EEE", d.timeZone))
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .frame(width: 54, alignment: .leading)

            Image(systemName: d.symbol)
                .symbolRenderingMode(.multicolor)
                .frame(width: 24)

            if let wettest = d.hours.max(by: { $0.precip < $1.precip }), wettest.precip >= 0.2 {
                Text("\(Int((wettest.precip * 100).rounded()))%")
                    .font(.caption).foregroundStyle(DS.Palette.info).frame(width: 36, alignment: .leading)
            } else {
                Spacer().frame(width: 36)
            }

            Spacer(minLength: 0)

            Text("\(Int(d.lowF.rounded()))°").foregroundStyle(.secondary)
            tempBar(d)
            Text("\(Int(d.highF.rounded()))°")
        }
        .font(.subheadline)
        .padding(.horizontal, DS.Space.l).padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    /// The day's low→high span, coloured on the same absolute scale as the stripe, so a warm day
    /// reads warm here too.
    private func tempBar(_ d: DayForecast) -> some View {
        LinearGradient(colors: [weatherTempColor(d.lowF), weatherTempColor(d.highF)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(width: 64, height: 4)
            .clipShape(Capsule())
    }

    /// Apple Weather's mark and its legal page, as Apple requires wherever its forecast shows.
    @ViewBuilder private var footer: some View {
        if let a = weather.attribution {
            VStack(spacing: 6) {
                AsyncImage(url: colorScheme == .dark ? a.markDark : a.markLight) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Text(a.serviceName).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(height: 14)
                .accessibilityLabel(a.serviceName)
                Link("Other data sources", destination: a.legalPage)
                    .font(.caption2)
            }
            .padding(.top, 4).padding(.bottom, 16)
        } else {
            Text(weather.source.isEmpty ? "" : "Forecast by \(weather.source)")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.top, 4).padding(.bottom, 16)
        }
    }

    // MARK: - Helpers

    private func sameHour(as date: Date, on day: DayForecast) -> Date {
        let hour = day.calendar.component(.hour, from: date)
        return day.hours.first { $0.hour == hour }?.date ?? day.hours.first?.date ?? day.date
    }

    /// Every label is rendered in the *forecast's* zone. Formatting in the device's would relabel
    /// 9am as "9 PM" and turn sunrise into an evening whenever the two zones differ.
    ///
    /// Formatters are cached by (template, zone): this helper runs ~30–40 times per body pass
    /// (hour strip + hero + week rows), and constructing a DateFormatter — locale load, template
    /// resolution — is one of the more expensive Foundation allocations to put in a render path.
    private static let labelFormatters = NSCache<NSString, DateFormatter>()

    private func label(_ date: Date, _ template: String, _ zone: TimeZone) -> String {
        let key = "\(template)|\(zone.identifier)" as NSString
        if let cached = Self.labelFormatters.object(forKey: key) { return cached.string(from: date) }
        let f = DateFormatter()
        f.timeZone = zone
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(template)
        Self.labelFormatters.setObject(f, forKey: key)
        return f.string(from: date)
    }
}
