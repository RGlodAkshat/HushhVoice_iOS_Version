import AppIntents

struct AskHushhVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask HushhVoice"
    static var description = IntentDescription(
        "Ask HushhVoice a question using your voice or Shortcuts."
    )

    static var parameterSummary: some ParameterSummary {
        Summary("Ask HushhVoice \(\.$question)")
    }

    @Parameter(
        title: "Question",
        requestValueDialog: IntentDialog("What do you want to ask HushhVoice?")
    )
    var question: String

    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        let token = UserDefaults.standard.string(forKey: "google_access_token")
        do {
            let data = try await HushhAPI.ask(prompt: question, googleToken: token)
            let text = (data.display?.removingPercentEncoding ?? data.display) ?? data.speech ?? "(no response)"
            return .result(value: text, dialog: IntentDialog(stringLiteral: text))
        } catch {
            let msg = "Sorry, I couldn’t get an answer: \(error.localizedDescription)"
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
    }
}

struct HushhVoiceShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .teal

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHushhVoiceIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "\(.applicationName) help"
            ],
            shortTitle: "Ask HushhVoice",
            systemImageName: "sparkles"
        )
    }
}


