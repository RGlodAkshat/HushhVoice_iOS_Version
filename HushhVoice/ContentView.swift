//
//  ContentView.swift
//  HushhVoice
// yiy erfefr
//  Main chat UI + models + networking + auth helpers.

import SwiftUI
import Foundation
import UIKit
import AuthenticationServices
import CryptoKit
import AVFoundation
import AppIntents

// ======================================================
// MARK: - THEME
// ======================================================

// Centralized colors and layout constants for consistent styling.
enum HVTheme {
    private static var _isDark: Bool = true

    static func setMode(isDark: Bool) { _isDark = isDark }
    static var isDark: Bool { _isDark }

    static var bg: Color { isDark ? .black : Color(white: 0.985) }
    static var surface: Color { isDark ? Color(white: 0.12) : .white }
    static var surfaceAlt: Color { isDark ? Color(white: 0.08) : Color(white: 0.94) }
    static var stroke: Color { isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06) }

    static var userBubble: LinearGradient {
        if isDark {
            return LinearGradient(
                colors: [Color.white.opacity(0.95), Color.white.opacity(0.80)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [Color.white, Color(white: 0.96)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    static var userText: Color { .black }
    static var botText: Color { isDark ? .white : Color(red: 0.12, green: 0.14, blue: 0.20) }

    static var accent: Color {
        if isDark {
            return Color(hue: 0.53, saturation: 0.55, brightness: 0.95)
        } else {
            return Color(red: 0.00, green: 0.55, blue: 0.43)
        }
    }

    static let corner: CGFloat = 16
    static let sidebarWidth: CGFloat = 280
    static let scrimOpacity: CGFloat = 0.40
}

// ======================================================
// MARK: - MODELS & DTOs
// ======================================================

// Chat message model used throughout the UI and persistence.
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

// Chat thread model that holds a list of messages.
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

// Decoding models for the /siri/ask API response.
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

// Lightweight network client for your backend.
enum HushhAPI {
    static let base = URL(string: "https://hushhvoice-1.onrender.com")!
//    static let base = URL(string: "https://03d925e4dffe.ngrok-free.app")!
    
    
    static let appJWT = "Bearer dev-demo-app-jwt"

    static func ask(prompt: String, googleToken: String?) async throws -> SiriAskData {
        // Build the request for the ask endpoint.
        var req = URLRequest(url: base.appendingPathComponent("/siri/ask"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("founder@hushh.ai", forHTTPHeaderField: "X-User-Email")

        var tokens: [String: Any] = ["app_jwt": appJWT]
        if let googleToken { tokens["google_access_token"] = googleToken }

        let body: [String: Any] = [
            "prompt": prompt,
            "tokens": tokens
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Perform the network call.
        let (data, resp) = try await URLSession.shared.data(for: req)

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

        // Validate HTTP status before decoding.
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? JSONDecoder().decode(SiriAskResponse.self, from: data)
            let msg = decoded?.error?.message ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "HushhAPI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }

        // Decode JSON into Swift structs.
        let result = try JSONDecoder().decode(SiriAskResponse.self, from: data)

        print("🧩 Decoded SiriAskResponse.ok = \(result.ok)")
        print("🧩 Decoded SiriAskResponse.data.display = \(result.data?.display ?? "nil")")
        print("🧩 Decoded SiriAskResponse.data.speech  = \(result.data?.speech ?? "nil")")

        guard let data = result.data else {
            throw NSError(domain: "HushhAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        return data
    }

    static func tts(text: String, voice: String? = nil) async throws -> Data {
        // Request audio data from backend TTS.
        var req = URLRequest(url: base.appendingPathComponent("/tts"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["text": text]
        if let voice, !voice.isEmpty { body["voice"] = voice }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "HushhAPI.TTS", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }

        return data
    }

    static func deleteAccount(googleToken: String?, appleUserID: String?, kaiUserID: String?) async throws {
        // Tell backend to delete the account associated with tokens/IDs.
        var req = URLRequest(url: base.appendingPathComponent("/account/delete"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [:]
        if let googleToken { payload["google_access_token"] = googleToken }
        if let appleUserID, !appleUserID.isEmpty {
            payload["apple_user_id"] = appleUserID
            payload["user_id"] = appleUserID
        }
        if let kaiUserID, !kaiUserID.isEmpty {
            payload["kai_user_id"] = kaiUserID
            if payload["user_id"] == nil {
                payload["user_id"] = kaiUserID
            }
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "HushhAPI.DeleteAccount", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}

// ======================================================
// MARK: - GOOGLE OAUTH (PKCE flow + REFRESH)
// ======================================================

// Handles Google OAuth sign-in, refresh, and token storage.
@MainActor
final class GoogleSignInManager: NSObject, ObservableObject {
    static let shared = GoogleSignInManager()

    @Published var isSignedIn: Bool = false
    @Published var accessToken: String? = nil

    var hasConnectedGoogle: Bool {
        isSignedIn || accessToken != nil || defaults.string(forKey: tokenKey) != nil
    }

    // UserDefaults keys for token storage.
    private let tokenKey = "google_access_token"
    private let refreshTokenKey = "google_refresh_token"
    private let expiryKey = "google_token_expiry"

    // App Group lets the main app and extensions share tokens.
    private let appGroupID = "group.ai.hushh.hushhvoice"
    private var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    // OAuth client details from Google Cloud Console.
    private let clientID =
        "1042954531759-s0cgfui9ss2o2kvpvfssu2k81gtjpop9.apps.googleusercontent.com"
    private let redirectURI =
        "com.googleusercontent.apps.1042954531759-s0cgfui9ss2o2kvpvfssu2k81gtjpop9:/oauthredirect"

    // OAuth scopes for Gmail + Calendar.
    private let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events"
    ].joined(separator: " ")

    private var session: ASWebAuthenticationSession?
    private var codeVerifier: String?

    func loadFromDisk() {
        // Load token from disk so UI can show signed-in state.
        if let token = defaults.string(forKey: tokenKey) {
            accessToken = token
            isSignedIn = true
        } else {
            isSignedIn = false
        }
    }

    func signOut() {
        // Clear in-memory and persisted tokens.
        accessToken = nil
        isSignedIn = false
        defaults.removeObject(forKey: tokenKey)
        defaults.removeObject(forKey: refreshTokenKey)
        defaults.removeObject(forKey: expiryKey)
    }

    func disconnect() async {
        // Revoke token on Google side, then clear local state.
        let tokenToRevoke = accessToken ?? defaults.string(forKey: tokenKey)
        if let tokenToRevoke, let url = URL(string: "https://oauth2.googleapis.com/revoke?token=\(tokenToRevoke)") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: req)
        }
        signOut()
    }

    private var storedRefreshToken: String? { defaults.string(forKey: refreshTokenKey) }

    private var tokenExpiryDate: Date? {
        let ts = defaults.double(forKey: expiryKey)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    private func saveTokens(accessToken: String, refreshToken: String?, expiresIn: TimeInterval?) {
        // Persist access token, optional refresh token, and expiry.
        self.accessToken = accessToken
        defaults.set(accessToken, forKey: tokenKey)

        if let rt = refreshToken, !rt.isEmpty {
            defaults.set(rt, forKey: refreshTokenKey)
        }

        if let expiresIn {
            let expiry = Date().addingTimeInterval(expiresIn - 30)
            defaults.set(expiry.timeIntervalSince1970, forKey: expiryKey)
        }
    }

    func ensureValidAccessToken() async -> String? {
        // Use cached token if valid, otherwise refresh.
        if accessToken == nil && defaults.string(forKey: tokenKey) != nil {
            print("🔵 ensureValidAccessToken: loading from disk for this process")
            loadFromDisk()
        }

        if let expiry = tokenExpiryDate,
           expiry > Date(),
           let token = accessToken ?? defaults.string(forKey: tokenKey) {
            isSignedIn = true
            print("🔵 ensureValidAccessToken: using cached token (prefix \(token.prefix(8)))")
            return token
        }

        guard let refreshToken = storedRefreshToken else {
            print("🔴 ensureValidAccessToken: no refresh token stored")
            accessToken = nil
            isSignedIn = false
            return nil
        }

        do {
            let newToken = try await refreshAccessToken(refreshToken: refreshToken)
            isSignedIn = true
            return newToken
        } catch {
            print("🔴 Token refresh failed: \(error)")
            accessToken = nil
            isSignedIn = false
            return nil
        }
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        // Token refresh via OAuth endpoint.
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"

        let bodyParams: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]

        let bodyString = bodyParams
            .map { key, value in
                let escaped = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                return "\(key)=\(escaped)"
            }
            .joined(separator: "&")

        request.httpBody = bodyString.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GoogleAuth", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Refresh failed: \(body)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["access_token"] as? String else {
            throw NSError(domain: "GoogleAuth", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No access_token in refresh response"])
        }
        let expiresIn = json?["expires_in"] as? TimeInterval

        saveTokens(accessToken: token, refreshToken: nil, expiresIn: expiresIn)
        print("✅ Google access token refreshed (prefix): \(token.prefix(10))...")
        return token
    }

    func signIn() {
        // Start the OAuth PKCE flow in a web authentication session.
        let state = UUID().uuidString

        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = codeChallenge(from: verifier)

        let encodedScopes = scopes.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        let authURLString =
            "https://accounts.google.com/o/oauth2/v2/auth?" +
            "response_type=code" +
            "&client_id=\(clientID)" +
            "&redirect_uri=\(redirectURI)" +
            "&scope=\(encodedScopes)" +
            "&state=\(state)" +
            "&access_type=offline" +
            "&prompt=consent" +
            "&code_challenge=\(challenge)" +
            "&code_challenge_method=S256"

        guard let authURL = URL(string: authURLString) else {
            print("Failed to build auth URL")
            return
        }

        let scheme = "com.googleusercontent.apps.1042954531759-s0cgfui9ss2o2kvpvfssu2k81gtjpop9"

        session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { [weak self] callbackURL, error in
            guard let self else { return }

            if let error {
                print("Google sign-in failed: \(error.localizedDescription)")
                return
            }
            guard let callbackURL else {
                print("Google sign-in failed: missing callback URL")
                return
            }

            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
                print("Failed to parse callback URL components")
                return
            }

            if let errorItem = components.queryItems?.first(where: { $0.name == "error" }),
               let errorValue = errorItem.value {
                print("Google auth error: \(errorValue)")
                return
            }

            guard let codeItem = components.queryItems?.first(where: { $0.name == "code" }),
                  let code = codeItem.value else {
                print("No auth code found in callback URL")
                return
            }

            Task { await self.exchangeCodeForToken(code: code) }
        }

        session?.presentationContextProvider = self
        session?.start()
    }

    private func exchangeCodeForToken(code: String) async {
        // Exchange auth code for access/refresh tokens.
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
                let escaped = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
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
            let refreshToken = json?["refresh_token"] as? String
            let expiresIn = json?["expires_in"] as? TimeInterval

            if let token {
                saveTokens(accessToken: token, refreshToken: refreshToken, expiresIn: expiresIn)
                isSignedIn = true
                print("Google access token stored (prefix): \(token.prefix(10))...")
            } else {
                print("Token exchange: no access_token in response JSON")
            }
        } catch {
            print("Token exchange error: \(error)")
        }
    }

    private func generateCodeVerifier() -> String {
        // PKCE code verifier: random, URL-safe string.
        var data = Data(count: 32)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        if result != errSecSuccess { return base64url(Data(UUID().uuidString.utf8)) }
        return base64url(data)
    }

    private func codeChallenge(from verifier: String) -> String {
        // PKCE code challenge derived from verifier.
        let data = Data(verifier.utf8)
        let hashed = SHA256.hash(data: data)
        return base64url(Data(hashed))
    }

    private func base64url(_ data: Data) -> String {
        // Base64 URL-safe encoding (no padding).
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension GoogleSignInManager: ASWebAuthenticationPresentationContextProviding {
    // Provide a window for presenting the web auth session.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

// ======================================================
// MARK: - SPEECH MANAGER (TTS + Stop + State)
// ===================================================

// Plays backend TTS audio and falls back to system speech.
final class SpeechManager: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = SpeechManager()

    @Published var currentMessageID: UUID?
    @Published var isLoading: Bool = false
    @Published var isPlaying: Bool = false

    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        // Listen for synth completion callbacks.
        synth.delegate = self
    }

    func speak(_ text: String, messageID: UUID?) {
        // Public entry point: trims input then speaks.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await speakAsync(trimmed, messageID: messageID) }
    }

    func stop() { Task { await MainActor.run { self.stopAllInternal() } } }

    private func speakAsync(_ text: String, messageID: UUID?) async {
        // Reset state and configure audio session.
        await MainActor.run {
            self.stopAllInternal()
            self.currentMessageID = messageID
            self.isLoading = true
            self.isPlaying = false
            self.configureAudioSession()
        }

        do {
            // Prefer backend TTS audio (better voice).
            let audioData = try await HushhAPI.tts(text: text, voice: "alloy")
            try await MainActor.run {
                self.player = try AVAudioPlayer(data: audioData)
                self.player?.delegate = self
                self.player?.prepareToPlay()
                self.isLoading = false
                self.isPlaying = true
                self.player?.play()
            }
            return
        } catch {
            // If backend fails, fall back to system voice.
            print("🔴 Backend TTS failed, falling back to system voice: \(error)")
        }

        await MainActor.run {
            self.isLoading = false
            self.isPlaying = true
            let utterance = AVSpeechUtterance(string: text)
            if let betterVoice = AVSpeechSynthesisVoice(language: "en-US") {
                utterance.voice = betterVoice
            }
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
            self.synth.speak(utterance)
        }
    }

    private func configureAudioSession() {
        // Configure audio for spoken audio with speaker + Bluetooth.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
            )
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("AudioSession error: \(error)")
        }
    }

    private func stopAllInternal() {
        // Stop any active audio and reset state flags.
        if let player, player.isPlaying { player.stop() }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }

        player = nil
        isLoading = false
        isPlaying = false
        currentMessageID = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [])
        } catch {
            print("AudioSession deactivation error: \(error)")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Clean up when playback ends.
        Task { await MainActor.run { self.stopAllInternal() } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Clean up when system voice finishes.
        Task { await MainActor.run { self.stopAllInternal() } }
    }
}

// ======================================================
// MARK: - STORE
// ======================================================

// Manages chats, persistence, and message sending.
@MainActor
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

// ======================================================
// MARK: - STREAMING MARKDOWN VIEW
// ======================================================

// Displays text with a simple streaming/typing effect and basic **bold** parsing.
struct StreamingMarkdownText: View {
    let fullText: String
    let animate: Bool
    let charDelay: TimeInterval

    @State private var visibleText: String = ""
    @State private var started = false

    var body: some View {
        // Render whatever text is currently visible.
        renderedText(from: visibleText)
            .textSelection(.enabled)
            .onAppear {
                guard !started else { return }
                started = true
                if animate { startTyping() } else { visibleText = fullText }
            }
    }

    private func startTyping() {
        // Reveal one character at a time to simulate typing.
        visibleText = ""
        Task {
            for ch in fullText {
                try? await Task.sleep(nanoseconds: UInt64(charDelay * 1_000_000_000))
                visibleText.append(ch)
                if Task.isCancelled { break }
            }
        }
    }

    private func renderedText(from text: String) -> Text {
        // Naive Markdown: only handles **bold** segments.
        guard text.contains("**") else { return Text(text) }

        var result = Text("")
        var remaining = text[...]
        var isBold = false

        while let range = remaining.range(of: "**") {
            let before = remaining[..<range.lowerBound]
            if !before.isEmpty {
                let segment = Text(String(before))
                result = result + (isBold ? segment.bold() : segment)
            }
            isBold.toggle()
            remaining = remaining[range.upperBound...]
        }

        if !remaining.isEmpty {
            let segment = Text(String(remaining))
            result = result + (isBold ? segment.bold() : segment)
        }
        return result
    }
}

// ======================================================
// MARK: - HEADER (clean)
// ======================================================

// Top app bar with menu toggle and quick link button.
struct HeaderBar: View {
    var onToggleSidebar: (() -> Void)?
    var onGoToHushhTech: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { onToggleSidebar?() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 18, weight: .semibold))
            }
            .tint(HVTheme.accent)

            Text("HushhVoice")
                .font(.headline)
                .foregroundStyle(HVTheme.botText)

            Spacer()

            Button {
                onGoToHushhTech?()
            } label: {
                Text("Go to HushhTech")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(HVTheme.surfaceAlt))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
            }
            .foregroundStyle(HVTheme.botText)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(HVTheme.bg.opacity(0.95))
    }
}

// ======================================================
// MARK: - MESSAGE ROW
// ======================================================

// Renders a single chat message (user vs assistant styles).
struct MessageRow: View {
    let message: Message
    let isLastAssistant: Bool
    let hideControls: Bool
    let isSpeaking: Bool
    let isLoadingTTS: Bool
    var onCopy: (() -> Void)?
    var onSpeakToggle: (() -> Void)?
    var onReload: (() -> Void)?

    private var isUser: Bool { message.role == .user }

    var body: some View { isUser ? AnyView(userRow) : AnyView(assistantRow) }

    private var userRow: some View {
        // Right-aligned bubble for the user.
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)

                Text(message.text)
                    .font(.body)
                    .foregroundStyle(HVTheme.userText)
                    .multilineTextAlignment(.trailing)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: HVTheme.corner).fill(HVTheme.userBubble))
                    .overlay(RoundedRectangle(cornerRadius: HVTheme.corner).stroke(HVTheme.stroke))
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
                    .animation(.easeOut(duration: 0.18), value: message.id)

                Button(action: { onCopy?() }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(6)
                        .background(Circle().fill(HVTheme.surfaceAlt))
                }
                .buttonStyle(.plain)
                .foregroundStyle(HVTheme.isDark ? Color.white.opacity(0.9) : HVTheme.accent)
            }
            .padding(.horizontal)
        }
    }

    private var assistantRow: some View {
        // Left-aligned bubble for the assistant + action buttons.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    StreamingMarkdownText(fullText: message.text, animate: isLastAssistant, charDelay: 0.01)
                        .font(.body)
                        .foregroundStyle(HVTheme.botText)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: HVTheme.corner).fill(HVTheme.surface))
                        .overlay(RoundedRectangle(cornerRadius: HVTheme.corner).stroke(HVTheme.stroke))
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                removal: .opacity))
                        .animation(.easeOut(duration: 0.18), value: message.id)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal)

            if !hideControls {
                HStack(spacing: 12) {
                    Button(action: { onCopy?() }) {
                        Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HVTheme.isDark ? Color.white.opacity(0.9) : HVTheme.accent)

                    Button(action: { onSpeakToggle?() }) {
                        if isLoadingTTS {
                            ProgressView().scaleEffect(0.9)
                        } else if isSpeaking {
                            Image(systemName: "stop.fill").font(.system(size: 15, weight: .semibold))
                        } else {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        isSpeaking ? HVTheme.accent :
                            (HVTheme.isDark ? Color.white.opacity(0.9) : HVTheme.botText)
                    )

                    Button(action: { onReload?() }) {
                        Label("Reload", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isLastAssistant ? HVTheme.accent : HVTheme.botText.opacity(0.7))

                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
                .opacity(0.9)
            }
        }
    }
}

