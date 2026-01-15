import Foundation
import SwiftUI

// Manages chats, persistence, and message sending.
final class ChatStore: ObservableObject {
    @Published private(set) var chats: [Chat] = []
    @Published var activeChatID: UUID?

    private let chatsKey = "chats_v2"
    private let legacySingleThreadKey = "chat_history_v1"

    init() {
        // Load saved chats or create a default one.
        load()
        migrateLegacyIfNeeded()

        if chats.isEmpty {
            let c = Chat()
            chats = [c]
            activeChatID = c.id
            save()
        } else if activeChatID == nil {
            activeChatID = chats.first?.id
        }
    }

    var activeChat: Chat? {
        // Convenience for the selected chat.
        guard let id = activeChatID else { return nil }
        return chats.first(where: { $0.id == id })
    }

    var activeMessages: [Message] { activeChat?.messages ?? [] }

    func newChat(select: Bool = true) {
        // Create a new chat thread.
        let c = Chat()
        chats.insert(c, at: 0)
        if select { activeChatID = c.id }
        save()
    }

    func selectChat(_ chatID: UUID) { activeChatID = chatID }

    func deleteChat(_ chatID: UUID) {
        // Remove a chat and select a fallback if needed.
        let wasActive = (activeChatID == chatID)
        chats.removeAll { $0.id == chatID }
        if wasActive { activeChatID = chats.first?.id }
        if chats.isEmpty { newChat(select: true) }
        save()
    }

    func renameChat(_ chatID: UUID, to newTitle: String) {
        // Update the chat title and move it to the top.
        guard let idx = chats.firstIndex(where: { $0.id == chatID }) else { return }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        chats[idx].title = title.isEmpty ? "Untitled" : title
        chats[idx].updatedAt = Date()
        let updated = chats.remove(at: idx)
        chats.insert(updated, at: 0)
        save()
    }

    func send(_ text: String, googleToken: String?) async {
        // Add user message, call backend, then append assistant reply.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let id = activeChatID,
              let idx = chats.firstIndex(where: { $0.id == id })
        else { return }

        let userMsg = Message(role: .user, text: trimmed)
        chats[idx].messages.append(userMsg)
        chats[idx].updatedAt = Date()

        if chats[idx].title == "New Chat" {
            chats[idx].title = Self.initialWordsTitle(from: trimmed)
        }
        save()

        let contextualPrompt = buildContextualPrompt(forChatIndex: idx, newUserMessage: trimmed, maxHistory: 10)

        do {
            let data = try await HushhAPI.ask(prompt: contextualPrompt, googleToken: googleToken)
            let replyText = (data.display?.removingPercentEncoding ?? data.display) ?? data.speech ?? "(no response)"

            let botMsg = Message(role: .assistant, text: replyText)
            chats[idx].messages.append(botMsg)
            chats[idx].updatedAt = Date()
            save()
        } catch {
            let err = Message(role: .assistant, text: "❌ \(error.localizedDescription)")
            chats[idx].messages.append(err)
            chats[idx].updatedAt = Date()
            save()
        }
    }

    func regenerate(at assistantMessageID: UUID, googleToken: String?) async {
        // Re-run the backend for the latest user message.
        guard let chatID = activeChatID,
              let chatIdx = chats.firstIndex(where: { $0.id == chatID }),
              let aIdx = chats[chatIdx].messages.firstIndex(where: { $0.id == assistantMessageID && $0.role == .assistant })
        else { return }

        let msgs = chats[chatIdx].messages
        guard let userIdx = (0..<aIdx).last(where: { msgs[$0].role == .user }) else { return }
        let prompt = msgs[userIdx].text

        chats[chatIdx].messages.remove(at: aIdx)
        save()

        do {
            let data = try await HushhAPI.ask(prompt: prompt, googleToken: googleToken)
            let replyText = (data.display?.removingPercentEncoding ?? data.display) ?? data.speech ?? "(no response)"

            let botMsg = Message(role: .assistant, text: replyText)
            chats[chatIdx].messages.insert(botMsg, at: aIdx)
            chats[chatIdx].updatedAt = Date()
            save()
        } catch {
            let err = Message(role: .assistant, text: "❌ \(error.localizedDescription)")
            chats[chatIdx].messages.insert(err, at: aIdx)
            chats[chatIdx].updatedAt = Date()
            save()
        }
    }

    func clearMessagesInActiveChat() {
        // Remove all messages but keep the chat itself.
        guard let id = activeChatID,
              let idx = chats.firstIndex(where: { $0.id == id })
        else { return }

        chats[idx].messages.removeAll()
        chats[idx].updatedAt = Date()
        save()
    }

    func clearAllChatsAndReset() {
        chats.removeAll()
        UserDefaults.standard.removeObject(forKey: chatsKey)

        let c = Chat()
        chats = [c]
        activeChatID = c.id
        save()
    }

    private func load() {
        // Load chat history from UserDefaults.
        if let raw = UserDefaults.standard.data(forKey: chatsKey) {
            do {
                let decoded = try JSONDecoder().decode([Chat].self, from: raw)
                chats = decoded
                activeChatID = decoded.first?.id
            } catch {
                print("Load chats_v2 failed: \(error)")
            }
        }
    }

    private func save() {
        // Persist chat history to UserDefaults.
        do {
            let data = try JSONEncoder().encode(chats)
            UserDefaults.standard.set(data, forKey: chatsKey)
        } catch {
            print("Save chats_v2 failed: \(error)")
        }
    }

    private func migrateLegacyIfNeeded() {
        // Migrate older single-thread format to multi-chat format.
        guard chats.isEmpty,
              let raw = UserDefaults.standard.data(forKey: legacySingleThreadKey),
              let decoded = try? JSONDecoder().decode([Message].self, from: raw),
              !decoded.isEmpty
        else { return }

        let migrated = Chat(title: "Migrated Chat", messages: decoded)
        chats = [migrated]
        activeChatID = migrated.id
        save()
        UserDefaults.standard.removeObject(forKey: legacySingleThreadKey)
    }

    private func buildContextualPrompt(forChatIndex idx: Int, newUserMessage: String, maxHistory: Int = 8) -> String {
        // Build a prompt that includes recent history for better answers.
        let history = chats[idx].messages.suffix(maxHistory)

        var convoLines: [String] = []
        for m in history {
            let prefix = (m.role == .user) ? "User" : "HushhVoice"
            convoLines.append("\(prefix): \(m.text)")
        }

        let historyBlock = convoLines.joined(separator: "\n")

        return """
        You are HushhVoice, a private, consent-first AI copilot.
        Continue the conversation based on the history below. Answer as HushhVoice.

        Conversation so far:
        \(historyBlock)

        User: \(newUserMessage)
        Assistant:
        """
    }

    private static func initialWordsTitle(from text: String, maxWords: Int = 6, maxChars: Int = 42) -> String {
        // Create a short title from the first words of the message.
        let words = text.split(whereSeparator: { $0.isNewline || $0.isWhitespace })
        let first = words.prefix(maxWords).joined(separator: " ")
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
        return String(trimmed[..<end]) + "…"
    }
}
