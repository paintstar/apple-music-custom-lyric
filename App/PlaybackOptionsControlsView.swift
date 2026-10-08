import AppKit
import SwiftUI
import ShinAppleKit

struct PlaybackOptionsControlsView: View {
    @ObservedObject var model: PlaybackOptionsModel

    var body: some View {
        HStack(spacing: 12) {
            PlaybackShuffleButton(model: model)
            PlaybackRepeatButton(model: model)
            PlaybackVolumeButton(model: model)
        }
    }
}

struct PlaybackShuffleButton: View {
    @ObservedObject var model: PlaybackOptionsModel
    var body: some View { PlaybackModeButton(model: model, kind: .shuffle) }
}

struct PlaybackRepeatButton: View {
    @ObservedObject var model: PlaybackOptionsModel
    var body: some View { PlaybackModeButton(model: model, kind: .repeatMode) }
}

private struct PlaybackModeButton: View {
    enum Kind { case shuffle, repeatMode }
    @ObservedObject var model: PlaybackOptionsModel
    let kind: Kind
    @State private var showsDetails = false
    @State private var initiatedChange = false

    private var isKnown: Bool {
        kind == .shuffle ? model.snapshot.shuffleEnabled != nil : model.snapshot.repeatMode != nil
    }
    private var isOn: Bool {
        kind == .shuffle ? model.snapshot.shuffleEnabled == true : (model.snapshot.repeatMode ?? .off) != .off
    }
    private var label: String {
        if kind == .shuffle {
            return model.snapshot.shuffleEnabled.map { $0 ? "随机播放已开启" : "随机播放已关闭" } ?? "随机播放状态未知"
        }
        return model.snapshot.repeatMode?.playbackLabel ?? "循环状态未知"
    }
    private var symbol: String {
        if kind == .shuffle { return "shuffle" }
        return model.snapshot.repeatMode == .one ? "repeat.1" : "repeat"
    }

    var body: some View {
        Button {
            if !isKnown || model.errorMessage != nil {
                showsDetails = true
                if model.errorMessage == nil { model.refresh() }
            } else {
                initiatedChange = true
                if kind == .shuffle { model.toggleShuffle() } else { model.cycleRepeat() }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: PlaybackControlSizing.iconSize, weight: .medium))
                .foregroundStyle(isOn ? Color.appleMusicPink : .secondary)
                .frame(width: PlaybackControlSizing.optionSide, height: PlaybackControlSizing.optionSide)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if !isKnown {
                        Image(systemName: "questionmark.circle.fill").font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .buttonStyle(PlaybackButtonStyle(isSelected: isOn))
        .disabled(model.isBusy)
        .accessibilityLabel(label)
        .help(label + (isKnown ? " · 点击切换" : " · 点击重试读取"))
        .popover(isPresented: $showsDetails) { PlaybackOptionsStatusView(model: model, title: label) }
        .onChange(of: model.errorMessage) { _, message in
            if initiatedChange, message != nil { showsDetails = true; initiatedChange = false }
        }
        .onChange(of: model.isBusy) { _, busy in
            if !busy, model.errorMessage == nil { initiatedChange = false }
        }
        .modifier(PlaybackOptionsVisibility(model: model))
    }
}

struct PlaybackVolumeButton: View {
    @ObservedObject var model: PlaybackOptionsModel
    var compact = false
    @State private var showsVolume = false
    @State private var previewVolume: Int?

    private var volume: Int? { previewVolume ?? model.displayedVolume }
    private var symbol: String {
        guard let volume else { return "speaker.badge.exclamationmark" }
        if volume == 0 { return "speaker.slash.fill" }
        return volume < 50 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    var body: some View {
        Button { showsVolume.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: compact ? 14 : PlaybackControlSizing.iconSize, weight: .medium))
                .frame(width: compact ? 28 : PlaybackControlSizing.optionSide,
                       height: compact ? 30 : PlaybackControlSizing.optionSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlaybackButtonStyle(isSelected: showsVolume))
        .accessibilityLabel(volume.map { "音乐音量，\($0)%" } ?? "音乐音量未知")
        .help("调整「音乐」App 音量")
        .popover(isPresented: $showsVolume) {
            PlaybackVolumePopover(model: model, previewVolume: $previewVolume)
        }
        .onChange(of: showsVolume) { _, visible in
            previewVolume = nil
            if visible { model.refresh() }
        }
        .modifier(PlaybackOptionsVisibility(model: model))
    }
}

/// 读取、调整和空闲共用同一行，避免拖动松手时弹窗高度改变。
struct PlaybackVolumePopover: View {
    @ObservedObject var model: PlaybackOptionsModel
    @Binding var previewVolume: Int?

    private var volume: Int? { previewVolume ?? model.displayedVolume }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("音乐音量").font(.headline)
                Spacer()
                Text(volume.map { "\($0)%" } ?? "未知").monospacedDigit().foregroundStyle(.secondary)
            }
            Group {
                if let current = volume {
                    PlaybackVolumeSlider(value: current, enabled: model.snapshot.volume != nil,
                                         onPreview: { previewVolume = $0 }, onCommit: model.setVolume)
                } else {
                    Text("音量暂时无法读取").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 22)
            HStack(spacing: 8) {
                Button(model.errorMessage == nil ? "刷新播放选项" : "重试") { model.refresh() }
                    .disabled(model.isBusy)
                Spacer(minLength: 0)
                ProgressView().controlSize(.small).opacity(model.isBusy ? 1 : 0)
                    .accessibilityHidden(!model.isBusy)
            }
            .font(.caption)
            .frame(height: 22)
            .accessibilityValue(model.isBusy ? (model.pendingVolume == nil ? "正在读取播放选项" : "正在调整音量") : "")
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

private struct PlaybackOptionsStatusView: View {
    @ObservedObject var model: PlaybackOptionsModel
    let title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.headline) }
            if model.isBusy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取…") }
            } else if let message = model.errorMessage {
                Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("重试") { model.refresh() }
            } else {
                if model.snapshot.volume == nil || model.snapshot.shuffleEnabled == nil || model.snapshot.repeatMode == nil {
                    Text("部分播放选项暂时无法读取。").foregroundStyle(.secondary)
                }
                Button("刷新播放选项") { model.refresh() }
            }
        }
        .font(.caption)
        .padding(title == nil ? 0 : 16)
        .frame(maxWidth: title == nil ? nil : 280, alignment: .leading)
    }
}

