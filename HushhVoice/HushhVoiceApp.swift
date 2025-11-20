//
//  HushhVoiceApp.swift
//  HushhVoice
//
//  Entry point that boots the Chat UI.
//  Keep this file tiny so iteration stays fast.
//

import SwiftUI

@main
struct HushhVoiceApp: App {
    var body: some Scene {
        WindowGroup {
            ChatView() // Main experience
                .preferredColorScheme(.dark)
        }
    }
}
