import SwiftUI

// Centralized colors and layout constants for consistent styling.
enum HVTheme {
    private static var _isDark: Bool = true

    static func setMode(isDark: Bool) { _isDark = isDark }
    static var isDark: Bool { _isDark }

    static var bg: Color { isDark ? .black : Color(white: 0.985) }
    static var surface: Color { isDark ? Color(white: 0.12) : .white }
    static var surfaceAlt: Color { isDark ? Color(white: 0.08) : Color(white: 0.94) }
    static var stroke: Color { isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06) }

    static var userBubble: LinearGradient {
        if isDark {
            return LinearGradient(
                colors: [Color.white.opacity(0.95), Color.white.opacity(0.80)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [Color.white, Color(white: 0.96)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    static var userText: Color { .black }
    static var botText: Color { isDark ? .white : Color(red: 0.12, green: 0.14, blue: 0.20) }

    static var accent: Color {
        if isDark {
            return Color(hue: 0.53, saturation: 0.55, brightness: 0.95)
        } else {
            return Color(red: 0.00, green: 0.55, blue: 0.43)
        }
    }

    static let corner: CGFloat = 16
    static let sidebarWidth: CGFloat = 280
    static let scrimOpacity: CGFloat = 0.40
}