private struct PlaybackOptionsVisibility: ViewModifier {
    @ObservedObject var model: PlaybackOptionsModel
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { model.appear(id) }
            .onDisappear { model.disappear(id) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refresh()
            }
    }
}

/// 拖动仅预览，松开提交一次；方向键与辅助功能调节直接提交。
struct PlaybackVolumeSlider: NSViewRepresentable {
    let value: Int
    let enabled: Bool
    let onPreview: (Int?) -> Void
    let onCommit: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> VolumeSlider {
        let slider = VolumeSlider()
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.coordinator = context.coordinator
        slider.setAccessibilityLabel("音乐音量")
        slider.toolTip = "拖动后松开设置音量；方向键微调音量"
        return slider
    }
    func updateNSView(_ slider: VolumeSlider, context: Context) {
        context.coordinator.parent = self
        slider.updateVolumeEnabled(enabled)
        if !slider.isTrackingMouse, slider.integerValue != value { slider.integerValue = value }
        let description = "\(slider.integerValue)%"
        if slider.accessibilityValueDescription() != description { slider.setAccessibilityValueDescription(description) }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PlaybackVolumeSlider
        private var interactionGeneration: UInt64 = 0
        init(_ parent: PlaybackVolumeSlider) { self.parent = parent }
        func begin() { interactionGeneration &+= 1 }
        func cancel() {
            interactionGeneration &+= 1
            let generation = interactionGeneration
            // 取消可来自 SwiftUI 渲染/卸载；离开当前更新后清预览，新手势使旧清理失效。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.interactionGeneration == generation else { return }
                self.parent.onPreview(nil)
            }
        }
        @objc func changed(_ slider: VolumeSlider) {
            slider.setAccessibilityValueDescription("\(slider.integerValue)%")
            if slider.isTrackingMouse { parent.onPreview(slider.integerValue) } else { commit(slider) }
        }
        func commit(_ slider: VolumeSlider) {
            if parent.enabled { parent.onCommit(slider.integerValue) }
            // 同步保存待确认目标后才结束预览，避免松手回跳到旧快照。
            parent.onPreview(nil)
        }
    }
    @MainActor
    final class VolumeSlider: NSSlider {
        weak var coordinator: Coordinator?
        private(set) var isTrackingMouse = false
        private var grabOffset: CGFloat = 0

        override var mouseDownCanMoveWindow: Bool { false }

        func updateVolumeEnabled(_ enabled: Bool) {
            if !enabled { cancelMouseTracking() }
            guard isEnabled != enabled else { return }
            if !enabled, window?.firstResponder === self {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.coordinator?.parent.enabled == false else { return }
                    if self.window?.firstResponder === self { self.window?.makeFirstResponder(nil) }
                    self.isEnabled = false
                }
            } else {
                isEnabled = enabled
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled, coordinator?.parent.enabled == true else { return }
            window?.makeFirstResponder(self)
            isTrackingMouse = true
            coordinator?.begin()
            let point = convert(event.locationInWindow, from: nil)
            let knob = (cell as? NSSliderCell)?.knobRect(flipped: isFlipped) ?? .zero
            grabOffset = knob.contains(point) ? point.x - knob.midX : 0
            preview(event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard isTrackingMouse else { return }
            preview(event)
        }

        override func mouseUp(with event: NSEvent) {
            guard isTrackingMouse else { return }
            preview(event)
            guard isTrackingMouse else { return }
            isTrackingMouse = false
            coordinator?.commit(self)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { cancelMouseTracking() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func cancelOperation(_ sender: Any?) { cancelMouseTracking() }

        override func accessibilityPerformIncrement() -> Bool { adjustAccessibleVolume(by: 1) }
        override func accessibilityPerformDecrement() -> Bool { adjustAccessibleVolume(by: -1) }

        private func adjustAccessibleVolume(by amount: Int) -> Bool {
            guard isEnabled, coordinator?.parent.enabled == true else { return false }
            // 音量协议为 0...100 整数；VoiceOver 每次微调一个百分点。
            let next = min(max(integerValue + amount, Int(minValue)), Int(maxValue))
            guard next != integerValue else { return false }
            integerValue = next
            needsDisplay = true
            return sendAction(action, to: target)
        }

        func cancelMouseTracking() {
            guard isTrackingMouse else { return }
            isTrackingMouse = false
            coordinator?.cancel()
        }

        private func preview(_ event: NSEvent) {
            guard isEnabled, coordinator?.parent.enabled == true, let cell = cell as? NSSliderCell else {
                cancelMouseTracking()
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            let bar = cell.barRect(flipped: isFlipped)
            let knobWidth = cell.knobRect(flipped: isFlipped).width
            let travel = bar.width - knobWidth
            guard travel > 0 else { return }
            let fraction = min(max((point.x - grabOffset - bar.minX - knobWidth / 2) / travel, 0), 1)
            doubleValue = minValue + Double(fraction) * (maxValue - minValue)
            needsDisplay = true
            sendAction(action, to: target)
        }
    }
}
