//
//  ContentView.swift
//  HushhVoice
//

import SwiftUI
import Foundation
import UIKit
import AuthenticationServices
import CryptoKit

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
        startPoint: .topLeading,
        endPoint: .bottomTrailing
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

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = .init(),
        updatedAt: Date = .init(),
        messages: [Message] = []
    ) {
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
    // Swap to prod when ready
//    static let base = URL(string: "https://a6ee2db28da0.ngrok-free.app")!
    static let base = URL(string: "https://hushhvoice-1.onrender.com")!
    

    static let appJWT = "Bearer dev-demo-app-jwt"

    static func ask(prompt: String, googleToken: String?) async throws -> SiriAskData {
        var req = URLRequest(url: base.appendingPathComponent("/siri/ask"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("founder@hushh.ai", forHTTPHeaderField: "X-User-Email")

        var tokens: [String: Any] = ["app_jwt": appJWT]
        if let googleToken {
            tokens["google_access_token"] = googleToken
        }

        let body: [String: Any] = [
            "prompt": prompt,
            "tokens": tokens
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)

        // 🔍 LOG RAW HTTP INFO
        if let http = resp as? HTTPURLResponse {
            print("🔵 /siri/ask status: \(http.statusCode)")
        } else {
            print("🔵 /siri/ask: non-HTTP response?")
        }

        if let raw = String(data: data, encoding: .utf8) {
            print("📩 RAW /siri/ask RESPONSE:\n\(raw)\n------------------------")
        } else {
            print("📩 RAW /siri/ask RESPONSE (non-UTF8, size \(data.count) bytes)")
        }

        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? JSONDecoder().decode(SiriAskResponse.self, from: data)
            let msg = decoded?.error?.message ?? "HTTP \(http.statusCode)"
            throw NSError(
                domain: "HushhAPI",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }

        let result = try JSONDecoder().decode(SiriAskResponse.self, from: data)

        // 🔍 LOG DECODED STRUCT TOO
        print("🧩 Decoded SiriAskResponse.ok = \(result.ok)")
        print("🧩 Decoded SiriAskResponse.data.display = \(result.data?.display ?? "nil")")
        print("🧩 Decoded SiriAskResponse.data.speech  = \(result.data?.speech ?? "nil")")

        guard let data = result.data else {
            throw NSError(
                domain: "HushhAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response"]
            )
        }
        return data
    }
}

// ======================================================
// MARK: - GOOGLE OAUTH (PKCE flow)
// ======================================================

@MainActor
final class GoogleSignInManager: NSObject, ObservableObject {
    static let shared = GoogleSignInManager()

    @Published var isSignedIn: Bool = false
    @Published var accessToken: String? = nil

    private let clientID =
        "1042954531759-s0cgfui9ss2o2kvpvfssu2k81gtjpop9.apps.googleusercontent.com"
    private let redirectURI =
        "com.googleusercontent.apps.1042954531759-s0cgfui9ss2o2kvpvfssu2k81gtjpop9:/oauthredirect"

    private let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events"
    ].joined(separator: " ")

    private var session: ASWebAuthenticationSession?
    private var codeVerifier: String?

    // MARK: Persistence

    func loadFromDisk() {
        if let token = UserDefaults.standard.string(forKey: "google_access_token") {
            accessToken = token
            isSignedIn = true
        }
    }

    func signOut() {
        accessToken = nil
        isSignedIn = false
        UserDefaults.standard.removeObject(forKey: "google_access_token")
    }

    // MARK: Sign-In (Auth Code + PKCE)

    func signIn() {
        let state = UUID().uuidString

        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = codeChallenge(from: verifier)

        let encodedScopes = scopes.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? ""

        let authURLString =
            "https://accounts.google.com/o/oauth2/v2/auth?" +
            "response_type=code" +
            "&client_id=\(clientID)" +
            "&redirect_uri=\(redirectURI)" +
            "&scope=\(encodedScopes)" +
            "&state=\(state)" +
            "&code_challenge=\(challenge)" +
            "&code_challenge_method=S256"

        guard let authURL = URL(string: authURLString) else {
            print("Failed to build auth URL")
            return
        }

        let scheme = "com.googleusercontent.apps.1042954531759-s0cgfui9ss2o2kvpvfssu2k81gtjpop9"

        session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: scheme
        ) { [weak self] callbackURL, error in
            guard let self else { return }

            if let error {
                print("Google sign-in failed: \(error.localizedDescription)")
                return
            }
            guard let callbackURL else {
                print("Google sign-in failed: missing callback URL")
                return
            }

            guard
                let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
            else {
                print("Failed to parse callback URL components")
                return
            }

            if let errorItem = components.queryItems?.first(where: { $0.name == "error" }),
               let errorValue = errorItem.value {
                print("Google auth error: \(errorValue)")
                return
            }

            guard let codeItem = components.queryItems?.first(where: { $0.name == "code" }),
                  let code = codeItem.value
            else {
                print("No auth code found in callback URL")
                return
            }

            Task {
                await self.exchangeCodeForToken(code: code)
            }
        }

        session?.presentationContextProvider = self
        session?.start()
    }

    private func exchangeCodeForToken(code: String) async {
        guard let verifier = codeVerifier else {
            print("Missing PKCE codeVerifier when exchanging token")
            return
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"

        let bodyParams: [String: String] = [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI
        ]

        let bodyString = bodyParams
            .map { key, value in
                let escaped = value.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed
                ) ?? ""
                return "\(key)=\(escaped)"
            }
            .joined(separator: "&")

        request.httpBody = bodyString.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                print("Token exchange: no HTTPURLResponse")
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("Token exchange failed: \(http.statusCode) \(body)")
                return
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let token = json?["access_token"] as? String

            if let token {
                accessToken = token
                isSignedIn = true
                UserDefaults.standard.set(token, forKey: "google_access_token")
                print("Google access token stored (prefix): \(token.prefix(10))...")
            } else {
                print("Token exchange: no access_token in response JSON")
            }
        } catch {
            print("Token exchange error: \(error)")
        }
    }

    // MARK: PKCE helpers

    private func generateCodeVerifier() -> String {
        var data = Data(count: 32)
        let result = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        if result != errSecSuccess {
            return base64url(Data(UUID().uuidString.utf8))
        }
        return base64url(data)
    }

    private func codeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hashed = SHA256.hash(data: data)
        return base64url(Data(hashed))
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
        if select {
            activeChatID = c.id
        }
        save()
    }

    func selectChat(_ chatID: UUID) { activeChatID = chatID }

    func deleteChat(_ chatID: UUID) {
        let wasActive = (activeChatID == chatID)
        chats.removeAll { $0.id == chatID }
        if wasActive {
            activeChatID = chats.first?.id
        }
        if chats.isEmpty {
            newChat(select: true)
        }
        save()
    }

    func renameChat(_ chatID: UUID, to newTitle: String) {
        guard let idx = chats.firstIndex(where: { $0.id == chatID }) else { return }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        chats[idx].title = title.isEmpty ? "Untitled" : title
        chats[idx].updatedAt = Date()
        let updated = chats.remove(at: idx)
        chats.insert(updated, at: 0)
        save()
    }

    func send(_ text: String, googleToken: String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let id = activeChatID,
              let idx = chats.firstIndex(where: { $0.id == id })
        else { return }

        // 1) Append the *user* message exactly as typed (for our local history)
        let userMsg = Message(role: .user, text: trimmed)
        chats[idx].messages.append(userMsg)
        chats[idx].updatedAt = Date()

        if chats[idx].title == "New Chat" {
            chats[idx].title = Self.initialWordsTitle(from: trimmed)
        }
        save()

        // 2) Build a context-aware prompt from recent history + this new turn
        let contextualPrompt = buildContextualPrompt(
            forChatIndex: idx,
            newUserMessage: trimmed,
            maxHistory: 10     // tweak window size as you like
        )

        // 3) Call backend with that context-aware prompt
        do {
            let data = try await HushhAPI.ask(prompt: contextualPrompt, googleToken: googleToken)
            let replyText =
                (data.display?.removingPercentEncoding ?? data.display)
                ?? data.speech
                ?? "(no response)"

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

    /// Regenerate response at a specific assistant message using the nearest preceding user message.
    func regenerate(at assistantMessageID: UUID, googleToken: String?) async {
        guard let chatID = activeChatID,
              let chatIdx = chats.firstIndex(where: { $0.id == chatID }),
              let aIdx = chats[chatIdx].messages.firstIndex(where: {
                  $0.id == assistantMessageID && $0.role == .assistant
              })
        else { return }

        let msgs = chats[chatIdx].messages
        guard let userIdx = (0..<aIdx).last(where: { msgs[$0].role == .user }) else { return }
        let prompt = msgs[userIdx].text

        chats[chatIdx].messages.remove(at: aIdx)
        save()

        do {
            let data = try await HushhAPI.ask(prompt: prompt, googleToken: googleToken)
            let replyText =
                (data.display?.removingPercentEncoding ?? data.display)
                ?? data.speech
                ?? "(no response)"

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
        guard let id = activeChatID,
              let idx = chats.firstIndex(where: { $0.id == id })
        else { return }

        chats[idx].messages.removeAll()
        chats[idx].updatedAt = Date()
        save()
    }

    // MARK: Persistence helpers

    private func load() {
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

    private func buildContextualPrompt(
        forChatIndex idx: Int,
        newUserMessage: String,
        maxHistory: Int = 8
    ) -> String {
        // Take the last N messages before this new turn
        let history = chats[idx].messages.suffix(maxHistory)

        var convoLines: [String] = []
        for m in history {
            let prefix = (m.role == .user) ? "User" : "HushhVoice"
            convoLines.append("\(prefix): \(m.text)")
        }

        let historyBlock = convoLines.joined(separator: "\n")

        // Final prompt the backend will see
        let prompt = """
        You are HushhVoice, a private, consent-first AI copilot.
        Continue the conversation based on the history below. Answer as HushhVoice.

        Conversation so far:
        \(historyBlock)

        User: \(newUserMessage)
        Assistant:
        """

        return prompt
    }

    private static func initialWordsTitle(
        from text: String,
        maxWords: Int = 6,
        maxChars: Int = 42
    ) -> String {
        let words = text.split(whereSeparator: { $0.isNewline || $0.isWhitespace })
        let first = words.prefix(maxWords).joined(separator: " ")
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
        return String(trimmed[..<end]) + "…"
    }
}

// ======================================================
// MARK: - STREAMING MARKDOWN VIEW
// ======================================================
struct StreamingMarkdownText: View {
    let fullText: String
    let animate: Bool
    let charDelay: TimeInterval

    @State private var visibleText: String = ""
    @State private var started = false

    var body: some View {
        renderedText(from: visibleText)
            .textSelection(.enabled)
            .onAppear {
                guard !started else { return }
                started = true
                if animate {
                    startTyping()
                } else {
                    visibleText = fullText
                }
            }
    }

    // MARK: - Typing animation

    private func startTyping() {
        visibleText = ""
        Task {
            for ch in fullText {
                try? await Task.sleep(
                    nanoseconds: UInt64(charDelay * 1_000_000_000)
                )
                visibleText.append(ch)
                if Task.isCancelled { break }
            }
        }
    }

    // MARK: - Tiny markdown-ish renderer (only **bold**)

    /// Very simple parser:
    /// - Treats `**...**` as bold.
    /// - Preserves all `\n` exactly (Text handles them correctly).
    private func renderedText(from text: String) -> Text {
        // If there's no bold marker at all, keep it simple.
        guard text.contains("**") else {
            return Text(text)
        }

        var result = Text("")
        var remaining = text[...]
        var isBold = false

        while let range = remaining.range(of: "**") {
            let before = remaining[..<range.lowerBound]
            if !before.isEmpty {
                let segment = Text(String(before))
                result = result + (isBold ? segment.bold() : segment)
            }

            // Flip bold mode and skip past the `**`
            isBold.toggle()
            remaining = remaining[range.upperBound...]
        }

        // Tail segment after the last `**`
        if !remaining.isEmpty {
            let segment = Text(String(remaining))
            result = result + (isBold ? segment.bold() : segment)
        }

        return result
    }
}

// ======================================================
// MARK: - HEADER (Google Sign-In/Out)
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
                Button { auth.signOut() } label: {
                    Label("Sign Out", systemImage: "person.crop.circle.badge.minus")
                        .labelStyle(.iconOnly)
                }
                .tint(.white)
            } else {
                Button { auth.signIn() } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                        .labelStyle(.iconOnly)
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
// MARK: - MESSAGE ROW (with assistant actions + streaming)
// ======================================================

struct MessageRow: View {
    let message: Message
    let isLastAssistant: Bool
    var onCopy: (() -> Void)?
    var onSpeak: (() -> Void)?
    var onReload: (() -> Void)?

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                if isUser { Spacer(minLength: 0) }

                VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                    messageBubble
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(
                            isUser
                            ? AnyView(
                                RoundedRectangle(cornerRadius: HVTheme.corner)
                                    .fill(HVTheme.userBubble)
                            )
                            : AnyView(
                                RoundedRectangle(cornerRadius: HVTheme.corner)
                                    .fill(HVTheme.surface)
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: HVTheme.corner)
                                .stroke(HVTheme.stroke)
                        )
                        .shadow(
                            color: .black.opacity(0.25),
                            radius: 6,
                            x: 0,
                            y: 2
                        )
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: isUser ? .trailing : .leading)
                                    .combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                        .animation(.easeOut(duration: 0.18), value: message.id)
                }

                if !isUser { Spacer(minLength: 0) }
            }

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
                    .foregroundStyle(
                        isLastAssistant ? HVTheme.accent : .white.opacity(0.7)
                    )

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

    @ViewBuilder
    private var messageBubble: some View {
        if isUser {
            Text(message.text)
                .font(.body)
                .foregroundStyle(HVTheme.userText)
                .multilineTextAlignment(.trailing)
        } else {
            StreamingMarkdownText(
                fullText: message.text,
                animate: isLastAssistant,
                charDelay: 0.01
            )
            .font(.body)
            .foregroundStyle(HVTheme.botText)
            .lineSpacing(4)                     // 👈 add breathing room between lines
            .multilineTextAlignment(.leading)   // 👈 left-align blocks
            .fixedSize(horizontal: false, vertical: true)
        }
    }

}

