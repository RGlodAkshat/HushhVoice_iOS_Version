//
//  ContentView.swift
//  HushhVoice
//
//  Overlay sidebar + scrim, safer left padding in sidebar,
//  compact single-line composer (no auto-growing) + mic button,
//  assistant message actions (copy / speak UI / reload answer),
//  Google Sign-In/Out in header, and empty-state placeholders.
//
//  Kept:
//  - Multi-chat sidebar (titles + timestamps, active highlight)
//  - New Chat, Delete, Rename with local persistence (UserDefaults)
//  - Modern chat UI: bubbles, shadows, smooth auto-scroll, animations
//  - Composer with Send button intact (unchanged behavior)
//  - Settings placeholder
//
//  Notes:
//  - Persists chats in UserDefaults ("chats_v2"). Migrates legacy single-thread messages ("chat_history_v1").
//  - Titles derive from the first user message.
//  - Sidebar slides OVER the chat with a dimmed scrim; chat does not shift or shrink.
//

import SwiftUI
import Foundation
import UIKit
import AuthenticationServices

// ======================================================
// MARK: - THEME
// ======================================================
enum HVTheme {
    static let bg = Color.black
    static let surface = Color(white: 0.12)
    static let surfaceAlt = Color(white: 0.08)
    static let stroke = Color.white.opacity(0.08)
    static let userBubble = LinearGradient(
        colors: [Color.white.opacity(0.95), Color.white.opacity(0.80)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let userText = Color.black
    static let botText = Color.white
    static let corner: CGFloat = 16

    static let accent = Color(hue: 0.53, saturation: 0.55, brightness: 0.95)
    static let sidebarWidth: CGFloat = 280
    static let scrimOpacity: CGFloat = 0.40
}

// ======================================================
// MARK: - MODELS & DTOs
// ======================================================
struct Message: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = .init()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

struct Chat: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]