// ======================================================
// MARK: - COMPOSER
// ======================================================

// Input field and send button at the bottom of the chat.
struct ComposerView: View {
    @Binding var text: String
    var isSending: Bool
    var disabled: Bool
    var onSend: () -> Void

    private let fieldHeight: CGFloat = 36
    private var iconSize: CGFloat { 20 }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(HVTheme.surfaceAlt)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)

                HStack {
                    TextField("Ask HushhVoice…", text: $text, onCommit: { if !disabled { onSend() } })
                        .textInputAutocapitalization(.sentences)
                        .disableAutocorrection(false)
                        .foregroundColor(HVTheme.botText)
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

// Simple animated dots to show "assistant is typing".
struct TypingIndicatorView: View {
    @State private var scale: CGFloat = 0.2

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(HVTheme.botText.opacity(0.35)).frame(width: 7, height: 7)
                .scaleEffect(scale)
                .animation(.easeInOut(duration: 0.9).repeatForever().delay(0.00), value: scale)
            Circle().fill(HVTheme.botText.opacity(0.55)).frame(width: 7, height: 7)
                .scaleEffect(scale)
                .animation(.easeInOut(duration: 0.9).repeatForever().delay(0.15), value: scale)
            Circle().fill(HVTheme.botText).frame(width: 7, height: 7)
                .scaleEffect(scale)
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
// MARK: - SIDEBAR
// ======================================================

// Sidebar listing chats with rename/delete actions.
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
                Text("Chats").font(.headline).foregroundColor(HVTheme.botText)
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
                                    .foregroundStyle(isActive ? HVTheme.accent : HVTheme.botText.opacity(0.7))
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    if renamingChatID == chat.id {
                                        TextField("Title", text: $renameText, onCommit: { commitInlineRename(chat.id) })
                                            .textFieldStyle(.roundedBorder)
                                            .foregroundStyle(HVTheme.botText)
                                    } else {
                                        Text(chat.title.isEmpty ? "Untitled" : chat.title)
                                            .font(.subheadline.weight(isActive ? .semibold : .regular))
                                            .foregroundStyle(HVTheme.botText)
                                            .lineLimit(2)
                                    }
                                    Text(chat.updatedAt, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(HVTheme.botText.opacity(0.5))
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isActive ? (HVTheme.isDark ? Color.white.opacity(0.08) : Color.white) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isActive ? HVTheme.accent.opacity(0.5) : HVTheme.stroke,
                                            lineWidth: isActive ? 1.5 : 1)
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
                            Button(role: .destructive) { store.deleteChat(chat.id) } label: {
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
                    Image(systemName: "gearshape.fill").font(.system(size: 16, weight: .semibold))
                    Text("Settings").font(.subheadline)
                }
                .foregroundStyle(HVTheme.botText)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(HVTheme.surfaceAlt)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
                )
                .padding([.horizontal, .bottom], 10)
            }
            .tint(HVTheme.accent)
        }
        .frame(width: HVTheme.sidebarWidth)
        .background(HVTheme.bg)
        .shadow(color: HVTheme.isDark ? .black.opacity(0.5) : .black.opacity(0.12),
                radius: HVTheme.isDark ? 14 : 6, x: 0, y: 0)
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
        // Save inline rename edits.
        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameChat(chatID, to: newTitle)
        renamingChatID = nil
        renameText = ""
    }
}

