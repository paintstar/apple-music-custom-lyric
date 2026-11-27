import SwiftUI
import ShinAppleKit

/// 同步歌词区之上的划词浮动胶囊条与学习窗口锚点层。
/// 空闲像素不拦截事件，确保底层原生滚动、双击重听与拖选照常工作。
struct LyricsStudyOverlayLayer: View {
    @ObservedObject var studyModel: LyricsStudyModel
    let document: LyricDocument
    let containerSize: CGSize
    let onStudyPopoverPresentedChange: (Bool) -> Void
    var lineLoopMenuState: ((UUID) -> LyricsLineLoopMenuState?)?
    var onToggleSingleLineLoop: ((UUID) -> Void)?
    var onClearTextSelection: (() -> Void)?

    @State private var barSize = CGSize(width: 220, height: 34)

    private var wordStudyState: WordPopoverState? {
        guard let state = studyModel.wordPopover, state.documentId == document.id else { return nil }
        return state
    }

    private var isPopoverOpen: Bool {
        wordStudyState != nil || studyModel.linePopover != nil || studyModel.lineEditPopover != nil
    }

    private var linePopoverBinding: Binding<LinePopoverState?> {
        Binding(
            get: { studyModel.linePopover },
            set: { newValue in
                if newValue == nil {
                    studyModel.dismissLinePopover()
                }
            }
        )
    }

    private var lineEditPopoverBinding: Binding<LineQuickEditState?> {
        Binding(
            get: { studyModel.lineEditPopover },
            set: { newValue in
                if newValue == nil {
                    studyModel.dismissLineQuickEdit()
                }
            }
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WordStudyWindowPresenter(
                studyModel: studyModel,
                state: wordStudyState,
                anchorRect: clampedAnchorRect(wordStudyState?.anchorRectInScrollViewport)
            )
            .frame(width: containerSize.width, height: containerSize.height)
            .allowsHitTesting(false)

            Color.clear
                .allowsHitTesting(false)
                .popover(
                    item: linePopoverBinding,
                    attachmentAnchor: .rect(.rect(clampedAnchorRect(studyModel.linePopover?.anchorRectInScrollViewport))),
                    arrowEdge: .bottom
                ) { state in
                    LineStudyPopoverView(studyModel: studyModel, initialState: state)
                }

            Color.clear
                .allowsHitTesting(false)
                .popover(
                    item: lineEditPopoverBinding,
                    attachmentAnchor: .rect(.rect(clampedAnchorRect(studyModel.lineEditPopover?.anchorRectInScrollViewport))),
                    arrowEdge: .bottom
                ) { state in
                    LineQuickEditPopoverView(studyModel: studyModel, initialState: state)
                }

            if let selection = studyModel.selectionBar,
               selection.documentId == document.id,
               studyModel.linePopover == nil,
               studyModel.lineEditPopover == nil {
                let origin = floatingBarOrigin(for: selection.anchorRectInScrollViewport)
                let loopState = lineLoopMenuState?(selection.lineId)
                let canLoopLine = loopState?.isCurrentSingleLineLoop == true
                    || loopState?.canSingleLineLoop == true
                WordSelectionFloatingBar(
                    selection: selection,
                    quickSaveMessage: studyModel.quickSaveMessage,
                    compact: containerSize.width < 340,
                    isLineLooping: loopState?.isCurrentSingleLineLoop == true,
                    onOpenWordStudy: { studyModel.openWordStudy(from: selection) },
                    onQuickSave: { studyModel.quickSaveWord(from: selection) },
                    onOpenLineStudy: {
                        studyModel.openLineStudy(
                            document: document,
                            lineId: selection.lineId,
                            anchorRect: selection.anchorRectInScrollViewport
                        )
                    },
                    onToggleLineLoop: canLoopLine
                        ? { onToggleSingleLineLoop?(selection.lineId) }
                        : nil
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: SelectionFloatingBarSizeKey.self, value: proxy.size)
                    }
                }
                .onPreferenceChange(SelectionFloatingBarSizeKey.self) { size in
                    if size.width > 0, size.height > 0, size != barSize {
                        barSize = size
                    }
                }
                .offset(x: origin.x, y: origin.y)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
        .onAppear {
            if isPopoverOpen {
                onStudyPopoverPresentedChange(true)
            }
        }
        .onChange(of: document.revision) { _, _ in
            studyModel.reconcileLineStudyDocument(document)
        }
        .onChange(of: isPopoverOpen) { _, open in
            onStudyPopoverPresentedChange(open)
        }
        .onChange(of: studyModel.clearSelectionToken) { _, _ in
            onClearTextSelection?()
        }
        .onDisappear {
            if isPopoverOpen {
                onStudyPopoverPresentedChange(false)
            }
            studyModel.clearTransientOverlays(forDocumentId: document.id)
        }
    }

    private func floatingBarOrigin(for anchor: CGRect) -> CGPoint {
        let margin: CGFloat = 8
        let gap: CGFloat = 8
        let maxX = max(margin, containerSize.width - barSize.width - margin)
        let maxY = max(margin, containerSize.height - barSize.height - margin)

        let rawX = anchor.midX - barSize.width / 2
        let clampedX = min(max(margin, rawX), maxX)

        let aboveY = anchor.minY - barSize.height - gap
        let belowY = anchor.maxY + gap
        let rawY = aboveY >= margin ? aboveY : belowY
        let clampedY = min(max(margin, rawY), maxY)
        return CGPoint(x: clampedX, y: clampedY)
    }

    private func clampedAnchorRect(_ rect: CGRect?) -> CGRect {
        guard let rect, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(x: max(1, containerSize.width / 2), y: max(1, containerSize.height / 3), width: 1, height: 1)
        }
        let width = max(1, min(rect.width, containerSize.width))
        let height = max(1, min(rect.height, containerSize.height))
        let x = min(max(0, rect.minX), max(0, containerSize.width - width))
        let y = min(max(0, rect.minY), max(0, containerSize.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct SelectionFloatingBarSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 {
            value = next
        }
    }
}

private struct WordSelectionFloatingBar: View {
    let selection: LyricsWordSelection
    let quickSaveMessage: String?
    let compact: Bool
    let isLineLooping: Bool
    let onOpenWordStudy: () -> Void
    let onQuickSave: () -> Void
    let onOpenLineStudy: () -> Void
    let onToggleLineLoop: (() -> Void)?

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: compact ? 4 : 8) {
                barButton(
                    title: compact ? "🔍 释义" : "🔍 划词释义",
                    help: "查看本机离线词典释义，或点击触发 AI 结合歌词语境解析",
                    action: onOpenWordStudy
                )
                divider
                barButton(
                    title: compact ? "＋ 收录" : "＋ 收录生词",
                    help: "使用本机词典释义立即加入生词本并标注下划线",
                    action: onQuickSave
                )
                divider
                barButton(
                    title: compact ? "📖 整句" : "📖 解析所在句",
                    help: "查看或生成整句歌词的语法、唱法贴士与文化笔记",
                    action: onOpenLineStudy
                )
                if !compact, let onToggleLineLoop {
                    divider
                    barButton(
                        title: isLineLooping ? "⏹" : "🔁",
                        help: isLineLooping ? "退出当前句单句循环" : "单句循环这句歌词",
                        action: onToggleLineLoop
                    )
                }
            }
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.black.opacity(0.62), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)

            if let quickSaveMessage {
                Text(quickSaveMessage)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.teal.opacity(0.88), in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.22))
            .frame(width: 1, height: 14)
    }

    private func barButton(title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, compact ? 4 : 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
