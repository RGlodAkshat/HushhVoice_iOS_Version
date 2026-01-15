import AppIntents
import Foundation

// Siri Shortcut intent that calls the same backend.
struct AskHushhVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask HushhVoice"
    static var description = IntentDescription("Ask HushhVoice anything")

    @Parameter(title: "Question")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask HushhVoice: \(\.$question)")
    }

    static var openAppWhenRun: Bool = false

    static var suggestedInvocationPhrase: String {
        "Ask HushhVoice to check my email"
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Run the ask endpoint and speak a short response.
        let token = await GoogleSignInManager.shared.ensureValidAccessToken()
        print("🔵 AskHushhVoiceIntent.perform: token is \(token == nil ? "nil" : "non-nil")")

        let data = try await HushhAPI.ask(prompt: question, googleToken: token)

        let spoken =
            (data.speech?.removingPercentEncoding ?? data.speech)
            ?? (data.display?.removingPercentEncoding ?? data.display)
            ?? "I couldn't get a response."

        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = trimmed.count > 280 ? String(trimmed.prefix(280)) + "…" : trimmed

        return .result(dialog: IntentDialog(stringLiteral: short))
    }
}

struct HushhVoiceAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHushhVoiceIntent(),
            phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) anything"],
            shortTitle: "Ask HushhVoice",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
    }
}