fileprivate extension View {
    // Helper to show the iOS 17 rename alert when available.
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
        // Use the native iOS 17 alert with a text field.
        if #available(iOS 17.0, *) {
            content.alert("Rename Chat", isPresented: $show) {
                TextField("Title", text: $title)
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onSave() }
            } message: { Text("Enter a new title.") }
        } else {
            content
        }
    }
}

// ======================================================
// MARK: - ONBOARDING / HOW-TO VIEW
// ======================================================

// Static "how to use" guide shown from settings.
struct OnboardingView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Welcome to HushhVoice").font(.system(size: 28, weight: .bold))
                        Text("Your private, consent-first AI copilot.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Group {
                        Text("What you can do").font(.headline)
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Ask questions in natural language.", systemImage: "text.bubble")
                            Label("Summarize or draft replies to your email.", systemImage: "envelope.badge")
                            Label("Check your schedule or plan events.", systemImage: "calendar")
                            Label("Use it like a smart, trustworthy assistant for your day.", systemImage: "brain.head.profile")
                        }
                        .font(.subheadline)
                    }

                    Group {
                        Text("Using HushhVoice with Siri").font(.headline)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("How it currently works:").font(.subheadline)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("1. Say: “Hey Siri, ask HushhVoice…” and pause.")
                                Text("2. Siri will respond: “What is the Question”")
                                Text("3. Then say your request, like:")
                                Text("   • “Check my email.”")
                                Text("   • “What meetings do I have today?”")
                                Text("   • “Draft a reply to my last email.”")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }

                    Group {
                        Text("Email & Calendar").font(.headline)
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Connect Google to let HushhVoice read and summarize your Gmail inbox.", systemImage: "envelope.open")
                            Label("Ask natural questions like “Anything urgent from today?”", systemImage: "exclamationmark.circle")
                            Label("Let it check your Google Calendar or help schedule meetings.", systemImage: "calendar.badge.clock")
                        }
                        .font(.subheadline)
                    }

                    Group {
                        Text("Privacy & Consent").font(.headline)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("HushhVoice uses your Google token only to talk to Gmail and Calendar on your behalf.")
                            Text("You stay in control: you can disconnect at any time from Settings.")
                            Text("Your data. Your business.")
                        }
                        .font(.subheadline)
                    }

                    Spacer(minLength: 8)
                }
                .padding()
            }
            .navigationTitle("How to use HushhVoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

// ======================================================
// MARK: - SETTINGS VIEW
// ======================================================

// Settings screen: theme, integrations, account, help.
struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var isDarkMode: Bool
    @ObservedObject var google: GoogleSignInManager
    @ObservedObject var store: ChatStore
    @Binding var isGuest: Bool

    @AppStorage("hushh_apple_user_id") private var appleUserID: String = ""
    @State private var showHelpSheet: Bool = false

    var onSignOutAll: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Toggle(isOn: $isDarkMode) { Text("Dark Mode") }
                }

                Section("Integrations") {
                    HStack {
                        Text("Google")
                        Spacer()
                        Text(google.hasConnectedGoogle ? "Connected" : "Not Connected")
                            .foregroundStyle(google.hasConnectedGoogle ? .green : .secondary)
                            .font(.footnote)
                    }

                    if google.hasConnectedGoogle {
                        Button { google.signIn() } label: {
                            HStack {
                                Image(systemName: "envelope.circle.fill")
                                Text("Reconnect Google")
                            }
                        }

                        Button(role: .destructive) {
                            Task {
                                await google.disconnect()
                                if appleUserID.isEmpty {
                                    isGuest = true
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                Text("Disconnect Google")
                            }
                        }
                    } else {
                        Button { google.signIn() } label: {
                            HStack {
                                Image(systemName: "envelope.circle.fill")
                                Text("Sign in with Google")
                            }
                        }
                    }
                }

                if isGuest {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sign in to unlock integrations and sync")
                                .font(.headline)
                            Text("Connect Google or Apple to sync data and enable Gmail/Calendar features.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Accounts") {
                    HStack {
                        Text(appleUserID.isEmpty ? "Not Linked" : "Linked")
                            .foregroundColor(appleUserID.isEmpty ? .secondary : .green)
                            .font(.footnote)

                    }

                    // ✅ IMPORTANT: Do NOT wrap this in any SwiftUI Button.
                    if appleUserID.isEmpty {
                        SupabaseSignInWithAppleButton()
                    } else {
                        Button(role: .destructive) {
                            AppleSupabaseAuth.shared.signOut()
                            appleUserID = ""
                            if !google.hasConnectedGoogle {
                                isGuest = true
                            }
                        } label: {
                            Text("Unlink Apple ID")
                        }
                    }

                    if google.hasConnectedGoogle || !appleUserID.isEmpty {
                        Button(role: .destructive) {
                            onSignOutAll()
                            dismiss()
                        } label: {
                            Text("Sign out of HushhVoice")
                        }
                    }

                    NavigationLink {
                        DeleteAccountView(store: store, google: google, onDeleted: {
                            isGuest = true
                            dismiss()
                        })
                    } label: {
                        Text("Delete Account")
                    }
                }
                Section("Help") {
                    Button { showHelpSheet = true } label: {
                        HStack {
                            Image(systemName: "questionmark.circle")
                            Text("How to use HushhVoice")
                        }
                    }
                }

                Section("Coming Soon / Planned Features") {
                    Label("iCloud sync for chats", systemImage: "icloud")
                    Label("Offline voice mode", systemImage: "waveform")
                    Label("Expanded integrations (Drive, Slack)", systemImage: "bolt.horizontal")
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hushh.ai").font(.headline)
                        Text("A private, consent-first AI copilot for your data, email, and calendar.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showHelpSheet) { OnboardingView() }
        }
    }
}

/// ======================================================
// MARK: - AUTH GATE (REPLACE THIS WHOLE VIEW)
// ======================================================

// Landing gate shown before user signs in or chooses guest mode.
struct AuthGateView: View {
    @ObservedObject private var google = GoogleSignInManager.shared
    @AppStorage("hushh_guest_mode") private var isGuest: Bool = false
    @State private var breathe = false
    @State private var appeared = false

    private var tagline: String {
        "Your data. Your intelligence. In voice mode."
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    HVTheme.surfaceAlt.opacity(0.9),
                                    HVTheme.surfaceAlt.opacity(0.6)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 136, height: 136)
                        .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                        .background(
                            RadialGradient(
                                colors: [HVTheme.accent.opacity(0.25), .clear],
                                center: .center,
                                startRadius: 12,
                                endRadius: 120
                            )
                        )

                    Image("hushh_quiet_logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 6)
                }
                .scaleEffect(breathe ? 1.02 : 0.98)
                .opacity(breathe ? 1.0 : 0.85)
                .onAppear {
                    withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                        breathe = true
                    }
                }

                VStack(spacing: 10) {
                    Text("HushhVoice")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(tagline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 26)
                }
            }
            .padding(.bottom, 8)

            VStack(spacing: 14) {
                Button {
                    isGuest = false
                    google.signIn()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "g.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                        Text(google.isSignedIn ? "Continue with Google" : "Continue with Google")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .opacity(0.7)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color.white))
                }
                .foregroundColor(.black)
                .buttonStyle(AuthGatePressableStyle())

                Text("— or —")
                    .foregroundStyle(.white.opacity(0.5))
                    .font(.footnote.weight(.semibold))

                SupabaseSignInWithAppleButton()
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .buttonStyle(AuthGatePressableStyle())

                Button {
                    isGuest = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Continue as Guest")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .opacity(0.7)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                }
                .foregroundColor(.white)
                .buttonStyle(AuthGatePressableStyle())
            }
            .padding(.horizontal, 28)

            Spacer()

            VStack(spacing: 6) {
                Text("Used only to connect your data securely to your personal AI.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                Text("Nothing is shared without your consent.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)

            Spacer(minLength: 26)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 18)
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) {
                appeared = true
            }
        }
        .background(AuthGateBackground().ignoresSafeArea())
    }
}

