// HushhVoiceApp.swift
// Entry point for the app. SwiftUI apps start here.

import SwiftUI

// @main tells Swift this is the app's starting type.
@main
struct HushhVoiceApp: App {
    // body describes the app's scenes (windows) and their root views.
    var body: some Scene {
        WindowGroup {
            // ChatView is the first screen shown in the main window.
            ChatView()
                .onAppear {
                    // Try to restore a previous login session when the app launches.
                    AppleSupabaseAuth.shared.restoreSessionIfPossible()
                }
                // Force a dark color scheme for the whole app.
                .preferredColorScheme(.dark)
        }
    }
}
