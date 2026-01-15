import Foundation
import SwiftUI
import AuthenticationServices
import CryptoKit
import UIKit
import Security

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
