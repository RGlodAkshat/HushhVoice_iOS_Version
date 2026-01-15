import Foundation

struct KaiLocalState: Codable, Equatable {
    var createdAt: Date
    var discovery: [String: String]
    var notes: [KaiNoteEntry]
    var completedQuestions: Int
    var totalQuestions: Int
    var isComplete: Bool
    var lastQuestionId: String?
}
