import Foundation

struct KaiNoteEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var ts: Date
    var questionId: String
    var text: String

    init(id: UUID = UUID(), ts: Date = Date(), questionId: String, text: String) {
        self.id = id
        self.ts = ts
        self.questionId = questionId
        self.text = text
    }
}