// ======================================================
// MARK: - COMPOSER
// ======================================================

struct ComposerView: View {
    @Binding var text: String
    var isSending: Bool
    var disabled: Bool
    var onSend: () -> Void

    private let fieldHeight: CGFloat = 36
    private var iconSize: CGFloat { 20 }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: {}) {
                Image(systemName: "mic.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .frame(width: fieldHeight, height: fieldHeight)
            }
            .background(Color.white.opacity(0.15))
            .foregroundStyle(.white)
            .clipShape(Circle())
            .disabled(true) // placeholder for future mic

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(HVTheme.surfaceAlt)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(HVTheme.stroke)
                    )
                    .shadow(
                        color: .black.opacity(0.25),
                        radius: 4,
                        x: 0,
                        y: 1
                    )

                HStack {
                    TextField(
                        "Ask HushhVoice…",
                        text: $text,
                        onCommit: { if !disabled { onSend() } }
                    )
                    .textInputAutocapitalization(.sentences)
                    .disableAutocorrection(false)
                    .foregroundColor(.white)
                    .font(.body)
                    .frame(height: fieldHeight)
                    .padding(.horizontal, 10)
                }
                .frame(height: fieldHeight)
            }
            .frame(height: fieldHeight)

            Button(action: onSend) {
                if isSending {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                }
            }
            .frame(width: fieldHeight, height: fieldHeight)
            .background(
                disabled ? Color.white.opacity(0.25) : Color.white
            )
            .foregroundStyle(
                disabled ? .black.opacity(0.5) : .black
            )
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
            Circle()
                .fill(.white.opacity(0.7))
                .frame(width: 7, height: 7)
                .scaleEffect(scale)
                .animation(
                    .easeInOut(duration: 0.9)
                        .repeatForever()
                        .delay(0.00),
                    value: scale
                )
            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: 7, height: 7)
                .scaleEffect(scale)
                .animation(
                    .easeInOut(duration: 0.9)
                        .repeatForever()
                        .delay(0.15),
                    value: scale
                )
            Circle()
                .fill(.white)
                .frame(width: 7, height: 7)
                .scaleEffect(scale)
                .animation(
                    .easeInOut(duration: 0.9)
                        .repeatForever()
                        .delay(0.30),
                    value: scale
                )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: HVTheme.corner)
                .fill(HVTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HVTheme.corner)
                .stroke(HVTheme.stroke)
        )
        .onAppear { scale = 1.0 }
    }
}