    init(id: UUID = UUID(), title: String = "New Chat",
         createdAt: Date = .init(), updatedAt: Date = .init(),
         messages: [Message] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

struct SiriAskResponse: Decodable {
    let ok: Bool
    let data: SiriAskData?
    let error: SiriAskError?
}
struct SiriAskData: Decodable {
    let speech: String?
    let display: String?
    let open_url: String?
}
struct SiriAskError: Decodable {
    let message: String?
}

// ======================================================
// MARK: - API LAYER
// ======================================================
enum HushhAPI {
    static let base = URL(string: "https://hushhvoice-1.onrender.com")!
    static let appJWT = "Bearer dev-demo-app-jwt" // TODO: replace with real token

    static func ask(prompt: String, googleToken: String?) async throws -> SiriAskData {
        var req = URLRequest(url: base.appendingPathComponent("/siri/ask"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("founder@hushh.ai", forHTTPHeaderField: "X-User-Email")

        var tokens: [String: Any] = ["app_jwt": appJWT]
        if let googleToken { tokens["google_access_token"] = googleToken }

        let body: [String: Any] = ["prompt": prompt, "tokens": tokens]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        if !(200..<300).contains(http.statusCode) {
            let decoded = try? JSONDecoder().decode(SiriAskResponse.self, from: data)
            let msg = decoded?.error?.message ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "HushhAPI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let result = try JSONDecoder().decode(SiriAskResponse.self, from: data)
        guard let data = result.data else {
            throw NSError(domain: "HushhAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        return data
    }
}

// ======================================================
// MARK: - GOOGLE OAUTH
// ======================================================
@MainActor
final class GoogleSignInManager: NSObject, ObservableObject {
    static let shared = GoogleSignInManager()

    @Published var isSignedIn: Bool = false
    @Published var accessToken: String? = nil

    private let clientID = "1042954531759-s0cgfui9ss2o2kvpvfssu2k81gtjpop9.apps.googleusercontent.com"
    private let redirectURI = "com.googleusercontent.apps.1042954531759-s0cgfui9ss2o2kvpvfssu2k81gtjpop9:/oauthredirect"
    private let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events"
    ].joined(separator: " ")

    private var session: ASWebAuthenticationSession?

    func loadFromDisk() {
        if let token = UserDefaults.standard.string(forKey: "google_access_token") {
            self.accessToken = token
            self.isSignedIn = true
        }
    }

    func signIn() {
        let state = UUID().uuidString
        let url = URL(string:
            "https://accounts.google.com/o/oauth2/v2/auth?" +
            "response_type=token" +
            "&client_id=\(clientID)" +
            "&redirect_uri=\(redirectURI)" +
            "&scope=\(scopes.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" +
            "&state=\(state)"
        )!

        let scheme = "com.googleusercontent.apps.1042954531759-s0cgfui9ss2o2kvpvfssu2k81gtjpop9"

        session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] callbackURL, error in
            guard let self, error == nil, let callbackURL else {
                print("Google sign-in failed: \(error?.localizedDescription ?? "unknown")")
                return
            }
            guard let fragment = callbackURL.fragment else { return }
            let pairs = fragment.split(separator: "&")
            var map: [String: String] = [:]
            for kv in pairs {
                let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { map[parts[0]] = parts[1] }
            }
            if let token = map["access_token"] {
                self.accessToken = token
                self.isSignedIn = true
                UserDefaults.standard.set(token, forKey: "google_access_token")
            }
        }

        session?.presentationContextProvider = self
        session?.start()
    }

    func signOut() {
        accessToken = nil
        isSignedIn = false
        UserDefaults.standard.removeObject(forKey: "google_access_token")
    }
}

extension GoogleSignInManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

// ======================================================
// MARK: - STORE
// ======================================================
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var chats: [Chat] = []
    @Published var activeChatID: UUID?

    private let chatsKey = "chats_v2"
    private let legacySingleThreadKey = "chat_history_v1"

    init() {
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
        guard let id = activeChatID else { return nil }
        return chats.first(where: { $0.id == id })
    }
    var activeMessages: [Message] { activeChat?.messages ?? [] }

    func newChat(select: Bool = true) {
        let c = Chat()
        chats.insert(c, at: 0)
        if select { activeChatID = c.id }
        save()
    }

    func selectChat(_ chatID: UUID) { activeChatID = chatID }

    func deleteChat(_ chatID: UUID) {
        let wasActive = (activeChatID == chatID)
        chats.removeAll { $0.id == chatID }
        if wasActive { activeChatID = chats.first?.id }
        if chats.isEmpty { newChat(select: true) }
        save()
    }

    func renameChat(_ chatID: UUID, to newTitle: String) {
        guard let idx = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[idx].title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : newTitle
        chats[idx].updatedAt = Date()
        let updated = chats.remove(at: idx)
        chats.insert(updated, at: 0)
        save()
    }

    func send(_ text: String, googleToken: String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = activeChatID, let idx = chats.firstIndex(where: { $0.id == id }) else { return }

        let userMsg = Message(role: .user, text: trimmed)
        chats[idx].messages.append(userMsg)
        chats[idx].updatedAt = Date()

        if chats[idx].title == "New Chat" {
            chats[idx].title = Self.initialWordsTitle(from: trimmed)
        }
        save()

        do {
            let data = try await HushhAPI.ask(prompt: trimmed, googleToken: googleToken)
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

    /// Regenerate response *at a specific assistant message* using the nearest preceding user message.
    func regenerate(at assistantMessageID: UUID, googleToken: String?) async {
        guard let chatID = activeChatID,
              let chatIdx = chats.firstIndex(where: { $0.id == chatID }),
              let aIdx = chats[chatIdx].messages.firstIndex(where: { $0.id == assistantMessageID && $0.role == .assistant })
        else { return }

        let msgs = chats[chatIdx].messages
        guard let userIdx = (0..<aIdx).last(where: { msgs[$0].role == .user }) else { return }
        let prompt = msgs[userIdx].text

        // Remove the assistant answer we're reloading.
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
        guard let id = activeChatID, let idx = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[idx].messages.removeAll()
        chats[idx].updatedAt = Date()
        save()
    }

    private func load() {
        if let raw = UserDefaults.standard.data(forKey: chatsKey) {
            do {
                let decoded = try JSONDecoder().decode([Chat].self, from: raw)
                self.chats = decoded
                self.activeChatID = decoded.first?.id
            } catch {
                print("Load chats_v2 failed: \(error)")
            }
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(chats)
            UserDefaults.standard.set(data, forKey: chatsKey)
        } catch {
            print("Save chats_v2 failed: \(error)")
        }
    }

    private func migrateLegacyIfNeeded() {
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

    private static func initialWordsTitle(from text: String, maxWords: Int = 6, maxChars: Int = 42) -> String {
        let words = text.split(whereSeparator: { $0.isNewline || $0.isWhitespace })
        let first = words.prefix(maxWords).joined(separator: " ")
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
        return String(trimmed[..<end]) + "…"
    }
}

// ======================================================
// MARK: - HEADER (with Google Sign-In/Out)
// ======================================================
struct HeaderBar: View {
    var onToggleSidebar: (() -> Void)?
    @ObservedObject private var auth = GoogleSignInManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { onToggleSidebar?() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 18, weight: .semibold))
            }
            .tint(HVTheme.accent)

            Text("HushhVoice")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            if auth.isSignedIn {
                Button {
                    auth.signOut()
                } label: {
                    Label("Sign Out", systemImage: "person.crop.circle.badge.minus")
                        .labelStyle(.iconOnly)      // 👈 show only the icon
                }
                .tint(.white)
            } else {
                Button {
                    auth.signIn()
                } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                        .labelStyle(.iconOnly)      // 👈 show only the icon
                }
                .tint(.white)
            }

        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(HVTheme.bg.opacity(0.95))
    }
}

// ======================================================
// MARK: - MESSAGE BUBBLES (+ assistant actions)
// ======================================================
struct MessageRow: View {
    let message: Message
    let isLastAssistant: Bool
    var onCopy: (() -> Void)?
    var onSpeak: (() -> Void)?    // UI only
    var onReload: (() -> Void)?   // regenerate this answer

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                if isUser { Spacer(minLength: 0) }

                VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                    // Text(isUser ? "You" : "HushhVoice")
                    //     .font(.caption2)
                    //     .foregroundStyle(.white.opacity(0.6))

                    Text(message.text)
                        .textSelection(.enabled)
                        .font(.body)
                        .foregroundStyle(isUser ? HVTheme.userText : HVTheme.botText)
                        .padding(.vertical, 10).padding(.horizontal, 12)
                        .background(
                            isUser
                            ? AnyView(RoundedRectangle(cornerRadius: HVTheme.corner).fill(HVTheme.userBubble))
                            : AnyView(RoundedRectangle(cornerRadius: HVTheme.corner).fill(HVTheme.surface))
                        )
                        .overlay(RoundedRectangle(cornerRadius: HVTheme.corner).stroke(HVTheme.stroke))
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                        .transition(.asymmetric(
                            insertion: .move(edge: isUser ? .trailing : .leading).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .animation(.easeOut(duration: 0.18), value: message.id)
                }

                if !isUser { Spacer(minLength: 0) }
            }

            // Assistant message actions row
            if !isUser {
                HStack(spacing: 12) {
                    Button(action: { onCopy?() }) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.9))

                    Button(action: { onSpeak?() }) {
                        Label("Speak", systemImage: "speaker.wave.2.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.9))

                    Button(action: { onReload?() }) {
                        Label("Reload", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isLastAssistant ? HVTheme.accent : .white.opacity(0.7))

                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .opacity(0.9)
            }
        }
        .padding(.horizontal)
    }
}

// ======================================================
// MARK: - COMPOSER (Single-line TextField + Mic button)
//       (Send button left untouched per request)
// ======================================================
struct ComposerView: View {
    @Binding var text: String
    var isSending: Bool
    var disabled: Bool
    var onSend: () -> Void

    private let fieldHeight: CGFloat = 36 // single-line
    private var iconSize: CGFloat { 20 }

    var body: some View {
        HStack(spacing: 8) {

            // Microphone (UI only)
            Button(action: {}) {
                Image(systemName: "mic.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .frame(width: fieldHeight, height: fieldHeight)
            }
            .background(Color.white.opacity(0.15))
            .foregroundStyle(.white)
            .clipShape(Circle())
            .disabled(true) // UI only for now

            // Single-line input
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(HVTheme.surfaceAlt)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)

                HStack {
                    TextField("Ask HushhVoice…", text: $text, onCommit: { if !disabled { onSend() } })
                        .textInputAutocapitalization(.sentences)
                        .disableAutocorrection(false)
                        .foregroundColor(.white)
                        .font(.body)
                        .frame(height: fieldHeight)
                        .padding(.horizontal, 10)
                }
                .frame(height: fieldHeight)
            }
            .frame(height: fieldHeight) // 👈 pin container height (fixes tall background)

            // Send (unchanged)
            Button(action: onSend) {
                if isSending {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                }
            }
            .frame(width: fieldHeight, height: fieldHeight)
            .background(disabled ? Color.white.opacity(0.25) : Color.white)
            .foregroundStyle(disabled ? .black.opacity(0.5) : .black)
            .clipShape(Circle())
            .disabled(disabled)
        }
        .padding(.vertical, 4)
        .tint(HVTheme.accent)
    }
}

// ======================================================
// MARK: - TYPING INDICATOR
// ======================================================
struct TypingIndicatorView: View {
    @State private var scale: CGFloat = 0.2
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.white.opacity(0.7)).frame(width: 7, height: 7).scaleEffect(scale)
                .animation(.easeInOut(duration: 0.9).repeatForever().delay(0.00), value: scale)
            Circle().fill(.white.opacity(0.85)).frame(width: 7, height: 7).scaleEffect(scale)
                .animation(.easeInOut(duration: 0.9).repeatForever().delay(0.15), value: scale)
            Circle().fill(.white).frame(width: 7, height: 7).scaleEffect(scale)
                .animation(.easeInOut(duration: 0.9).repeatForever().delay(0.30), value: scale)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: HVTheme.corner).fill(HVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: HVTheme.corner).stroke(HVTheme.stroke))
        .onAppear { scale = 1.0 }
    }
}

