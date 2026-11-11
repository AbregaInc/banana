import Foundation

// The 27.2 SDK back-deploys these Date operators only before 27.2, but early 27.2
// runtimes report that version without exporting the new entry points. Keep the
// SDK's numeric fallback in every first-party module, including extensions and Watch.
// These internal overloads deliberately shadow Foundation within the application;
// this is not an exported library API. Preserve IEEE comparisons, including NaN.
extension Date {
    static func >= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate >= rhs.timeIntervalSinceReferenceDate
    }

    static func <= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate <= rhs.timeIntervalSinceReferenceDate
    }
}
