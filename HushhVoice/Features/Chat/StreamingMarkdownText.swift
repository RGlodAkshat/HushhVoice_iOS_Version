import SwiftUI
import Foundation

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

enum MarkdownLinkDetector {
    static func longURLs(in text: String, minLength: Int = 60) -> [URL] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var seen = Set<URL>()
        var results: [URL] = []
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let url = match?.url else { return }
            let urlString = url.absoluteString
            guard urlString.count >= minLength else { return }
            if seen.insert(url).inserted {
                results.append(url)
            }
        }
        return results
    }
}

struct MarkdownTextBlock: View {
    let text: String
    let isStreaming: Bool
    let baseFont: Font
    let textColor: Color

    var body: some View {
        Group {
            if isStreaming {
                Text(text)
                    .transition(.opacity)
                    .animation(.linear(duration: 0.08), value: text)
            } else {
                if let attributed = try? AttributedString(markdown: text) {
                    Text(attributed)
                } else {
                    Text(text)
                }
            }
        }
        .font(baseFont)
        .foregroundStyle(textColor)
        .textSelection(.enabled)
    }
}
