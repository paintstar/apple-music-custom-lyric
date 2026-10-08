import SwiftUI

/// 不改变控制槽位大小；鼠标与键盘按下都使用同一反馈。
struct PlaybackButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        PlaybackButtonAppearance(configuration: configuration, isSelected: isSelected)
    }
}

private struct PlaybackButtonAppearance: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var isPressed: Bool { isEnabled && configuration.isPressed }
    private var background: Color {
        if isPressed { return .appleMusicPink.opacity(0.24) }
        if isSelected { return .appleMusicPink.opacity(isEnabled && isHovered ? 0.20 : 0.12) }
        return .primary.opacity(isEnabled && isHovered ? 0.10 : 0)
    }

    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(isPressed && !reduceMotion ? 0.93 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
            .onHover { isHovered = $0 }
    }
}
