import Foundation

/// The week of weather the preview and store-capture routes show (`WeatherStore.injectSampleForPreview`):
/// the same at every run, and one that reads like a real forecast. Each day is its own: a dry
/// clear day, afternoon showers, a grey day, a wet day, storms in the evening. Every number on the
/// forecast page comes from the hours, so the header, the hour strip and the week agree: a day's
/// high and low are its warmest and coolest hours, and a day is rainy exactly when an hour is.
enum WeatherSample {
    struct Hour: Equatable {
        let hour: Int
        let tempF: Double
        let precip: Double
        let windMph: Double
        let humidity: Double
        let symbol: String
        let condition: String
    }

    struct Day {
        let hours: [Hour]
        let symbol: String
        let condition: String
        var highF: Double { hours.map(\.tempF).max() ?? 0 }
        var lowF: Double { hours.map(\.tempF).min() ?? 0 }
        var wettest: Double { hours.map(\.precip).max() ?? 0 }
    }

    /// A chance of rain from here up is a rainy hour (and day): its symbol shows rain.
    static let rainy = 0.4

    private enum Sky { case clear, partly, cloudy }
    private struct Rain { let from: Int, to: Int, peak: Double, symbol: String, condition: String }
    private struct Plan { let high: Double, low: Double, sky: Sky, wind: Double, rain: Rain? }

    private static let plans: [Plan] = [
        Plan(high: 72, low: 55, sky: .clear, wind: 6, rain: nil),
        Plan(high: 70, low: 57, sky: .partly, wind: 9,
             rain: Rain(from: 14, to: 18, peak: 0.6, symbol: "cloud.sun.rain.fill", condition: "Showers")),
        Plan(high: 66, low: 55, sky: .cloudy, wind: 11, rain: nil),
        Plan(high: 61, low: 52, sky: .cloudy, wind: 14,
             rain: Rain(from: 6, to: 20, peak: 0.85, symbol: "cloud.rain.fill", condition: "Rain")),
        Plan(high: 64, low: 50, sky: .partly, wind: 8, rain: nil),
        Plan(high: 69, low: 52, sky: .clear, wind: 5, rain: nil),
        Plan(high: 74, low: 58, sky: .partly, wind: 10,
             rain: Rain(from: 17, to: 22, peak: 0.5, symbol: "cloud.bolt.rain.fill", condition: "Thunderstorms")),
    ]

    /// Seven days from today, 24 hours each.
    static func week() -> [Day] { plans.map(day) }

    private static func day(_ plan: Plan) -> Day {
        let hours = (0..<24).map { hour -> Hour in
            // Coolest at 3 AM, warmest at 3 PM: the day's low and high, exactly.
            let warmth = (sin((Double(hour) - 9) / 24 * 2 * .pi) + 1) / 2
            let temp = (plan.low + (plan.high - plan.low) * warmth).rounded()
            let base: Double = switch plan.sky {
            case .clear: 0.03 + Double(hour % 3) * 0.01
            case .partly: 0.08 + Double(hour % 3) * 0.02
            case .cloudy: 0.14 + Double(hour % 3) * 0.02
            }
            var precip = base
            if let rain = plan.rain, (rain.from..<rain.to).contains(hour) {
                let along = (Double(hour - rain.from) + 0.5) / Double(rain.to - rain.from)
                precip = max(base, rain.peak * sin(.pi * along))
            }
            precip = (precip * 100).rounded() / 100
            let daylight = (7...16).contains(hour)   // sunrise 6:32, sunset 4:41 (WeatherStore)
            let (symbol, condition): (String, String) = {
                if precip >= rainy, let rain = plan.rain { return (rain.symbol, rain.condition) }
                if precip >= 0.25 { return ("cloud.drizzle.fill", "Drizzle") }
                switch plan.sky {
                case .clear: return (daylight ? "sun.max.fill" : "moon.stars.fill", "Clear")
                case .partly: return (daylight ? "cloud.sun.fill" : "cloud.moon.fill", "Partly Cloudy")
                case .cloudy: return ("cloud.fill", "Cloudy")
                }
            }()
            return Hour(hour: hour, tempF: temp, precip: precip,
                        windMph: plan.wind + Double(hour % 4), humidity: min(0.95, 0.45 + precip * 0.45),
                        symbol: symbol, condition: condition)
        }
        let symbol: String, condition: String
        if let rain = plan.rain, hours.contains(where: { $0.precip >= rainy }) {
            (symbol, condition) = (rain.symbol, rain.condition)
        } else {
            switch plan.sky {
            case .clear: (symbol, condition) = ("sun.max.fill", "Clear")
            case .partly: (symbol, condition) = ("cloud.sun.fill", "Partly Cloudy")
            case .cloudy: (symbol, condition) = ("cloud.fill", "Cloudy")
            }
        }
        return Day(hours: hours, symbol: symbol, condition: condition)
    }
}
