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
    static func p(_ msg: String) {
//        print("🍏🔐 [AppleAuth] \(msg)")
    }
}

// ======================================================
// MARK: - Supabase Apple Auth Manager
// ======================================================

@MainActor
final class AppleSupabaseAuth: ObservableObject {
    static let shared = AppleSupabaseAuth()

    @Published var isSignedIn: Bool = false
    @Published var supabaseUserID: String? = nil

    private let supabaseURL = URL(string: "https://cvfhnyvpomberwcjddcp.supabase.co")!
    private let supabaseAnonKey =
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN2ZmhueXZwb21iZXJ3Y2pkZGNwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU1MjIxMjIsImV4cCI6MjA4MTA5ODEyMn0.LwVDjPbtgA4iETh3XZJlYlQ2wLYfuJ_AnaIk0MFgDAA"


    private lazy var client = SupabaseClient(
        supabaseURL: supabaseURL,
        supabaseKey: supabaseAnonKey
    )

    // Your app already checks this key for auth gate
    private let appleUserDefaultsKey = "hushh_apple_user_id"

    /// Call this at launch (you already do in HushhVoiceApp) to restore stored session.
    func restoreSessionIfPossible() {
        HVAuthLog.p("restoreSessionIfPossible() called")
        Task {
            do {
                let session = try await client.auth.session
                let uid = session.user.id.uuidString

                self.isSignedIn = true
                self.supabaseUserID = uid
                UserDefaults.standard.set(uid, forKey: self.appleUserDefaultsKey)

                HVAuthLog.p("✅ Restored Supabase session. user_id=\(uid)")
            } catch {
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
            let credentials = OpenIDConnectCredentials(
                provider: .apple,
                idToken: idToken,
                nonce: rawNonce
            )

            HVAuthLog.p("Calling supabase.auth.signInWithIdToken(...)")
            let session = try await client.auth.signInWithIdToken(credentials: credentials)

            let uid = session.user.id.uuidString
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
    @State private var currentNonce: String = ""
    @AppStorage("hushh_apple_user_id") private var appleUserID: String = ""

    var body: some View {
        SignInWithAppleButton(.continue) { request in
            let nonce = randomNonceString()
            currentNonce = nonce

            request.requestedScopes = [.fullName, .email]
            request.nonce = sha256(nonce)

        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let tokenData = credential.identityToken,
                      let idToken = String(data: tokenData, encoding: .utf8),
                      !currentNonce.isEmpty
                else {
                    return
                }

                let nonce = currentNonce
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
        .signInWithAppleButtonStyle(.black)
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}


// ======================================================
// MARK: - Nonce helpers
// ======================================================

private func sha256(_ input: String) -> String {
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
