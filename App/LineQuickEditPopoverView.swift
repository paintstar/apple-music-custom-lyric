import SwiftUI
import ShinAppleKit

/// 单句歌词原文、逐行注音与简体中文译文快捷编辑 Popover。
struct LineQuickEditPopoverView: View {
    @ObservedObject var studyModel: LyricsStudyModel
    let initialState: LineQuickEditState

    private var state: LineQuickEditState {
        studyModel.lineEditPopover?.id == initialState.id
            ? (studyModel.lineEditPopover ?? initialState)
            : initialState
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { state.draftText },
            set: { newValue in
                guard var current = studyModel.lineEditPopover,
                      current.id == initialState.id,
                      newValue != current.draftText else { return }
                current.draftText = newValue
                current.errorMessage = nil
                studyModel.lineEditPopover = current
            }
        )
    }

    private var pronunciationBinding: Binding<String> {
        Binding(
            get: { state.draftPronunciation },
            set: { newValue in
                guard var current = studyModel.lineEditPopover,
                      current.id == initialState.id,
                      newValue != current.draftPronunciation else { return }
                current.draftPronunciation = newValue
                current.errorMessage = nil
                studyModel.lineEditPopover = current
            }
        )
    }

    private var pronunciationStyleBinding: Binding<PronunciationStyle> {
        Binding(
            get: { state.draftPronunciationStyle },
            set: { newValue in
                guard var current = studyModel.lineEditPopover,
                      current.id == initialState.id,
                      newValue != current.draftPronunciationStyle else { return }
                current.draftPronunciationStyle = newValue
                current.errorMessage = nil
                studyModel.lineEditPopover = current
            }
        )
    }

    private var translationBinding: Binding<String> {
        Binding(
            get: { state.draftTranslation },
            set: { newValue in
                guard var current = studyModel.lineEditPopover,
                      current.id == initialState.id,
                      newValue != current.draftTranslation else { return }
                current.draftTranslation = newValue
                current.errorMessage = nil
                studyModel.lineEditPopover = current
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerSection
                Divider()
                originalTextSection
                pronunciationSection
                translationSection
                if let errorMessage = state.errorMessage {
                    StudyErrorLabel(message: errorMessage)
                }
                Divider()
                footerSection
            }
            .padding(14)
        }
        .frame(width: 400)
        .frame(maxHeight: 500)
    }

    private var headerSection: some View {
        HStack(spacing: 6) {
            Label("编辑本句歌词", systemImage: "square.and.pencil")
                .font(.headline)
            if let startMs = state.startMs {
                Text(Self.formattedTimestamp(startMs))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            Spacer()
            Button {
                studyModel.dismissLineQuickEdit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    private var originalTextSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("歌词原文")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("输入歌词原文", text: textBinding, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .lineLimit(1...4)
                .disabled(state.isSaving)
        }
    }

    private var pronunciationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("逐行注音")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if state.pronunciationNeedsReview && !state.pronunciationChanged {
                    StudyCapsuleBadge(text: "待复核", tint: .orange, backgroundOpacity: 0.16)
                }
                Spacer(minLength: 4)
                Picker("注音样式", selection: pronunciationStyleBinding) {
                    ForEach(PronunciationStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .disabled(state.isSaving)
            }
            TextField("留空可清除本句注音", text: pronunciationBinding, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .lineLimit(1...3)
                .disabled(state.isSaving)
        }
    }

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("简体中文译文")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if state.translationNeedsReview && !state.translationChanged {
                    StudyCapsuleBadge(text: "待复核", tint: .orange, backgroundOpacity: 0.16)
                }
                Spacer(minLength: 4)
            }
            TextField("留空可清除本句译文", text: translationBinding, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .lineLimit(1...3)
                .disabled(state.isSaving)
        }
    }

    private var footerSection: some View {
        HStack(spacing: 8) {
            Text("保存后记为人工编辑，不会被自动获取覆盖")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("取消") {
                studyModel.dismissLineQuickEdit()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.isSaving)

            Button {
                studyModel.saveLineQuickEdit()
            } label: {
                if state.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("保存")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!state.hasChanges || state.isSaving)
        }
    }

    private static func formattedTimestamp(_ ms: Int64) -> String {
        let clamped = max(0, ms)
        let totalSeconds = clamped / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let centiseconds = (clamped % 1_000) / 10
        return String(format: "%02lld:%02lld.%02lld", minutes, seconds, centiseconds)
    }
}
