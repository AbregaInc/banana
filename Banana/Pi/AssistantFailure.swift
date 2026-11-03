import Foundation

struct AssistantFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
