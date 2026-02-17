import SwiftUI
import SafariServices

struct VoiceCaptureBar: View {
    let micLevel: CGFloat
    let isMuted: Bool
    let onMicToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            WaveformView(level: micLevel, isMuted: isMuted, accent: HVTheme.accent)
                .frame(height: 32)
                .opacity(isMuted ? 0.45 : 0.85)

            Button(action: onMicToggle) {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(isMuted ? HVTheme.surfaceAlt : HVTheme.accent.opacity(0.2)))
                    .overlay(Circle().stroke(HVTheme.stroke))
            }
            .tint(isMuted ? HVTheme.botText : HVTheme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(HVTheme.surfaceAlt)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(HVTheme.stroke))
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
        )
    }
}

struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct GoogleConnectBanner: View {
    let onConnect: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HVTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect Google to enable Gmail + Calendar.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HVTheme.botText)
                Text("Tools are disabled until you sign in.")
                    .font(.caption)
                    .foregroundStyle(HVTheme.botText.opacity(0.7))
            }
            Spacer(minLength: 0)
            Button("Connect") { onConnect() }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(HVTheme.accent.opacity(0.18)))
            Button("Sign in") { onSignIn() }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(HVTheme.surfaceAlt))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(HVTheme.surfaceAlt.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(HVTheme.stroke))
        )
    }
}

struct ProgressRowView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HVTheme.accent)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HVTheme.botText.opacity(0.85))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(HVTheme.surfaceAlt.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
        )
        .padding(.horizontal, 20)
    }
}

struct ChatHintBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(HVTheme.botText.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(HVTheme.surfaceAlt.opacity(0.95))
                    .overlay(Capsule().stroke(HVTheme.stroke))
            )
    }
}

struct ChatScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
