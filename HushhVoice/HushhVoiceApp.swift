import SwiftUI

@main
struct HushhVoiceApp: App {
    private let useNewRealtimeChatUI = true

    var body: some Scene {
        WindowGroup {
            Group {
                // NOTE: `RealtimeChatView` lives in `HushhVoice/Realtime/...` but those files are not
                // currently referenced by the Xcode project, so the symbol may not exist at compile time.
                // To enable the new Realtime UI, first add the Realtime folder/files to the app target,
                // then define the Swift compilation condition `HUSHHVOICE_NEW_REALTIME_UI`.
                #if HUSHHVOICE_NEW_REALTIME_UI
                if useNewRealtimeChatUI {
                    RealtimeChatView()
                } else {
                    ChatView()
                }
                #else
                ChatView()
                #endif
            }
            .onAppear {
                AppleSupabaseAuth.shared.restoreSessionIfPossible()
                // Make realtime logs available without needing Scheme env var edits.
                // If you still want Scheme control, set `HV_REALTIME_DEBUG=0/1` explicitly.
                #if DEBUG
                if UserDefaults.standard.object(forKey: "hv_realtime_debug") == nil {
                    UserDefaults.standard.set(true, forKey: "hv_realtime_debug")
                }
                #endif
                #if HUSHHVOICE_NEW_REALTIME_UI
                print("[HushhVoiceApp] UI=\(useNewRealtimeChatUI ? "RealtimeChatView" : "ChatView") useNewRealtimeChatUI=\(useNewRealtimeChatUI)")
                #else
                print("[HushhVoiceApp] UI=ChatView (HUSHHVOICE_NEW_REALTIME_UI not defined)")
                #endif
            }
                .preferredColorScheme(.dark)
        }
    }
}
