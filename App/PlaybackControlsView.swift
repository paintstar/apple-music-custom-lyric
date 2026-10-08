import AppKit
import SwiftUI
import ShinAppleKit

/// 主要播放操作的视觉与命中尺寸；浮栏据此决定窄窗口的控制排布。
enum PlaybackControlSizing {
    static let iconSize: CGFloat = 18
    static let optionSide: CGFloat = 36
    static let skipWidth: CGFloat = 32
    static let playWidth: CGFloat = 40
    static let transportHeight: CGFloat = 40
    static let transportSpacing: CGFloat = 4
}

struct PlaybackControlsView: View {
    enum Layout { case stacked, inline, transport }
    @EnvironmentObject private var model: AppModel
    var layout: Layout = .stacked

    var body: some View {
        if layout == .transport {
            transport
        } else {
            controlsWithProgress
        }
    }

    private var controlsWithProgress: some View {
        VStack(spacing: 8) {
            if layout == .inline {
                HStack(spacing: 22) {
                    transport
                    PlaybackTimelineProgressView()
                }
            } else {
                PlaybackTimelineProgressView()
                transport.padding(.top, 2)
            }
            if let message = model.playbackMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: transportSpacing) {
            PlaybackShuffleButton(model: model.playbackOptions)
            Button { model.playPrevious() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: PlaybackControlSizing.iconSize, weight: .semibold))
                    .frame(width: layout == .transport ? PlaybackControlSizing.skipWidth : 34,
                           height: PlaybackControlSizing.transportHeight)
                    .contentShape(Rectangle())
            }
            .disabled(model.isChangingTrack || !canControl || !(model.snapshot.capabilities?.previous ?? model.isMock))
            .accessibilityLabel("上一首")
            .help(model.isChangingTrack ? "正在切换歌曲…" : "上一首")
            Button { model.togglePlayPause() } label: {
                Image(systemName: model.snapshot.status == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: layout == .transport ? 24 : 26, weight: .semibold))
                    .frame(width: PlaybackControlSizing.playWidth, height: PlaybackControlSizing.transportHeight)
                    .contentShape(Rectangle())
            }
            .disabled(!canControl || !(model.snapshot.capabilities?.playPause ?? model.isMock))
            .accessibilityLabel(model.snapshot.status == .playing ? "暂停" : "播放")
            .help(model.snapshot.status == .playing ? "暂停" : "播放")
            Button { model.playNext() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: PlaybackControlSizing.iconSize, weight: .semibold))
                    .frame(width: layout == .transport ? PlaybackControlSizing.skipWidth : 34,
                           height: PlaybackControlSizing.transportHeight)
                    .contentShape(Rectangle())
            }
            .disabled(model.isChangingTrack || !canControl || !(model.snapshot.capabilities?.next ?? model.isMock))
            .accessibilityLabel("下一首")
            .help(model.isChangingTrack ? "正在切换歌曲…" : "下一首")
            PlaybackRepeatButton(model: model.playbackOptions)
        }
        .buttonStyle(PlaybackButtonStyle())
        .foregroundStyle(.primary)
        .frame(maxWidth: layout == .stacked ? .infinity : nil)
    }

    private var transportSpacing: CGFloat {
        switch layout {
        case .stacked: return 18
        case .inline: return 12
        case .transport: return PlaybackControlSizing.transportSpacing
        }
    }

    private var canControl: Bool { canControlPlayback(model) }
}

struct PlaybackTimelineProgressView: View {
    @EnvironmentObject private var model: AppModel
    var showsTimeLabels = true
    var thinStyle = false

    var body: some View {
        TimelineView(AdaptiveProgressSchedule(isPlaying: model.snapshot.status == .playing)) { _ in
            let estimate = model.estimatedPositionMs(nowMonotonicMs: AppModel.monotonicNowMs())
            PlaybackProgressView(
                snapshot: model.snapshot,
                estimatePositionMs: model.pendingSeek?.positionMs ?? estimate.positionMs,
                isStale: model.pendingSeek == nil && estimate.isStale,
                durationMs: model.sliderDurationMs,
                enabled: canControlPlayback(model) && (model.snapshot.capabilities?.seek ?? model.isMock),
                showsTimeLabels: showsTimeLabels,
                thinStyle: thinStyle,
                onSeek: { position, snapshot in model.seek(toMs: position, expectedSnapshot: snapshot) }
            )
        }
    }
}

@MainActor
private func canControlPlayback(_ model: AppModel) -> Bool {
    guard case .ready = model.setup else { return false }
    switch model.snapshot.status {
    case .playing, .paused, .ended, .buffering, .seeking: return true
    default: return false
    }
}

/// 只有进度区域按帧更新；歌词行不进入时间线。
struct AdaptiveProgressSchedule: TimelineSchedule {
    var isPlaying: Bool
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> PeriodicTimelineSchedule.Entries {
        PeriodicTimelineSchedule(from: startDate, by: isPlaying ? 1.0 / 30.0 : 1.0)
            .entries(from: startDate, mode: mode)
    }
}

private struct PlaybackProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let snapshot: PlaybackSnapshot
    let estimatePositionMs: Int64?
    let isStale: Bool
    let durationMs: Int64
    let enabled: Bool
    let showsTimeLabels: Bool
    let thinStyle: Bool
    let onSeek: (Int64, PlaybackSnapshot) -> Void
    @State private var previewPositionMs: Int64?

    var body: some View {
        let position = previewPositionMs ?? estimatePositionMs
        VStack(spacing: 2) {
            PlaybackScrubber(
                snapshot: snapshot,
                positionMs: estimatePositionMs,
                durationMs: durationMs,
                enabled: enabled && durationMs > 1 && estimatePositionMs != nil && snapshot.positionMs != nil,
                thinStyle: thinStyle,
                reduceMotion: reduceMotion,
                onPreview: { previewPositionMs = $0 },
                onSeek: onSeek
            )
            .frame(height: thinStyle ? ThinPlaybackSliderSizing.hitHeight : 14)
            if showsTimeLabels {
                timeLabels(position)
            } else if let status = compactStatus(position) {
                Text(status).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).help(status)
            }
        }
        .frame(minWidth: 100)
        .onChange(of: snapshot.trackEpoch) { _, _ in previewPositionMs = nil }
        .onChange(of: snapshot.sessionEpoch) { _, _ in previewPositionMs = nil }
        .onChange(of: snapshot.trackKey) { _, _ in previewPositionMs = nil }
    }

    private func timeLabels(_ position: Int64?) -> some View {
        HStack {
            Text(PlayerBarView.formatDuration(position))
            if isStale {
                Image(systemName: "clock.badge.exclamationmark")
                    .help("播放位置暂未更新，正在等待新的播放状态")
                    .accessibilityLabel("播放位置暂未更新")
            }
            Spacer()
            Text("−" + PlayerBarView.formatDuration(remaining(position)))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func compactStatus(_ position: Int64?) -> String? {
        if position == nil { return "播放位置未知" }
        if durationMs <= 1 { return "歌曲时长未知" }
        return isStale ? "播放位置暂未更新" : nil
    }

    private func remaining(_ position: Int64?) -> Int64? {
        guard let position, durationMs > 1 else { return nil }
        return durationMs - min(max(position, 0), durationMs)
    }
}