// ======================================================
// MARK: - SIDEBAR (context menu: Rename + Delete)
// ======================================================
struct ChatSidebar: View {
    @ObservedObject var store: ChatStore
    @Binding var showingSettings: Bool
    @Binding var isCollapsed: Bool

    // Inline rename state
    @State private var renamingChatID: UUID?
    @State private var renameText: String = ""

    // Optional small alert (iOS 17+) fallback
    @State private var showRenameAlert = false
    @State private var pendingRenameChatID: UUID?
    @State private var pendingRenameTitle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header + New Chat
            HStack {
                Text("Chats")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button { store.newChat(select: true) } label: {
                    Label("New", systemImage: "plus.circle.fill").labelStyle(.iconOnly)
                }
                .tint(HVTheme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(HVTheme.bg.opacity(0.98))

            Divider().background(HVTheme.stroke)

            // List
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.chats) { chat in
                        let isActive = (chat.id == store.activeChatID)
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                store.selectChat(chat.id)
                                isCollapsed = false
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: isActive ? "message.fill" : "message")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(isActive ? HVTheme.accent : .white.opacity(0.7))
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    if renamingChatID == chat.id {
                                        TextField("Title", text: $renameText, onCommit: {
                                            commitInlineRename(chat.id)
                                        })
                                        .textFieldStyle(.roundedBorder)
                                        .foregroundStyle(.white)
                                    } else {
                                        Text(chat.title.isEmpty ? "Untitled" : chat.title)
                                            .font(.subheadline.weight(isActive ? .semibold : .regular))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                    }
                                    Text(chat.updatedAt, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isActive ? Color.white.opacity(0.08) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isActive ? HVTheme.accent.opacity(0.5) : HVTheme.stroke, lineWidth: isActive ? 1.5 : 1)
                            )
                        }
                        .contextMenu {
                            Button("Rename") {
                                if #available(iOS 17.0, *) {
                                    pendingRenameChatID = chat.id
                                    pendingRenameTitle = chat.title
                                    showRenameAlert = true
                                } else {
                                    renamingChatID = chat.id
                                    renameText = chat.title
                                }
                            }
                            Button(role: .destructive) {
                                store.deleteChat(chat.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.deleteChat(chat.id)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                renamingChatID = chat.id
                                renameText = chat.title
                            } label: { Label("Rename", systemImage: "pencil") }
                            .tint(HVTheme.accent)
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            }

            Spacer(minLength: 6)

            // Settings
            Button { showingSettings = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Settings").font(.subheadline)
                }
                .foregroundStyle(.white)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(HVTheme.surfaceAlt)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
                )
                .padding([.horizontal, .bottom], 10)
            }
            .tint(HVTheme.accent)
        }
        .frame(width: HVTheme.sidebarWidth)
        .background(HVTheme.bg)
        .shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 0)
        .transition(.move(edge: .leading).combined(with: .opacity))
        .ifAvailableiOS17RenameAlert(
            show: $showRenameAlert,
            title: $pendingRenameTitle,
            onSave: {
                if let id = pendingRenameChatID {
                    store.renameChat(id, to: pendingRenameTitle)
                    pendingRenameChatID = nil
                    pendingRenameTitle = ""
                }
            },
            onCancel: {
                pendingRenameChatID = nil
                pendingRenameTitle = ""
            }
        )
    }

    private func commitInlineRename(_ chatID: UUID) {
        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameChat(chatID, to: newTitle)
        renamingChatID = nil
        renameText = ""
    }
}

