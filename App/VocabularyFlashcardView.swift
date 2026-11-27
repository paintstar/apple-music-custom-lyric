import SwiftUI
import ShinAppleKit

/// 闪卡自测弹窗：结合歌曲原声例句进行记忆抽查与掌握度分级标记。
struct VocabularyFlashcardView: View {
    @ObservedObject var book: VocabularyBookModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerBar
            if let message = book.statusMessage {
                statusBanner(message)
            }
            if book.flashcardCompleted {
                completionSummary
            } else if let entry = book.currentFlashcardEntry {
                progressSection
                flashcardBody(for: entry)
                footerActions
            } else {
                emptyDeckView
            }
        }
        .padding(22)
        .frame(width: 560, height: 500)
        .modifier(VocabularyPlaybackAlert(book: book, source: .flashcard))
        .onChange(of: book.currentFlashcardEntry?.id) { _, entryId in
            book.cancelOccurrencePlaybackOutsideEntry(entryId, source: .flashcard)
        }
        .onDisappear {
            book.cancelOccurrencePlayback(source: .flashcard)
            book.clearStatus()
        }
    }

    private var headerBar: some View {
        HStack {
            Label("闪卡自测", systemImage: "rectangle.on.rectangle.angled")
                .font(.title3.weight(.semibold))
            Spacer()
            if !book.flashcardCompleted, !book.flashcardDeck.isEmpty {
                Text("第 \(min(book.flashcardIndex + 1, book.flashcardDeck.count)) / \(book.flashcardDeck.count) 张")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("关闭") {
                book.closeFlashcards()
                dismiss()
            }
        }
    }

    private var progressSection: some View {
        let total = max(1, book.flashcardDeck.count)
        let current = min(book.flashcardIndex + 1, total)
        return ProgressView(value: Double(current), total: Double(total))
            .tint(Color.appleMusicPink)
    }

    private func flashcardBody(for entry: VocabularyEntry) -> some View {
        let firstOccurrence = book.occurrences(for: entry.id).first
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                cardFrontSection(entry: entry, firstOccurrence: firstOccurrence)
                if book.isFlashcardRevealed {
                    Divider()
                    cardBackSection(entry: entry, firstOccurrence: firstOccurrence)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }

    private func cardFrontSection(
        entry: VocabularyEntry,
        firstOccurrence: VocabularyOccurrence?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.surface)
                    .font(.system(size: 30, weight: .bold))
                    .textSelection(.enabled)
                if let reading = VocabularyBookModel.nonEmptyTrimmed(entry.reading) {
                    Text(reading)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                VocabularyMasteryBadge(mastery: entry.mastery)
            }

            if let lemma = VocabularyBookModel.nonEmptyTrimmed(entry.lemma), lemma != entry.surface {
                Text("原型：\(lemma)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let occurrence = firstOccurrence {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Label(trackHintText(occurrence), systemImage: "music.note")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if let startMs = occurrence.startMsSnapshot {
                            Text("[\(VocabularyBookModel.formatTimestampMMSS(startMs))]")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.appleMusicPink)
                        }
                    }

                    Text(VocabularyTextHighlight.attributedLine(for: occurrence))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    Button {
                        book.playOccurrence(occurrence, source: .flashcard)
                    } label: {
                        if book.playingOccurrenceId == occurrence.id {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在定位播放……")
                            }
                        } else {
                            Label("听原句", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(book.playingOccurrenceId != nil)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func cardBackSection(
        entry: VocabularyEntry,
        firstOccurrence: VocabularyOccurrence?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let pos = VocabularyBookModel.nonEmptyTrimmed(entry.partOfSpeech) {
                Text(pos)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.teal.opacity(0.12), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("通用释义")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(
                    VocabularyBookModel.nonEmptyTrimmed(entry.generalMeaning)
                        ?? "暂未填写通用释义"
                )
                .font(.body)
                .foregroundStyle(
                    VocabularyBookModel.nonEmptyTrimmed(entry.generalMeaning) == nil
                        ? .secondary
                        : .primary
                )
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }

            if let contextual = VocabularyBookModel.nonEmptyTrimmed(firstOccurrence?.contextualMeaning) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("句中语境释义")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.teal)
                    Text(contextual)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            if let translation = VocabularyBookModel.nonEmptyTrimmed(firstOccurrence?.lineTranslationSnapshot) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("例句译文")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(translation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            if let note = VocabularyBookModel.nonEmptyTrimmed(entry.userNote) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("个人笔记")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private var footerActions: some View {
        if !book.isFlashcardRevealed {
            HStack {
                Spacer()
                Button {
                    book.revealFlashcard()
                } label: {
                    Text("显示释义")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appleMusicPink)
                .controlSize(.large)
                .keyboardShortcut(.space, modifiers: [])
                Spacer()
            }
        } else {
            HStack(spacing: 10) {
                gradeButton("还需巩固（学习中）", tint: .orange) {
                    book.gradeCurrentFlashcard(as: .learning)
                }
                gradeButton("再练练（复习中）", tint: .blue) {
                    book.gradeCurrentFlashcard(as: .reviewing)
                }
                gradeButton("已掌握", tint: .green, prominent: true) {
                    book.gradeCurrentFlashcard(as: .mastered)
                }
            }
        }
    }

    private func gradeButton(
        _ title: String,
        tint: Color,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(prominent ? tint : tint.opacity(0.75))
    }

    private var completionSummary: some View {
        let stats = book.flashcardStats
        return VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("太棒了！本轮闪卡自测已完成")
                .font(.title3.weight(.bold))
            Text("共复习 \(stats.reviewedCount) 个词条，掌握状态已实时同步到单词本。")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                statPill("仍需巩固", count: stats.learningCount, tint: .orange)
                statPill("继续复习", count: stats.reviewingCount, tint: .blue)
                statPill("已掌握", count: stats.masteredCount, tint: .green)
            }

            Spacer()

            HStack(spacing: 12) {
                Button("再来一轮") {
                    book.restartFlashcards()
                }
                .controlSize(.large)
                Button("完成") {
                    book.closeFlashcards()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appleMusicPink)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDeckView: some View {
        VStack(spacing: 10) {
            Text("当前没有可自测的词条。")
                .foregroundStyle(.secondary)
            Button("关闭") {
                book.closeFlashcards()
                dismiss()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statPill(_ title: String, count: Int, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func statusBanner(_ message: String) -> some View {
        let isWarning = book.statusTone == .warning
        let color: Color = isWarning ? .orange : .secondary
        return Label(message, systemImage: isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func trackHintText(_ occurrence: VocabularyOccurrence) -> String {
        VocabularyBookModel.trackAttributionText(for: occurrence, fallback: "歌曲原声例句")
    }
}
