import SwiftUI

/// Dark theme colors matching the Android app (GitHub-style).
enum Theme {
    static let background = Color(hex: 0x0D1117)
    static let surface = Color(hex: 0x161B22)
    static let border = Color(hex: 0x30363D)
    static let primary = Color(hex: 0x58A6FF)   // Blue
    static let green = Color(hex: 0x3FB950)      // Status green
    static let red = Color(hex: 0xF85149)        // Error red
    static let text = Color(hex: 0xC9D1D9)       // Primary text
    static let textSecondary = Color(hex: 0x8B949E)
}

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
