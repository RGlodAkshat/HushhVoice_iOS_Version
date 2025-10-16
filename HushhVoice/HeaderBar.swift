import SwiftUI

struct HeaderBar: View {
    var body: some View {
        HStack(spacing: 12) {
            // Replace "hushh_logo" with your asset name later
            if UIImage(named: "hushh_logo") != nil {
                Image("hushh_logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                // Placeholder if image not yet added
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .overlay(Text("H").font(.caption).bold().foregroundColor(.black))
            }

            Text("HushhVoice")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(HVTheme.bg.opacity(0.95))
    }
}
