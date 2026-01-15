import SwiftUI
import Orb

struct KaiOrb: View {
    let configuration: OrbConfiguration
    let size: CGFloat

    var body: some View {
        OrbView(configuration: configuration)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 28, x: 0, y: 14)
    }
}
