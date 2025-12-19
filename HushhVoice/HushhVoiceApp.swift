//HushhVoiceApp.swift

import SwiftUI

@main
struct HushhVoiceApp: App {
    var body: some Scene {
        WindowGroup {
            ChatView()
                .onAppear {
                    AppleSupabaseAuth.shared.restoreSessionIfPossible()
                }
                .preferredColorScheme(.dark)
        }
    }
}

