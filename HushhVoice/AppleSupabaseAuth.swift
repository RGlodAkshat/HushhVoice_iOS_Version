////
////  AppleSupabaseAuth.swift
////  HushhVoice
////
////  Created by Akshat Kumar on 13/12/25.
////
//
//import AuthenticationServices
//import Supabase
//import UIKit
//
//@MainActor
//final class AppleSupabaseAuth: NSObject {
//    static let shared = AppleSupabaseAuth()
//
//    func signIn() {
//        let request = ASAuthorizationAppleIDProvider().createRequest()
//        request.requestedScopes = [.fullName, .email]
//
//        let controller = ASAuthorizationController(authorizationRequests: [request])
//        controller.delegate = self
//        controller.presentationContextProvider = self
//        controller.performRequests()
//    }
//}
//
//extension AppleSupabaseAuth: ASAuthorizationControllerDelegate {
//    func authorizationController(controller: ASAuthorizationController,
//                                 didCompleteWithAuthorization authorization: ASAuthorization) {
//        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
//              let tokenData = credential.identityToken,
//              let idToken = String(data: tokenData, encoding: .utf8) else {
//            print("❌ Missing Apple identityToken")
//            return
//        }
//
//        Task {
////            do {
////                let session = try await SupabaseManager.shared.client.auth.signInWithIdToken(
////                    credentials: .init(provider: .apple, idToken: idToken)
////                )
////                print("✅ Apple→Supabase login OK, user:", session.user.id.uuidString)
////            } catch {
////                print("❌ Apple→Supabase login failed:", error)
////            }
////        }
//    }
//
//    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
//        print("❌ Apple sign-in failed:", error)
//    }
//}
//
//extension AppleSupabaseAuth: ASAuthorizationControllerPresentationContextProviding {
//    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
//        UIApplication.shared.connectedScenes
//            .compactMap { $0 as? UIWindowScene }
//            .flatMap { $0.windows }
//            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
//    }
//}
