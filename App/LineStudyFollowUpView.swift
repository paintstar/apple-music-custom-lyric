import SwiftUI

struct LineStudyFollowUpView: View {
    let studyModel: LyricsStudyModel
    let state: LinePopoverState
    let canUseAI: Bool
    @Binding var isOpen: Bool
    let onOpenSettings: () -> Void
    let onAddToDraft: () -> Void
    @FocusState private var isQuestionFocused: Bool

    private var questionBinding: Binding<String> {
        Binding(
            get: { state.questionDraft },
            set: { question in
                guard var current = studyModel.linePopover, current.id == state.id,
                      !current.isAskingFollowUp else { return }
                current.questionDraft = question
                studyModel.linePopover = current
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isOpen {
                Label("继续问这句", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.headline)
                ForEach(state.followUps) { item in
                    followUpAnswer(item)
                        .id(item.id)
                }
                TextField("输入关于本句的问题", text: questionBinding, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .focused($isQuestionFocused)
                    .disabled(state.isAskingFollowUp)
                if let error = state.followUpErrorMessage {
                    StudyErrorLabel(message: error)
                }
                HStack {
                    if state.isAskingFollowUp {
                        ProgressView().controlSize(.small)
                        Text("正在回答…").font(.caption).foregroundStyle(.secondary)
                    } else if !canUseAI {
                        Button("前往设置配置 AI…", action: onOpenSettings)
                            .buttonStyle(.link)
                    }
                    Spacer()
                    Button("发送") {
                        isQuestionFocused = false
                        studyModel.submitLineFollowUp()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canUseAI || state.isAskingFollowUp || StudyTextHelpers.nonEmpty(state.questionDraft) == nil)
                }
            } else {
                Button {
                    isOpen = true
                    isQuestionFocused = true
                } label: {
                    Label("继续问这句", systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func followUpAnswer(_ item: LineFollowUpItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.turn.question)
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.turn.answer)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(item.isInNoteDraft ? "已加入笔记草稿" : "加入本句笔记草稿") {
                studyModel.addFollowUpToLineNote(id: item.id)
                onAddToDraft()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(item.isInNoteDraft || state.isSavingNote)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