private struct AuthGatePressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}

private struct AuthGateBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(hue: 0.58, saturation: 0.4, brightness: 0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [HVTheme.accent.opacity(0.15), .clear],
                center: .top,
                startRadius: 40,
                endRadius: 320
            )
            RadialGradient(
                colors: [Color.white.opacity(0.08), .clear],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 280
            )
        }
    }
}

// ======================================================
// MARK: - DELETE ACCOUNT
// ======================================================

// Confirmation flow that clears local data and disconnects accounts.
struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ChatStore
    @ObservedObject var google: GoogleSignInManager

    @AppStorage("hushh_apple_user_id") private var appleUserID: String = ""
    @AppStorage("hushh_guest_mode") private var isGuest: Bool = false
    @AppStorage("hushh_kai_user_id") private var kaiUserID: String = ""

    @State private var confirmText: String = ""
    @State private var isDeleting: Bool = false
    @State private var errorText: String?
    @State private var success: Bool = false

    var onDeleted: () -> Void

    private var deleteEnabled: Bool {
        confirmText == "DELETE" && !isDeleting
    }

    var body: some View {
        Form {
            Section {
                Text("Deleting your account removes all personal data, onboarding answers, chat history, and disconnects integrations. This cannot be undone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } header: { Text("Warning") }

            Section {
                TextField("Type DELETE to confirm", text: $confirmText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if success {
                    Text("Your account has been deleted.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                }
            } footer: {
                Text("You must type DELETE to enable the button.")
            }

            Section {
                Button(role: .destructive) {
                    Task { await deleteAccount() }
                } label: {
                    if isDeleting {
                        ProgressView().tint(.red)
                    } else {
                        Text("Delete Account")
                    }
                }
                .disabled(!deleteEnabled)
            }
        }
        .navigationTitle("Delete Account")
    }

    @MainActor
    private func deleteAccount() async {
        // Disconnect integrations and clear local state.
        guard deleteEnabled else { return }
        isDeleting = true
        errorText = nil

        do {
            let token = await google.ensureValidAccessToken()
            try await HushhAPI.deleteAccount(
                googleToken: token,
                appleUserID: appleUserID,
                kaiUserID: kaiUserID
            )
        } catch {
            errorText = error.localizedDescription
            isDeleting = false
            return
        }

        clearLocalUserState()

        if google.hasConnectedGoogle {
            await google.disconnect()
        }
        if !appleUserID.isEmpty {
            AppleSupabaseAuth.shared.signOut()
            appleUserID = ""
        }

        store.clearAllChatsAndReset()
        isGuest = true
        success = true
        onDeleted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { dismiss() }

        isDeleting = false
    }

    @MainActor
    private func clearLocalUserState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "hv_profile_completed")
        defaults.removeObject(forKey: "hv_hushhtech_intro_completed")
        defaults.removeObject(forKey: "hv_has_completed_investor_onboarding")
        defaults.removeObject(forKey: "hushh_has_seen_intro")
        defaults.removeObject(forKey: "hushh_kai_last_prompt")

        if !kaiUserID.isEmpty {
            defaults.removeObject(forKey: "hushh_kai_onboarding_state_v1_\(kaiUserID)")
            defaults.removeObject(forKey: "hushh_kai_onboarding_sync_pending_\(kaiUserID)")
        }
        if !appleUserID.isEmpty {
            defaults.removeObject(forKey: "hushh_kai_onboarding_state_v1_\(appleUserID)")
            defaults.removeObject(forKey: "hushh_kai_onboarding_sync_pending_\(appleUserID)")
        }

        kaiUserID = ""
    }
}

// ======================================================
// MARK: - CHAT VIEW (root)
// ======================================================

// Main app screen that wires together store, auth, and UI.
struct ChatView: View {
    @StateObject private var store = ChatStore()
    @ObservedObject var auth = GoogleSignInManager.shared
    @ObservedObject var speech = SpeechManager.shared

    @AppStorage("hv_has_completed_investor_onboarding") private var hvDone: Bool = false
    @State private var showInvestorOnboarding: Bool = false

    @AppStorage("hushh_apple_user_id") private var appleUserID: String = ""
    @AppStorage("hushh_kai_user_id") private var kaiUserID: String = ""
    @AppStorage("hushh_is_dark") private var isDarkMode: Bool = true
    @AppStorage("hushh_has_seen_intro") private var hasSeenIntro: Bool = false
    @AppStorage("hushh_guest_mode") private var isGuest: Bool = false

    @State private var input: String = ""
    @State private var sending = false
    @State private var showTyping = false
    @State private var showSidebar: Bool = false
    @State private var showingSettings = false
    @State private var showingIntro = false
    @State private var animatingAssistantID: UUID?
    @State private var showGoogleGate: Bool = false
    @State private var gatedPrompt: String = ""

    private let emptyPhrases = [
        "Hi, I'm HushhVoice. How may I help you?",
        "Ready when you are — ask me anything.",
        "Your data. Your business. How can I assist?",
        "Let’s build something useful. What’s on your mind?",
        "Ask away. I’ll keep it crisp."
    ]
    @State private var currentEmptyPhrase: String = ""

    private var isAuthenticated: Bool {
        isGuest || auth.isSignedIn || !appleUserID.isEmpty
    }

    var body: some View {
        Group {
            if !isAuthenticated {
                AuthGateView()
            } else {
                mainChat
                    .onAppear {
                        if !hvDone {
                            showInvestorOnboarding = true
                        }
                    }
                    .sheet(isPresented: $showInvestorOnboarding) {
                        Onboarding()
                    }
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .onAppear {
            HVTheme.setMode(isDark: isDarkMode)
            auth.loadFromDisk()
            if auth.isSignedIn || !appleUserID.isEmpty {
                isGuest = false
            }
        }
        .onChange(of: isDarkMode) { _, newValue in
            HVTheme.setMode(isDark: newValue)
        }
    }

    private var mainChat: some View {
        // Core chat layout: header, messages, composer, sidebar.
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                HeaderBar {
                    withAnimation(.easeInOut(duration: 0.22)) { showSidebar.toggle() }
                } onGoToHushhTech: {
                    showInvestorOnboarding = true
                }

                ScrollViewReader { proxy in
                    ZStack {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(store.activeMessages) { msg in
                                    let isLast = isLastAssistant(msg)
                                    let hideControls = (msg.role == .assistant && msg.id == animatingAssistantID)

                                    MessageRow(
                                        message: msg,
                                        isLastAssistant: isLast,
                                        hideControls: hideControls,
                                        isSpeaking: speech.currentMessageID == msg.id && speech.isPlaying,
                                        isLoadingTTS: speech.currentMessageID == msg.id && speech.isLoading,
                                        onCopy: { UIPasteboard.general.string = msg.text },
                                        onSpeakToggle: { handleSpeakToggle(for: msg) },
                                        onReload: {
                                            Task {
                                                let token = await auth.ensureValidAccessToken()
                                                await store.regenerate(at: msg.id, googleToken: token)
                                            }
                                        }
                                    )
                                    .id(msg.id)
                                }

                                if showTyping { TypingIndicatorView().id("typing") }
                            }
                            .padding(.vertical, 12)
                        }

                        if store.activeMessages.isEmpty {
                            VStack(spacing: 10) {
                                Text(currentEmptyPhrase)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(HVTheme.botText.opacity(0.9))

                                Rectangle().fill(HVTheme.botText.opacity(0.06)).frame(width: 220, height: 8).cornerRadius(4)
                                Rectangle().fill(HVTheme.botText.opacity(0.06)).frame(width: 260, height: 8).cornerRadius(4)
                                Rectangle().fill(HVTheme.botText.opacity(0.06)).frame(width: 180, height: 8).cornerRadius(4)
                            }
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .transition(.opacity.combined(with: .scale))
                        }
                    }
                    .onChange(of: store.activeMessages.last?.id) { _, id in
                        if let id {
                            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .bottom) }

                            if let last = store.activeMessages.last, last.role == .assistant {
                                animatingAssistantID = id
                                let textLength = last.text.count
                                let totalTime = Double(textLength) * 0.01 + 0.25
                                Task {
                                    try? await Task.sleep(nanoseconds: UInt64(totalTime * 1_000_000_000))
                                    await MainActor.run {
                                        if animatingAssistantID == id { animatingAssistantID = nil }
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: showTyping) { _, typing in
                        if typing {
                            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("typing", anchor: .bottom) }
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
                Color.black.opacity(HVTheme.scrimOpacity)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.22)) { showSidebar = false }
                    }

                ChatSidebar(store: store, showingSettings: $showingSettings, isCollapsed: $showSidebar)
                    .frame(width: HVTheme.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .tint(HVTheme.accent)
        .sheet(isPresented: $showingSettings) {
            SettingsView(isDarkMode: $isDarkMode, google: auth, store: store, isGuest: $isGuest, onSignOutAll: handleSignOut)
        }
        .sheet(isPresented: $showingIntro) {
            OnboardingView()
        }
        .alert("Connect Google to Continue", isPresented: $showGoogleGate) {
            Button("Go to Settings") { showingSettings = true }
            Button("Sign in with Google") { auth.signIn() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("To answer Gmail or Calendar questions, connect Google in Settings.")
        }
        .onAppear {
            randomizeEmptyPhrase()
            if !hasSeenIntro && hvDone {
                hasSeenIntro = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showingIntro = true }
            }
        }
        .onChange(of: store.activeChatID) { _ in randomizeEmptyPhrase() }
    }


    private func isLastAssistant(_ msg: Message) -> Bool {
        // Used to decide which assistant message gets typing animation.
        guard msg.role == .assistant else { return false }
        guard let last = store.activeMessages.last(where: { $0.role == .assistant }) else { return false }
        return last.id == msg.id
    }

    private func randomizeEmptyPhrase() {
        // Pick a random empty-state prompt.
        currentEmptyPhrase = emptyPhrases.randomElement() ?? emptyPhrases[0]
    }

    private func send() async {
        // Send message, show typing state, and gate Google features if needed.
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        let needsGoogle = requiresGoogleIntegration(for: q)
        let token = await auth.ensureValidAccessToken()

        if needsGoogle && token == nil {
            gatedPrompt = q
            showGoogleGate = true
            return
        }

        sending = true
        input = ""
        showTyping = true
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()

        await store.send(q, googleToken: token)

        showTyping = false
        sending = false
    }

    private func handleSpeakToggle(for msg: Message) {
        // Toggle TTS playback for the selected assistant message.
        if speech.currentMessageID == msg.id && (speech.isPlaying || speech.isLoading) {
            speech.stop()
        } else {
            speech.speak(msg.text, messageID: msg.id)
        }
    }

    private func handleSignOut() {
        // Sign out of all services and clear local state.
        AppleSupabaseAuth.shared.signOut()
        appleUserID = ""
        auth.signOut()
        isGuest = true
        speech.stop()
        store.clearMessagesInActiveChat()
    }

    private func requiresGoogleIntegration(for text: String) -> Bool {
        // Simple keyword check to decide if Google token is required.
        let lower = text.lowercased()
        let keywords = ["gmail", "email", "inbox", "calendar", "event", "meeting", "schedule"]
        return keywords.contains { lower.contains($0) }
    }
}

#Preview { ChatView() }

// ======================================================
// MARK: - SIRI SHORTCUTS INLINE
// ======================================================

// Siri Shortcut intent that calls the same backend.
struct AskHushhVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask HushhVoice"
    static var description = IntentDescription("Ask HushhVoice anything")

    @Parameter(title: "Question")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask HushhVoice: \(\.$question)")
    }

    static var openAppWhenRun: Bool = false

    static var suggestedInvocationPhrase: String {
        "Ask HushhVoice to check my email"
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Run the ask endpoint and speak a short response.
        let token = await GoogleSignInManager.shared.ensureValidAccessToken()
        print("🔵 AskHushhVoiceIntent.perform: token is \(token == nil ? "nil" : "non-nil")")

        let data = try await HushhAPI.ask(prompt: question, googleToken: token)

        let spoken =
            (data.speech?.removingPercentEncoding ?? data.speech)
            ?? (data.display?.removingPercentEncoding ?? data.display)
            ?? "I couldn't get a response."

        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = trimmed.count > 280 ? String(trimmed.prefix(280)) + "…" : trimmed

        return .result(dialog: IntentDialog(stringLiteral: short))
    }
}

struct HushhVoiceAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHushhVoiceIntent(),
            phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) anything"],
            shortTitle: "Ask HushhVoice",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
    }
}
