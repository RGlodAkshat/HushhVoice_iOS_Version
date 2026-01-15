import SwiftUI

struct SummaryHushhTechNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HVTheme.accent)
                .padding(6)
                .background(Circle().fill(HVTheme.surfaceAlt.opacity(0.8)))
            Text("HushhTech builds personal AI systems that work for you, not advertisers - private, consent-first, and fully under your control.")
                .font(.footnote)
                .foregroundStyle(HVTheme.botText.opacity(0.65))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(HVTheme.surfaceAlt.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06)))
        )
    }
}