// Helper: conditional alert with TextField on iOS 17+. No-op on older iOS.
fileprivate extension View {
    func ifAvailableiOS17RenameAlert(
        show: Binding<Bool>,
        title: Binding<String>,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        modifier(RenameAlertModifier(show: show, title: title, onSave: onSave, onCancel: onCancel))
    }
}

fileprivate struct RenameAlertModifier: ViewModifier {
    @Binding var show: Bool
    @Binding var title: String
    var onSave: () -> Void
    var onCancel: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.alert("Rename Chat", isPresented: $show) {
                TextField("Title", text: $title)
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onSave() }
            } message: {
                Text("Enter a new title.")
            }
        } else {
            content // older iOS falls back to inline rename
        }
    }
}

// ======================================================
// MARK: - SETTINGS PLACEHOLDER
// ======================================================
struct SettingsPlaceholderView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Toggle(isOn: .constant(true)) { Text("Dark Mode") }.disabled(true)
                    Toggle(isOn: .constant(true)) { Text("Hushh Backend") }.disabled(true)
                }
                Section("About") {
                    Text("Version 0.1 (MVP)")
                    Text("Made with Aloha & Alpha 🫶")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// ======================================================
// MARK: - CHAT VIEW (overlay sidebar; chat unchanged size)
//       + Empty state placeholders
// ======================================================
struct ChatView: View {
    @StateObject private var store = ChatStore()
    @ObservedObject var auth = GoogleSignInManager.shared

    @State private var input: String = ""
    @State private var sending = false
    @State private var showTyping = false
    @State private var showSidebar: Bool = false
    @State private var showingSettings = false

    // Empty state phrases (rotated when chat is empty)
    private let emptyPhrases = [
        "Hi, I'm HushhVoice. How may I help you?",
        "Ready when you are — ask me anything.",
        "Your data. Your business. How can I assist?",
        "Let’s build something useful. What’s on your mind?",
        "Ask away. I’ll keep it crisp."
    ]
    @State private var currentEmptyPhrase: String = ""

    var body: some View {
        ZStack(alignment: .leading) {
            // Base conversation (not resized by sidebar)
            VStack(spacing: 0) {
                HeaderBar(onToggleSidebar: { withAnimation(.easeInOut(duration: 0.22)) { showSidebar.toggle() } })

                ScrollViewReader { proxy in
                    ZStack {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(store.activeMessages) { msg in
                                    MessageRow(
                                        message: msg,
                                        isLastAssistant: isLastAssistant(msg),
                                        onCopy: { UIPasteboard.general.string = msg.text },
                                        onSpeak: { /* UI only */ },
                                        onReload: {
                                            Task { await store.regenerate(at: msg.id, googleToken: auth.accessToken) }
                                        }
                                    )
                                    .id(msg.id)
                                }
                                if showTyping {
                                    TypingIndicatorView().id("typing")
                                }
                            }
                            .padding(.vertical, 12)
                        }

                        // Empty-state placeholder
                        if store.activeMessages.isEmpty {
                            VStack(spacing: 10) {
                                Text(currentEmptyPhrase)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                Rectangle()
                                    .fill(.white.opacity(0.06))
                                    .frame(width: 220, height: 8)
                                    .cornerRadius(4)
                                Rectangle()
                                    .fill(.white.opacity(0.06))
                                    .frame(width: 260, height: 8)
                                    .cornerRadius(4)
                                Rectangle()
                                    .fill(.white.opacity(0.06))
                                    .frame(width: 180, height: 8)
                                    .cornerRadius(4)
                            }
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .transition(.opacity.combined(with: .scale))
                        }
                    }
                    .onChange(of: store.activeMessages.last?.id) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                    .onChange(of: showTyping) { _, typing in
                        if typing { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("typing", anchor: .bottom) } }
                    }
                }

                Divider().background(HVTheme.stroke)

                HStack {
                    ComposerView(
                        text: $input,
                        isSending: sending,
                        disabled: sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        onSend: { Task { await send() } }
                    )
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
            .background(HVTheme.bg.ignoresSafeArea())

            // SCRIM + SIDEBAR (overlay)
            if showSidebar {
                Color.black
                    .opacity(HVTheme.scrimOpacity)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.22)) { showSidebar = false } }

                ChatSidebar(store: store, showingSettings: $showingSettings, isCollapsed: $showSidebar)
                    .frame(width: HVTheme.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .tint(HVTheme.accent)
        .sheet(isPresented: $showingSettings) { SettingsPlaceholderView() }
        .task { auth.loadFromDisk() }
        .onAppear { randomizeEmptyPhrase() }
        .onChange(of: store.activeChatID) { _ in randomizeEmptyPhrase() }
    }

    private func isLastAssistant(_ msg: Message) -> Bool {
        guard msg.role == .assistant else { return false }
        guard let last = store.activeMessages.last(where: { $0.role == .assistant }) else { return false }
        return last.id == msg.id
    }

    private func randomizeEmptyPhrase() {
        currentEmptyPhrase = emptyPhrases.randomElement() ?? emptyPhrases[0]
    }

    private func send() async {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        sending = true
        input = ""
        showTyping = true
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        await store.send(q, googleToken: auth.accessToken)
        showTyping = false
        sending = false
    }
}

#Preview { ChatView() }

// ======================================================
// MARK: - Legacy (disabled)
// ======================================================
#if false
import OpenAIKit
import Combine
#endif
