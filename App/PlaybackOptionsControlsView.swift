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
        .buttonStyle(.plain)
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

    private var volume: Int? { previewVolume ?? model.snapshot.volume }
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
        .buttonStyle(.plain)
        .accessibilityLabel(volume.map { "音乐音量，\($0)%" } ?? "音乐音量未知")
        .help("调整「音乐」App 音量")
        .popover(isPresented: $showsVolume) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("音乐音量").font(.headline)
                    Spacer()
                    Text(volume.map { "\($0)%" } ?? "未知").monospacedDigit().foregroundStyle(.secondary)
                }
                if let current = model.snapshot.volume {
                    PlaybackVolumeSlider(value: current, enabled: !model.isBusy,
                                         onPreview: { previewVolume = $0 }, onCommit: model.setVolume)
                        .frame(height: 22)
                }
                PlaybackOptionsStatusView(model: model, title: nil)
            }
            .padding(16)
            .frame(width: 260)
        }
        .onChange(of: showsVolume) { _, visible in
            previewVolume = nil
            if visible { model.refresh() }
        }
        .modifier(PlaybackOptionsVisibility(model: model))
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
private struct PlaybackVolumeSlider: NSViewRepresentable {
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
        return slider
    }
    func updateNSView(_ slider: VolumeSlider, context: Context) {
        context.coordinator.parent = self
        slider.isEnabled = enabled
        if !slider.isTrackingMouse { slider.integerValue = value }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PlaybackVolumeSlider
        init(_ parent: PlaybackVolumeSlider) { self.parent = parent }
        @objc func changed(_ slider: VolumeSlider) {
            if slider.isTrackingMouse { parent.onPreview(slider.integerValue) } else { commit(slider) }
        }
        func commit(_ slider: VolumeSlider) {
            parent.onPreview(nil)
            if parent.enabled { parent.onCommit(slider.integerValue) }
        }
    }
    @MainActor
    final class VolumeSlider: NSSlider {
        weak var coordinator: Coordinator?
        var isTrackingMouse = false
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            isTrackingMouse = true
            super.mouseDown(with: event)
            isTrackingMouse = false
            coordinator?.commit(self)
        }
    }
}
