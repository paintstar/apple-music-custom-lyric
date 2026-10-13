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
    private var isPending: Bool {
        kind == .shuffle ? model.pendingShuffleChange : model.pendingRepeatChange
    }
    private var functionName: String { kind == .shuffle ? "随机播放" : "循环播放" }
    private var issueMessage: String? {
        kind == .shuffle ? model.shuffleErrorMessage : model.repeatErrorMessage
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
    private var help: String {
        let purpose = kind == .shuffle ? "随机播放：随机播放当前列表中的歌曲。" : "循环播放：重复播放当前列表或当前歌曲。"
        let action: String
        if isPending {
            action = "正在切换，等待「音乐」App 确认。"
        } else if !isKnown {
            action = "点击后读取状态并切换；读取失败会显示原因。"
        } else if kind == .shuffle {
            action = model.snapshot.shuffleEnabled == true ? "点击关闭随机播放。" : "点击开启随机播放。"
        } else {
            switch model.snapshot.repeatMode {
            case .off: action = "点击切换为列表循环。"
            case .all: action = "点击切换为单曲循环。"
            case .one: action = "点击关闭循环。"
            case nil: action = "点击读取状态并切换。"
            }
        }
        var lines = [purpose, "当前：\(label)。", action]
        if model.isBusy, !isPending { lines.append("正在读取或调整其他播放选项，点击后会依次执行。") }
        if let error = issueMessage { lines.append("上次操作：\(error)") }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        Button {
            initiatedChange = true
            if !isKnown || issueMessage != nil { showsDetails = true }
            if kind == .shuffle { model.toggleShuffle() } else { model.cycleRepeat() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: PlaybackControlSizing.iconSize, weight: .medium))
                .foregroundStyle(isOn ? Color.appleMusicPink : .secondary)
                .opacity(isPending ? 0.35 : 1)
                .frame(width: PlaybackControlSizing.optionSide, height: PlaybackControlSizing.optionSide)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if isPending {
                        ProgressView().controlSize(.mini)
                    } else if issueMessage != nil {
                        Image(systemName: "exclamationmark.circle.fill").font(.caption2)
                            .foregroundStyle(.orange)
                    } else if !isKnown {
                        Image(systemName: "questionmark.circle.fill").font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .buttonStyle(PlaybackButtonStyle(isSelected: isOn))
        .disabled(isPending)
        .accessibilityLabel(label)
        .accessibilityHint(help)
        .overlay { PlaybackModeTooltip(text: help).allowsHitTesting(false).accessibilityHidden(true) }
        .popover(isPresented: $showsDetails) {
            PlaybackOptionsStatusView(model: model, title: functionName, stateDescription: label,
                                      sequenceDescription: kind == .repeatMode ? "依次切换：关闭 → 列表循环 → 单曲循环 → 关闭" : nil,
                                      issueMessage: issueMessage, isChanging: isPending,
                                      retry: { if kind == .shuffle { model.toggleShuffle() } else { model.cycleRepeat() } })
        }
        .onChange(of: issueMessage) { _, message in
            if initiatedChange, message != nil { showsDetails = true; initiatedChange = false }
        }
        .onChange(of: isPending) { _, pending in
            if !pending, issueMessage == nil { initiatedChange = false }
        }
        .modifier(PlaybackOptionsVisibility(model: model))
    }
}

/// AppKit 注册完整按钮区域的 tooltip；不参与命中，避免浮窗 popover 与按钮样式吞掉悬停提示。
private struct PlaybackModeTooltip: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> HelpView {
        let view = HelpView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: HelpView, context: Context) { view.toolTip = text }
    final class HelpView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    let title: String
    let stateDescription: String
    let sequenceDescription: String?
    let issueMessage: String?
    let isChanging: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text("当前：\(stateDescription)")
            if let sequenceDescription { Text(sequenceDescription).foregroundStyle(.secondary) }
            if model.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(isChanging ? "正在切换，等待音乐确认…" : "正在读取…")
                }
            }
            if let message = issueMessage {
                Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("重试切换", action: retry).disabled(isChanging)
            } else {
                if model.snapshot.volume == nil || model.snapshot.shuffleEnabled == nil || model.snapshot.repeatMode == nil {
                    Text("部分播放选项暂时无法读取。").foregroundStyle(.secondary)
                }
                Button("刷新播放选项") { model.refresh() }.disabled(model.isBusy)
            }
        }
        .font(.caption)
        .padding(16)
        .frame(maxWidth: 280, alignment: .leading)
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
        slider.focusRingType = .none
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
        if !slider.isTrackingMouse, slider.integerValue != value {
            slider.integerValue = value
            slider.noteFocusRingMaskChanged()
        }
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
            slider.noteFocusRingMaskChanged()
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

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted {
                // 弹窗自动聚焦和鼠标点击不画键盘圆环；Tab 进入仍保留系统提示。
                showKeyboardFocus(NSApplication.shared.currentEvent?.type == .keyDown)
            }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { showKeyboardFocus(false) }
            return resigned
        }

        override func keyDown(with event: NSEvent) {
            showKeyboardFocus(true)
            super.keyDown(with: event)
            noteFocusRingMaskChanged()
        }

        private func showKeyboardFocus(_ shown: Bool) {
            focusRingType = shown ? .default : .none
            noteFocusRingMaskChanged()
            needsDisplay = true
        }

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
            showKeyboardFocus(false)
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
            if newWindow !== window {
                cancelMouseTracking()
                showKeyboardFocus(false)
            }
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
