import Foundation

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var messages: [Message] = []

    private let historyKey = "chat_history_v1"

    init() { load() }

    func send(_ text: String, googleToken: String?) async {
        let userMsg = Message(role: .user, text: text)
        messages.append(userMsg)
        save()

        do {
            let data = try await HushhAPI.ask(prompt: text, googleToken: googleToken)
            let replyText = (data.display?.removingPercentEncoding ?? data.display) ?? data.speech ?? "(no response)"
            let botMsg = Message(role: .assistant, text: replyText)
            messages.append(botMsg)
            save()
        } catch {
            let err = Message(role: .assistant, text: "❌ \(error.localizedDescription)")
            messages.append(err)
            save()
        }
    }

    // MARK: - Persistence (simple UserDefaults)
    private func load() {
        guard let raw = UserDefaults.standard.data(forKey: historyKey) else { return }
        if let decoded = try? JSONDecoder().decode([Message].self, from: raw) {
            self.messages = decoded
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    func clear() {
        messages.removeAll()
        save()
    }
}