// ======================================================
// MARK: - SIDEBAR
// ======================================================

struct ChatSidebar: View {
    @ObservedObject var store: ChatStore
    @Binding var showingSettings: Bool
    @Binding var isCollapsed: Bool

    @State private var renamingChatID: UUID?
    @State private var renameText: String = ""

    @State private var showRenameAlert = false
    @State private var pendingRenameChatID: UUID?
    @State private var pendingRenameTitle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button { store.newChat(select: true) } label: {
                    Label("New", systemImage: "plus.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .tint(HVTheme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(HVTheme.bg.opacity(0.98))

            Divider().background(HVTheme.stroke)

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
                                    .foregroundStyle(
                                        isActive ? HVTheme.accent : .white.opacity(0.7)
                                    )
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    if renamingChatID == chat.id {
                                        TextField(
                                            "Title",
                                            text: $renameText,
                                            onCommit: { commitInlineRename(chat.id) }
                                        )
                                        .textFieldStyle(.roundedBorder)
                                        .foregroundStyle(.white)
                                    } else {
                                        Text(chat.title.isEmpty ? "Untitled" : chat.title)
                                            .font(
                                                .subheadline.weight(
                                                    isActive ? .semibold : .regular
                                                )
                                            )
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
                                    .fill(
                                        isActive
                                        ? Color.white.opacity(0.08)
                                        : Color.clear
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        isActive
                                        ? HVTheme.accent.opacity(0.5)
                                        : HVTheme.stroke,
                                        lineWidth: isActive ? 1.5 : 1
                                    )
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
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                renamingChatID = chat.id
                                renameText = chat.title
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(HVTheme.accent)
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            }

            Spacer(minLength: 6)

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
                    RoundedRectangle(cornerRadius: 12)
                        .fill(HVTheme.surfaceAlt)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(HVTheme.stroke)
                        )
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
        modifier(
            RenameAlertModifier(
                show: show,
                title: title,
                onSave: onSave,
                onCancel: onCancel
            )
        )
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
            content
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
                    Toggle(isOn: .constant(true)) { Text("Dark Mode") }
                        .disabled(true)
                    Toggle(isOn: .constant(true)) { Text("Hushh Backend") }
                        .disabled(true)
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
// MARK: - CHAT VIEW (overlay sidebar; empty state)
// ======================================================

struct ChatView: View {
    @StateObject private var store = ChatStore()
    @ObservedObject var auth = GoogleSignInManager.shared

    @State private var input: String = ""
    @State private var sending = false
    @State private var showTyping = false
    @State private var showSidebar: Bool = false
    @State private var showingSettings = false

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
            VStack(spacing: 0) {
                HeaderBar {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showSidebar.toggle()
                    }
                }

                ScrollViewReader { proxy in
                    ZStack {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(store.activeMessages) { msg in
                                    MessageRow(
                                        message: msg,
                                        isLastAssistant: isLastAssistant(msg),
                                        onCopy: { UIPasteboard.general.string = msg.text },
                                        onSpeak: { /* reserved for TTS hook */ },
                                        onReload: {
                                            Task {
                                                await store.regenerate(
                                                    at: msg.id,
                                                    googleToken: auth.accessToken
                                                )
                                            }
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
                            .transition(
                                .opacity.combined(with: .scale)
                            )
                        }
                    }
                    .onChange(of: store.activeMessages.last?.id) { _, id in
                        if let id {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: showTyping) { _, typing in
                        if typing {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo("typing", anchor: .bottom)
                            }
                        }
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

            if showSidebar {
                Color.black
                    .opacity(HVTheme.scrimOpacity)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showSidebar = false
                        }
                    }

                ChatSidebar(
                    store: store,
                    showingSettings: $showingSettings,
                    isCollapsed: $showSidebar
                )
                .frame(width: HVTheme.sidebarWidth)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .tint(HVTheme.accent)
        .sheet(isPresented: $showingSettings) {
            SettingsPlaceholderView()
        }
        .task { auth.loadFromDisk() }
        .onAppear { randomizeEmptyPhrase() }
        .onChange(of: store.activeChatID) { _ in
            randomizeEmptyPhrase()
        }
    }

    private func isLastAssistant(_ msg: Message) -> Bool {
        guard msg.role == .assistant else { return false }
        guard let last = store.activeMessages.last(where: { $0.role == .assistant }) else {
            return false
        }
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

// ======================================================
// MARK: - SIRI SHORTCUTS INLINE
// ======================================================

import AppIntents

// MARK: - Intent

struct AskHushhVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask HushhVoice"
    static var description = IntentDescription(
        "Ask HushhVoice anything"
    )

    @Parameter(title: "Question")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask HushhVoice: \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let googleToken = UserDefaults.standard.string(forKey: "google_access_token")
        let data = try await HushhAPI.ask(
            prompt: question,
            googleToken: googleToken   // 👈 send it through when present
        )

        let reply =
            (data.display?.removingPercentEncoding ?? data.display)
            ?? data.speech
            ?? "I couldn't get a response."

        return .result(
            dialog: IntentDialog(stringLiteral: reply)
        )
    }
}

// MARK: - App Shortcut

struct HushhVoiceAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHushhVoiceIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) anything"
            ],
            shortTitle: "Ask HushhVoice",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
    }
}
