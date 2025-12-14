////
////  SupabaseManager.swift
////  HushhVoice
////
////  Created by Akshat Kumar on 13/12/25.
////
//
//import Foundation
//import Supabase
//
//final class SupabaseManager {
//    static let shared = SupabaseManager()
//    let client: SupabaseClient
//
//    private init() {
//        let urlString = Bundle.main.object(forInfoDictionaryKey: "SB_URL") as? String ?? ""
//        let anonKey = Bundle.main.object(forInfoDictionaryKey: "SB_ANON_KEY") as? String ?? ""
//
//        guard let url = URL(string: urlString), !anonKey.isEmpty else {
//            fatalError("Missing/invalid SB_URL or SB_ANON_KEY")
//        }
//
//        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
//    }
//}
