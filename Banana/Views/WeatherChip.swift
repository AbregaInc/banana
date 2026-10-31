import SwiftUI

/// The forecast's way in from the plan: the temperature and sky for the day shown, opening the
/// full forecast at that hour. Nothing at all when there is no forecast for that day.
struct WeatherChip: View {
    let day: Date
    @ObservedObject private var weather = WeatherStore.shared
    @State private var focus: WeatherFocus?

    /// Where you'll be then, not always where you are: on a day you fly, the afternoon's
    /// forecast is the city you land in (`WeatherStore.located`), as the full forecast shows it.
    private var hour: HourlyWeather? {
        let now = Date()
        let days = weather.located(at: WeatherGlance.instant(on: day, now: now)).days
        guard let hours = days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) })?.hours,
              let index = WeatherGlance.hourIndex(of: hours.map(\.date), on: day, now: now) else { return nil }
        return hours[index]
    }

    var body: some View {
        if let hour {
            Button { focus = WeatherFocus(id: hour.date) } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: hour.symbol).symbolRenderingMode(.multicolor)
                    Text("\(Int(hour.tempF.rounded()))\u{00B0}").monospacedDigit()
                }
                // The Mac's is a toolbar item, which draws its own; the phone's sits in the date line.
                #if !os(macOS)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, DS.Space.s)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
                #endif
            }
            #if !os(macOS)
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel("\(hour.condition), \(Int(hour.tempF.rounded())) degrees")
            .accessibilityHint("Opens the forecast")
            .accessibilityIdentifier("plan.weather")
            #if os(macOS)
            .help("\(hour.condition) \u{2014} open the forecast")
            #endif
            .sheet(item: $focus) { WeatherDetailView(focus: $0.date) }
        }
    }
}

/// Absolute temperature → color (blue cold → red hot). Absolute so colors mean the same
/// thing day to day.
func weatherTempColor(_ f: Double) -> Color {
    let stops: [(Double, Color)] = [
        (44, Color(red: 0.35, green: 0.45, blue: 0.90)),
        (58, Color(red: 0.26, green: 0.53, blue: 0.86)),
        (67, Color(red: 0.28, green: 0.74, blue: 0.78)),
        (74, Color(red: 0.47, green: 0.79, blue: 0.42)),
        (80, Color(red: 0.96, green: 0.74, blue: 0.24)),
        (90, Color(red: 0.91, green: 0.36, blue: 0.27)),
        (100, Color(red: 0.78, green: 0.20, blue: 0.28)),
    ]
    if f <= stops.first!.0 { return stops.first!.1 }
    if f >= stops.last!.0 { return stops.last!.1 }
    for i in 0..<stops.count - 1 where f >= stops[i].0 && f <= stops[i + 1].0 {
        let t = (f - stops[i].0) / (stops[i + 1].0 - stops[i].0)
        return stops[i].1.mix(with: stops[i + 1].1, by: t)
    }
    return .gray
}
