import SwiftUI

/// Two-row toolbar of extra keys for terminal use on mobile.
/// Matches the Android/Termux layout for consistency.
struct MobileToolbar: View {
    /// Called with the escape sequence bytes for the tapped key.
    let onKey: (Data) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Theme.border)

            // Row 1: ESC  /  -  HOME  UP  END  PGUP
            HStack(spacing: 0) {
                toolbarKey("ESC", data: .esc)
                toolbarKey("/", data: .char("/"))
                toolbarKey("-", data: .char("-"))
                toolbarKey("HOME", data: .home)
                toolbarKey("\u{2191}", data: .up)    // ↑
                toolbarKey("END", data: .end)
                toolbarKey("PgUp", data: .pageUp)
            }

            // Row 2: TAB  CTRL  ALT  LEFT  DOWN  RIGHT  PGDN
            HStack(spacing: 0) {
                toolbarKey("TAB", data: .tab)
                toolbarToggle("CTRL", modifier: .ctrl)
                toolbarToggle("ALT", modifier: .alt)
                toolbarKey("\u{2190}", data: .left)   // ←
                toolbarKey("\u{2193}", data: .down)    // ↓
                toolbarKey("\u{2192}", data: .right)   // →
                toolbarKey("PgDn", data: .pageDown)
            }
        }
        .background(Theme.surface)
    }

    // MARK: - State for modifier toggles

    @State private var ctrlActive = false
    @State private var altActive = false

    // MARK: - Key views

    private func toolbarKey(_ label: String, data: KeyData) -> some View {
        Button {
            var bytes = data.bytes
            if ctrlActive {
                bytes = applyCtrl(to: bytes)
                ctrlActive = false
            }
            if altActive {
                bytes = applyAlt(to: bytes)
                altActive = false
            }
            onKey(Data(bytes))
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
        }
    }

    private func toolbarToggle(_ label: String, modifier: Modifier) -> some View {
        let isActive = modifier == .ctrl ? ctrlActive : altActive

        return Button {
            switch modifier {
            case .ctrl: ctrlActive.toggle()
            case .alt: altActive.toggle()
            }
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(isActive ? Theme.background : Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(isActive ? Theme.primary : Color.clear)
        }
    }

    private enum Modifier { case ctrl, alt }

    // MARK: - Modifier application

    private func applyCtrl(to bytes: [UInt8]) -> [UInt8] {
        // Ctrl turns letters into control codes (e.g., Ctrl+C = 0x03)
        if bytes.count == 1, bytes[0] >= 0x40, bytes[0] <= 0x7F {
            return [bytes[0] & 0x1F]
        }
        return bytes
    }

    private func applyAlt(to bytes: [UInt8]) -> [UInt8] {
        // Alt/Meta prefixes with ESC (0x1B)
        return [0x1B] + bytes
    }
}

// MARK: - Key escape sequences

enum KeyData {
    case esc, tab
    case up, down, left, right
    case home, end, pageUp, pageDown
    case char(String)

    var bytes: [UInt8] {
        switch self {
        case .esc:      return [0x1B]
        case .tab:      return [0x09]
        case .up:       return [0x1B, 0x5B, 0x41]        // ESC [ A
        case .down:     return [0x1B, 0x5B, 0x42]        // ESC [ B
        case .right:    return [0x1B, 0x5B, 0x43]        // ESC [ C
        case .left:     return [0x1B, 0x5B, 0x44]        // ESC [ D
        case .home:     return [0x1B, 0x5B, 0x48]        // ESC [ H
        case .end:      return [0x1B, 0x5B, 0x46]        // ESC [ F
        case .pageUp:   return [0x1B, 0x5B, 0x35, 0x7E]  // ESC [ 5 ~
        case .pageDown: return [0x1B, 0x5B, 0x36, 0x7E]  // ESC [ 6 ~
        case .char(let s):
            return Array(s.utf8)
        }
    }
}
