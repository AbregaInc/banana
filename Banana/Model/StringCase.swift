import Foundation

extension String {
    /// "last week by now" → "Last week by now".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
