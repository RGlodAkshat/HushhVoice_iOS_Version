//
//  SignIn.swift
//  HushhVoice
//
//  Apple Sign-In -> Supabase Auth (OIDC id_token + nonce)
//  Debug logs + tiny UI status label.
//

import SwiftUI
import AuthenticationServices
import CryptoKit
import Supabase

// ======================================================
// MARK: - Debug Logger
// ======================================================

enum HVAuthLog {
    // Simple debug print helper. Commented out to avoid noisy logs.
    static func p(_ msg: String) {
//        print("🍏🔐 [AppleAuth] \(msg)")
    }
}

// ======================================================
// MARK: - Supabase Apple Auth Manager
// ======================================================

// MainActor ensures published UI state updates happen on the main thread.
@MainActor
final class AppleSupabaseAuth: ObservableObject {
    // Singleton shared instance for app-wide access.
    static let shared = AppleSupabaseAuth()

    // Published so UI can react to auth state changes.
    @Published var isSignedIn: Bool = false
    @Published var supabaseUserID: String? = nil

    // Supabase project URL and anon key for client initialization.
    private let supabaseURL = URL(string: "https://cvfhnyvpomberwcjddcp.supabase.co")!
    private let supabaseAnonKey =
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN2ZmhueXZwb21iZXJ3Y2pkZGNwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU1MjIxMjIsImV4cCI6MjA4MTA5ODEyMn0.LwVDjPbtgA4iETh3XZJlYlQ2wLYfuJ_AnaIk0MFgDAA"


    // Supabase client configured with your project credentials.
    private lazy var client = SupabaseClient(
        supabaseURL: supabaseURL,
        supabaseKey: supabaseAnonKey
    )

    // Your app already checks this key for auth gate
    private let appleUserDefaultsKey = "hushh_apple_user_id"

    /// Call this at launch (you already do in HushhVoiceApp) to restore stored session.
    func restoreSessionIfPossible() {
        HVAuthLog.p("restoreSessionIfPossible() called")
        // Use a Task because `client.auth.session` is async.
        Task {
            do {
                let session = try await client.auth.session
                let uid = session.user.id.uuidString

                // Save successful session in memory + local storage.
                self.isSignedIn = true
                self.supabaseUserID = uid
                UserDefaults.standard.set(uid, forKey: self.appleUserDefaultsKey)

                HVAuthLog.p("✅ Restored Supabase session. user_id=\(uid)")
            } catch {
                // No existing session is a normal case.
                self.isSignedIn = false
                self.supabaseUserID = nil
                HVAuthLog.p("ℹ️ No session to restore (normal). error=\(error.localizedDescription)")
            }
        }
    }

    /// Completes login using Apple OIDC id_token + original raw nonce.
    func finishAppleSignIn(idToken: String, rawNonce: String) async {
        HVAuthLog.p("finishAppleSignIn() called")
        HVAuthLog.p("idToken prefix: \(idToken.prefix(20))...")
        HVAuthLog.p("rawNonce: \(rawNonce)")

        do {
            // Build OIDC credentials required by Supabase.
            let credentials = OpenIDConnectCredentials(
                provider: .apple,
                idToken: idToken,
                nonce: rawNonce
            )

            HVAuthLog.p("Calling supabase.auth.signInWithIdToken(...)")
            let session = try await client.auth.signInWithIdToken(credentials: credentials)

            let uid = session.user.id.uuidString
            // Update app state and persist user id.
            self.isSignedIn = true
            self.supabaseUserID = uid
            UserDefaults.standard.set(uid, forKey: self.appleUserDefaultsKey)

            HVAuthLog.p("✅ Supabase sign-in success. user_id=\(uid)")
        } catch {
            self.isSignedIn = false
            self.supabaseUserID = nil
            HVAuthLog.p("❌ Supabase sign-in failed: \(error.localizedDescription)")
        }
    }

    func signOut() {
        HVAuthLog.p("signOut() called")
        Task {
            do { try await client.auth.signOut() } catch { }
            // Clear local session cache and update UI state.
            UserDefaults.standard.removeObject(forKey: appleUserDefaultsKey)
            isSignedIn = false
            supabaseUserID = nil
            HVAuthLog.p("✅ Signed out + cleared hushh_apple_user_id")
        }
    }
}
// ======================================================
// MARK: - Apple Button (Clean)
// ======================================================

struct SupabaseSignInWithAppleButton: View {
    // Nonce helps prevent replay attacks in Sign in with Apple.
    @State private var currentNonce: String = ""
    @AppStorage("hushh_apple_user_id") private var appleUserID: String = ""

    var body: some View {
        // Standard Apple sign-in button with request + completion handlers.
        SignInWithAppleButton(.continue) { request in
            let nonce = randomNonceString()
            currentNonce = nonce

            // Ask for name + email on first sign-in.
            request.requestedScopes = [.fullName, .email]
            // Hash nonce before sending in the Apple request.
            request.nonce = sha256(nonce)

        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                // Extract identity token from Apple credential.
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let tokenData = credential.identityToken,
                      let idToken = String(data: tokenData, encoding: .utf8),
                      !currentNonce.isEmpty
                else {
                    return
                }

                let nonce = currentNonce
                // Finish auth with Supabase and store user id.
                Task { @MainActor in
                    await AppleSupabaseAuth.shared.finishAppleSignIn(
                        idToken: idToken,
                        rawNonce: nonce
                    )
                    if let uid = AppleSupabaseAuth.shared.supabaseUserID, !uid.isEmpty {
                        appleUserID = uid
                    }
                }

            case .failure:
                return
            }
        }
        // Match Apple's black button style.
        .signInWithAppleButtonStyle(.black)
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}


// ======================================================
// MARK: - Nonce helpers
// ======================================================

private func sha256(_ input: String) -> String {
    // Hash input into a hex string.
    let inputData = Data(input.utf8)
    let hashed = SHA256.hash(data: inputData)
    return hashed.map { String(format: "%02x", $0) }.joined()
}

private func randomNonceString(length: Int = 32) -> String {
    precondition(length > 0)
    let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

    var result = ""
    var remaining = length

    while remaining > 0 {
        // Generate random bytes and map them to the allowed charset.
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess { fatalError("SecRandomCopyBytes failed") }

        for b in bytes {
            if remaining == 0 { break }
            if b < charset.count {
                result.append(charset[Int(b)])
                remaining -= 1
            }
        }
    }
    return result
}
