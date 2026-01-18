import Foundation
import SwiftUI

// Manages chats, persistence, and message sending.
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var chats: [Chat] = []
    @Published var activeChatID: UUID?
    @Published var turnState: ChatTurnState = .idle
    @Published private(set) var currentTurnID: String?

    @Published var isDraftUserActive: Bool = false
    @Published var draftUserText: String = ""
    @Published private(set) var draftUserID: UUID?
    @Published private(set) var draftUserTimestamp: Date?

    @Published var isAssistantStreaming: Bool = false
    @Published var streamingAssistantText: String = ""
    @Published private(set) var streamingAssistantID: UUID?
    @Published private(set) var streamingAssistantTimestamp: Date?

    @Published var pendingAttachments: [ChatAttachment] = []
    @Published var confirmations: [ChatConfirmation] = []
    @Published var hintText: String?
    @Published var progressText: String?

    private var hintClearTask: DispatchWorkItem?

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

    var draftUserMessage: Message? {
        guard isDraftUserActive else { return nil }
        let id = draftUserID ?? UUID()
        let ts = draftUserTimestamp ?? Date()
        return Message(id: id, role: .user, text: draftUserText, timestamp: ts)
    }

    var streamingAssistantMessage: Message? {
        guard isAssistantStreaming else { return nil }
        let id = streamingAssistantID ?? UUID()
        let ts = streamingAssistantTimestamp ?? Date()
        return Message(id: id, role: .assistant, text: streamingAssistantText, timestamp: ts)
    }

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

        setTurnState(.thinking)

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
            clearPendingAttachments()
            setTurnState(.idle)
        } catch {
            showHint("We couldn’t reach HushhVoice just now. Try again.")
            clearPendingAttachments()
            setTurnState(.idle)
        }
    }

    func appendUserMessage(_ text: String) {
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
    }

    func sendVoiceTranscript(_ text: String, googleToken: String?) async {
        // Send a voice transcript that already exists in the chat history.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let id = activeChatID,
              let idx = chats.firstIndex(where: { $0.id == id })
        else { return }

        setTurnState(.thinking)

        let contextualPrompt = buildContextualPrompt(
            forChatIndex: idx,
            newUserMessage: trimmed,
            maxHistory: 10,
            includeNewMessage: false
        )

        do {
            let data = try await HushhAPI.ask(prompt: contextualPrompt, googleToken: googleToken)
            let replyText = (data.display?.removingPercentEncoding ?? data.display) ?? data.speech ?? "(no response)"

            let botMsg = Message(role: .assistant, text: replyText)
            chats[idx].messages.append(botMsg)
            chats[idx].updatedAt = Date()
            save()
            clearPendingAttachments()
            setTurnState(.idle)
        } catch {
            showHint("We couldn’t reach HushhVoice just now. Try again.")
            clearPendingAttachments()
            setTurnState(.idle)
        }
    }

    func regenerate(at assistantMessageID: UUID, googleToken: String?) async {
        // Re-run the backend for the latest user message.
        guard let chatID = activeChatID,
              let chatIdx = chats.firstIndex(where: { $0.id == chatID }),
              let aIdx = chats[chatIdx].messages.firstIndex(where: { $0.id == assistantMessageID && $0.role == .assistant })
        else { return }

        setTurnState(.thinking)

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
            setTurnState(.idle)
        } catch {
            showHint("Couldn’t regenerate that response. Try again.")
            setTurnState(.idle)
        }
    }

    func clearMessagesInActiveChat() {
        // Remove all messages but keep the chat itself.
        guard let id = activeChatID,
              let idx = chats.firstIndex(where: { $0.id == id })
        else { return }

        chats[idx].messages.removeAll()
        chats[idx].updatedAt = Date()
        cancelVoiceDraft()
        clearAssistantStream()
        clearCurrentTurn()
        save()
    }

    func removeMessage(_ messageID: UUID) {
        guard let id = activeChatID,
              let idx = chats.firstIndex(where: { $0.id == id })
        else { return }

        chats[idx].messages.removeAll { $0.id == messageID }
        chats[idx].updatedAt = Date()
        save()
    }

    func markMessageInterrupted(_ messageID: UUID) {
        guard let id = activeChatID,
              let idx = chats.firstIndex(where: { $0.id == id }),
              let msgIdx = chats[idx].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        chats[idx].messages[msgIdx].status = .interrupted
        chats[idx].updatedAt = Date()
        save()
    }

    func clearAllChatsAndReset() {
        chats.removeAll()
        UserDefaults.standard.removeObject(forKey: chatsKey)

        let c = Chat()
        chats = [c]
        activeChatID = c.id
        cancelVoiceDraft()
        clearAssistantStream()
        clearCurrentTurn()
        clearPendingAttachments()
        confirmations.removeAll()
        save()
    }

    func setTurnState(_ state: ChatTurnState) {
        turnState = state
    }

    func setCurrentTurnID(_ turnID: String?) {
        currentTurnID = turnID
    }

    func clearCurrentTurn() {
        currentTurnID = nil
    }

    func beginVoiceDraft() {
        isDraftUserActive = true
        draftUserID = UUID()
        draftUserTimestamp = Date()
        draftUserText = ""
    }

    func updateVoiceDraft(_ text: String) {
        if !isDraftUserActive {
            beginVoiceDraft()
        }
        draftUserText = text
    }

    func finalizeVoiceDraft(appendToChat: Bool = true) -> String? {
        guard isDraftUserActive else { return nil }
        let finalText = draftUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        if appendToChat, !finalText.isEmpty, let chatID = activeChatID,
           let idx = chats.firstIndex(where: { $0.id == chatID }) {
            let msg = Message(
                id: draftUserID ?? UUID(),
                role: .user,
                text: finalText,
                timestamp: draftUserTimestamp ?? Date()
            )
            chats[idx].messages.append(msg)
            chats[idx].updatedAt = Date()
            if chats[idx].title == "New Chat" {
                chats[idx].title = Self.initialWordsTitle(from: finalText)
            }
            save()
        }
        cancelVoiceDraft()
        return finalText.isEmpty ? nil : finalText
    }

    func cancelVoiceDraft() {
        isDraftUserActive = false
        draftUserText = ""
        draftUserID = nil
        draftUserTimestamp = nil
    }

    func beginAssistantStream() {
        isAssistantStreaming = true
        streamingAssistantID = UUID()
        streamingAssistantTimestamp = Date()
        streamingAssistantText = ""
    }

    func updateAssistantStream(_ text: String) {
        if !isAssistantStreaming {
            beginAssistantStream()
        }
        streamingAssistantText = text
    }

    func appendAssistantStream(_ text: String) {
        if !isAssistantStreaming {
            beginAssistantStream()
        }
        streamingAssistantText += text
    }

    func finalizeAssistantStream(status: Message.Status = .normal) {
        guard isAssistantStreaming else { return }
        let finalText = streamingAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty, let chatID = activeChatID,
           let idx = chats.firstIndex(where: { $0.id == chatID }) {
            let msg = Message(
                id: streamingAssistantID ?? UUID(),
                role: .assistant,
                text: finalText,
                timestamp: streamingAssistantTimestamp ?? Date(),
                status: status
            )
            chats[idx].messages.append(msg)
            chats[idx].updatedAt = Date()
            save()
        }
        clearAssistantStream()
    }

    func clearAssistantStream() {
        isAssistantStreaming = false
        streamingAssistantText = ""
        streamingAssistantID = nil
        streamingAssistantTimestamp = nil
    }

    func addPendingAttachment(_ attachment: ChatAttachment) {
        pendingAttachments.append(attachment)
    }

    func removePendingAttachment(_ attachment: ChatAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    func clearPendingAttachments() {
        pendingAttachments.removeAll()
    }

    func addConfirmation(_ confirmation: ChatConfirmation) {
        confirmations.append(confirmation)
    }

    func updateConfirmation(_ confirmationID: UUID, status: ChatConfirmation.Status) {
        guard let idx = confirmations.firstIndex(where: { $0.id == confirmationID }) else { return }
        confirmations[idx].status = status
    }

    func removeConfirmation(_ confirmationID: UUID) {
        confirmations.removeAll { $0.id == confirmationID }
    }

    func showHint(_ text: String, duration: TimeInterval = 2.6) {
        hintClearTask?.cancel()
        hintText = text
        let task = DispatchWorkItem { [weak self] in
            self?.hintText = nil
        }
        hintClearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    func setProgress(_ text: String?) {
        progressText = text
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

    private func buildContextualPrompt(
        forChatIndex idx: Int,
        newUserMessage: String,
        maxHistory: Int = 8,
        includeNewMessage: Bool = true
    ) -> String {
        // Build a prompt that includes recent history for better answers.
        let history = chats[idx].messages.suffix(maxHistory)

        var convoLines: [String] = []
        for m in history {
            let prefix = (m.role == .user) ? "User" : "HushhVoice"
            convoLines.append("\(prefix): \(m.text)")
        }

        if includeNewMessage {
            convoLines.append("User: \(newUserMessage)")
        }

        let historyBlock = convoLines.joined(separator: "\n")

        return """
        You are HushhVoice, a private, consent-first AI copilot.
        Continue the conversation based on the history below. Answer as HushhVoice.

        Conversation so far:
        \(historyBlock)

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
