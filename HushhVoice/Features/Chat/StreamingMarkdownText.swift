import SwiftUI

// Displays text with a simple streaming/typing effect and basic **bold** parsing.
struct StreamingMarkdownText: View {
    let fullText: String
    let animate: Bool
    let charDelay: TimeInterval

    @State private var visibleText: String = ""
    @State private var started = false

    var body: some View {
        // Render whatever text is currently visible.
        renderedText(from: visibleText)
            .textSelection(.enabled)
            .onAppear {
                guard !started else { return }
                started = true
                if animate { startTyping() } else { visibleText = fullText }
            }
    }

    private func startTyping() {
        // Reveal one character at a time to simulate typing.
        visibleText = ""
        Task {
            for ch in fullText {
                try? await Task.sleep(nanoseconds: UInt64(charDelay * 1_000_000_000))
                visibleText.append(ch)
                if Task.isCancelled { break }
            }
        }
    }

    private func renderedText(from text: String) -> Text {
        // Naive Markdown: only handles **bold** segments.
        guard text.contains("**") else { return Text(text) }

        var result = Text("")
        var remaining = text[...]
        var isBold = false

        while let range = remaining.range(of: "**") {
            let before = remaining[..<range.lowerBound]
            if !before.isEmpty {
                let segment = Text(String(before))
                result = result + (isBold ? segment.bold() : segment)
            }
            isBold.toggle()
            remaining = remaining[range.upperBound...]
        }

        if !remaining.isEmpty {
            let segment = Text(String(remaining))
            result = result + (isBold ? segment.bold() : segment)
        }
        return result
    }
}
