import SwiftUI
import ShinAIProvider

/// 在线歌词搜索弹窗的关键词建议条：离线罗马音转假名、仅搜歌名、AI 推测原曲名。
struct NeteaseLyricsFetchSuggestionsView: View {
    @ObservedObject var model: NeteaseLyricsFetchModel
    var canSearch: Bool
    var onClose: () -> Void

    private var hasQueryTitle: Bool {
        !model.queryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasQueryArtist: Bool {
        !model.queryArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            actionRow
            if !model.aiSuggestions.isEmpty {
                aiSuggestionsRow
            }
            if let error = model.aiSuggestionError {
                aiErrorRow(error)
            }
        }
    }

    private var actionRow: some View {
        let kanaList = model.offlineKanaSuggestions
        return StudyFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(kanaList.enumerated()), id: \.element) { index, kana in
                Button {
                    Task {
                        await model.applySuggestionAndSearch(title: kana)
                    }
                } label: {
                    Text(index == 0 ? "假名：\(kana)" : kana)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canSearch)
            }

            if hasQueryArtist {
                Button {
                    Task { await model.searchTitleOnly() }
                } label: {
                    Text("仅搜歌名")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canSearch || !hasQueryTitle)
            }

            Button {
                model.requestAISearchSuggestions()
            } label: {
                HStack(spacing: 4) {
                    if model.isSuggestingWithAI {
                        ProgressView()
                            .controlSize(.mini)
                        Text("推测中…")
                    } else {
                        Image(systemName: "sparkles")
                        Text("AI 推测原曲名")
                    }
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isSuggestingWithAI || !canSearch || !hasQueryTitle)
        }
    }

    private var aiSuggestionsRow: some View {
        StudyFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(model.aiSuggestions) { suggestion in
                Button {
                    Task {
                        await model.applySuggestionAndSearch(
                            title: suggestion.title,
                            artist: suggestion.artist,
                            replaceArtist: false
                        )
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(suggestionTitle(suggestion))
                            .font(.caption)
                        if let reason = suggestion.reason, !reason.isEmpty {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canSearch)
            }
        }
    }

    private func aiErrorRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if model.aiSuggestionNeedsSettings {
                Button("前往设置") {
                    onClose()
                    NotificationCenter.default.post(
                        name: .shinSelectSettingsPage,
                        object: SettingsCategory.aiStudy
                    )
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private func suggestionTitle(_ suggestion: AISearchQuerySuggestion) -> String {
        if let artist = suggestion.artist, !artist.isEmpty {
            return "\(suggestion.title) · \(artist)"
        }
        return suggestion.title
    }
}
