import Foundation
import AuthenticationServices
import SwiftUI

@MainActor
final class GoogleSignInManager: NSObject, ObservableObject {
    static let shared = GoogleSignInManager()

    @Published var isSignedIn: Bool = false
    @Published var accessToken: String? = nil

    // Replace with your iOS OAuth client details
    private let clientID = "1042954531759-s0cgfui9ss2o2kvpvfssu2k81gtjpop9.apps.googleusercontent.com"
    private let redirectURI = "com.googleusercontent.apps.1042954531759-s0cgfui9ss2o2kvpvfssu2k81gtjpop9:/oauthredirect"
    private let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events"
    ].joined(separator: " ")

    private var session: ASWebAuthenticationSession?

    // Restore token on launch if you persist it
    func loadFromDisk() {
        if let token = UserDefaults.standard.string(forKey: "google_access_token") {
            self.accessToken = token
            self.isSignedIn = true
        }
    }

    func signIn() {
        let state = UUID().uuidString
        // Implicit flow to fetch an access_token (short-lived)
        let url = URL(string:
          "https://accounts.google.com/o/oauth2/v2/auth?" +
          "response_type=token" +
          "&client_id=\(clientID)" +
          "&redirect_uri=\(redirectURI)" +
          "&scope=\(scopes.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" +
          "&state=\(state)"
        )!

        // Use callbackURLScheme equal to the URL scheme part (before ://)
        let scheme = "com.googleusercontent.apps.1042954531759-s0cgfui9ss2o2kvpvfssu2k81gtjpop9"
        session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] callbackURL, error in
            guard let self, error == nil, let callbackURL else {
                print("Google sign-in failed: \(error?.localizedDescription ?? "unknown")")
                return
            }
            // Fragment contains access_token
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
        // Modern anchor (iOS 15+)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}



