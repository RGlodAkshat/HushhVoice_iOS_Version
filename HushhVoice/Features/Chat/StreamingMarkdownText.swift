import SwiftUI
import Foundation
import UIKit

// Streaming markdown renderer with light throttling and code block support.
struct StreamingMarkdownText: View {
    let fullText: String
    let animate: Bool
    let charDelay: TimeInterval
    var baseFont: Font = .body
    var textColor: Color = HVTheme.botText

    @State private var visibleText: String = ""
    @State private var started = false

    var body: some View {
        MarkdownTextBlock(
            text: visibleText,
            isStreaming: animate,
            baseFont: baseFont,
            textColor: textColor
        )
        .onAppear {
            guard !started else { return }
            started = true
            if animate { startTyping() } else { visibleText = fullText }
        }
        .onChange(of: fullText) { _, newValue in
            if !animate {
                visibleText = newValue
            }
        }
    }

    private func startTyping() {
        visibleText = ""
        Task {
            for ch in fullText {
                try? await Task.sleep(nanoseconds: UInt64(charDelay * 1_000_000_000))
                visibleText.append(ch)
                if Task.isCancelled { break }
            }
        }
    }
}

struct MarkdownTextBlock: View {
    let text: String
    let isStreaming: Bool
    let baseFont: Font
    let textColor: Color

    @State private var renderedText: String = ""
    @State private var pendingText: String = ""
    @State private var throttleTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(markdownSegments(from: renderedText).indices, id: \.self) { idx in
                let segment = markdownSegments(from: renderedText)[idx]
                if segment.isCode {
                    CodeBlockView(code: segment.content)
                } else {
                    MarkdownAttributedText(
                        text: segment.content,
                        baseFont: baseFont,
                        textColor: textColor
                    )
                }
            }
        }
        .onAppear { apply(text, immediate: true) }
        .onChange(of: text) { _, newValue in
            apply(newValue, immediate: !isStreaming)
        }
    }

    private func apply(_ newValue: String, immediate: Bool) {
        pendingText = newValue
        throttleTask?.cancel()
        if immediate {
            renderedText = newValue
            return
        }
        throttleTask = Task { [pendingText] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            await MainActor.run {
                renderedText = pendingText
            }
        }
    }

    private func markdownSegments(from text: String) -> [MarkdownSegment] {
        guard text.contains("```") else { return [MarkdownSegment(isCode: false, content: text)] }
        let rawParts = text.components(separatedBy: "```")
        var segments: [MarkdownSegment] = []
        for (idx, part) in rawParts.enumerated() {
            if idx % 2 == 1 {
                let cleaned = part.split(separator: "\n", omittingEmptySubsequences: false)
                let code = cleaned.count > 1 ? cleaned.dropFirst().joined(separator: "\n") : part
                segments.append(MarkdownSegment(isCode: true, content: String(code)))
            } else if !part.isEmpty {
                segments.append(MarkdownSegment(isCode: false, content: part))
            }
        }
        return segments.isEmpty ? [MarkdownSegment(isCode: false, content: text)] : segments
    }
}

private struct MarkdownSegment {
    let isCode: Bool
    let content: String
}

private struct MarkdownAttributedText: View {
    let text: String
    let baseFont: Font
    let textColor: Color

    var body: some View {
        let processed = MarkdownLinkDetector.linkify(text)
        let attributed = MarkdownAttributedText.makeAttributed(
            from: processed,
            fallbackFont: baseFont,
            fallbackColor: UIColor(textColor)
        )
        Text(attributed)
            .lineSpacing(6)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func makeAttributed(from text: String, fallbackFont: Font, fallbackColor: UIColor) -> AttributedString {
        var attributed = (try? AttributedString(markdown: text)) ?? AttributedString(text)
        for run in attributed.runs {
            if run.font == nil {
                attributed[run.range].font = fallbackFont
            }
            if run.foregroundColor == nil {
                attributed[run.range].foregroundColor = fallbackColor
            }
        }
        return attributed
    }
}

private struct CodeBlockView: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(code.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(HVTheme.botText.opacity(0.9))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(HVTheme.surfaceAlt.opacity(0.8))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
        )
    }
}

enum MarkdownLinkDetector {
    static func longURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { $0.url }.filter { $0.absoluteString.count > 60 }
    }

    static func linkify(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }
        var output = text
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let url = match.url else { continue }
            let urlString = url.absoluteString
            if isMarkdownLink(in: output, urlString: urlString) { continue }
            let label = urlString.count > 60 ? "View event" : urlString
            let replacement = "[\(label)](\(urlString))"
            if let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: replacement)
            }
        }
        return output
    }

    private static func isMarkdownLink(in text: String, urlString: String) -> Bool {
        guard let range = text.range(of: urlString) else { return false }
        let prefix = text[..<range.lowerBound]
        return prefix.hasSuffix("](")
    }
}
