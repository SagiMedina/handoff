import SwiftUI

/// Two-row toolbar of extra keys for terminal use on mobile.
/// Mirrors the Android key surface closely so muscle memory carries over.
struct MobileToolbar: View {
    let onKey: (Data) -> Void

    @State private var ctrlActive = false
    @State private var altActive = false
    @State private var shiftActive = false

    private let row1: [ToolbarKey] = [
        .init(label: "ESC", tapData: .esc, longPressData: .ctrlC),
        .init(label: "/", tapData: .char("/")),
        .init(label: "-", tapData: .char("-"), longPressData: .char("|")),
        .init(label: "HOME", tapData: .home),
        .init(label: "\u{2191}", tapData: .up, longPressData: .pageUp),
        .init(label: "END", tapData: .end),
        .init(label: "SHIFT", tapData: nil),
    ]

    private let row2: [ToolbarKey] = [
        .init(label: "TAB", tapData: .tab),
        .init(label: "CTRL", tapData: nil),
        .init(label: "ALT", tapData: nil),
        .init(label: "\u{2190}", tapData: .left, longPressData: .altB, repeatsLongPress: true),
        .init(label: "\u{2193}", tapData: .down, longPressData: .pageDown),
        .init(label: "\u{2192}", tapData: .right, longPressData: .altF, repeatsLongPress: true),
        .init(label: "\u{21B5}", tapData: .enter),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Theme.border)

            toolbarRow(row1)
            toolbarRow(row2)
        }
        .background(Theme.surface)
    }

    private func toolbarRow(_ keys: [ToolbarKey]) -> some View {
        HStack(spacing: 0) {
            ForEach(keys) { key in
                ToolbarButton(
                    key: key,
                    isActive: isModifierActive(key),
                    onTap: { handleTap(for: key) },
                    onLongPress: { handleLongPress(for: key) }
                )
            }
        }
    }

    private func isModifierActive(_ key: ToolbarKey) -> Bool {
        switch key.label {
        case "CTRL":
            return ctrlActive
        case "ALT":
            return altActive
        case "SHIFT":
            return shiftActive
        default:
            return false
        }
    }

    private func handleTap(for key: ToolbarKey) {
        switch key.label {
        case "CTRL":
            ctrlActive.toggle()
        case "ALT":
            altActive.toggle()
        case "SHIFT":
            shiftActive.toggle()
        default:
            guard let data = key.tapData else { return }
            send(data.bytes)
        }
    }

    private func handleLongPress(for key: ToolbarKey) {
        guard let data = key.longPressData else {
            handleTap(for: key)
            return
        }
        send(data.bytes, consumeShift: false)
    }

    private func send(_ bytes: [UInt8], consumeShift: Bool = true) {
        var finalBytes = bytes

        if ctrlActive {
            finalBytes = applyCtrl(to: finalBytes)
            ctrlActive = false
        }
        if consumeShift && shiftActive {
            finalBytes = applyShift(to: finalBytes)
            shiftActive = false
        }
        if altActive {
            finalBytes = [0x1B] + finalBytes
            altActive = false
        }

        onKey(Data(finalBytes))
    }

    private func applyCtrl(to bytes: [UInt8]) -> [UInt8] {
        if bytes.count == 1, bytes[0] >= 0x40, bytes[0] <= 0x7F {
            return [bytes[0] & 0x1F]
        }
        return bytes
    }

    private func applyShift(to bytes: [UInt8]) -> [UInt8] {
        if bytes == KeyData.tab.bytes {
            return [0x1B, 0x5B, 0x5A]
        }
        if bytes == KeyData.enter.bytes {
            return [0x0A]
        }
        if bytes.count == 3, bytes[0] == 0x1B, bytes[1] == 0x5B {
            let arrow = bytes[2]
            if [0x41, 0x42, 0x43, 0x44].contains(arrow) {
                return [0x1B, 0x5B, 0x31, 0x3B, 0x32, arrow]
            }
        }
        return bytes
    }
}

private struct ToolbarButton: View {
    let key: ToolbarKey
    let isActive: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var touchStart: Date?
    @State private var longPressFired = false
    @State private var repeatTask: Task<Void, Never>?

    private let longPressDelay: TimeInterval = 0.45
    private let repeatInterval: UInt64 = 80_000_000

    var body: some View {
        Text(key.label)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundColor(isActive ? Theme.background : Theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(isActive ? Theme.primary : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard touchStart == nil else { return }
                        touchStart = Date()
                        longPressFired = false
                        if key.longPressData != nil {
                            repeatTask = Task {
                                try? await Task.sleep(nanoseconds: UInt64(longPressDelay * 1_000_000_000))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    longPressFired = true
                                    onLongPress()
                                }
                                guard key.repeatsLongPress else { return }
                                while !Task.isCancelled {
                                    try? await Task.sleep(nanoseconds: repeatInterval)
                                    guard !Task.isCancelled else { return }
                                    await MainActor.run {
                                        onLongPress()
                                    }
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        let wasLongPress = longPressFired
                        resetTouchState()
                        if !wasLongPress {
                            onTap()
                        }
                    }
            )
    }

    private func resetTouchState() {
        repeatTask?.cancel()
        repeatTask = nil
        touchStart = nil
        longPressFired = false
    }
}

private struct ToolbarKey: Identifiable {
    let id = UUID()
    let label: String
    let tapData: KeyData?
    let longPressData: KeyData?
    let repeatsLongPress: Bool

    init(label: String, tapData: KeyData?, longPressData: KeyData? = nil, repeatsLongPress: Bool = false) {
        self.label = label
        self.tapData = tapData
        self.longPressData = longPressData
        self.repeatsLongPress = repeatsLongPress
    }
}

private enum KeyData {
    case esc
    case ctrlC
    case tab
    case enter
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case altB
    case altF
    case char(String)

    var bytes: [UInt8] {
        switch self {
        case .esc:
            return [0x1B]
        case .ctrlC:
            return [0x03]
        case .tab:
            return [0x09]
        case .enter:
            return [0x0D]
        case .up:
            return [0x1B, 0x5B, 0x41]
        case .down:
            return [0x1B, 0x5B, 0x42]
        case .right:
            return [0x1B, 0x5B, 0x43]
        case .left:
            return [0x1B, 0x5B, 0x44]
        case .home:
            return [0x1B, 0x5B, 0x48]
        case .end:
            return [0x1B, 0x5B, 0x46]
        case .pageUp:
            return [0x1B, 0x5B, 0x35, 0x7E]
        case .pageDown:
            return [0x1B, 0x5B, 0x36, 0x7E]
        case .altB:
            return [0x1B, 0x62]
        case .altF:
            return [0x1B, 0x66]
        case .char(let string):
            return Array(string.utf8)
        }
    }
}
