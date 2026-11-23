import Foundation
import ShinAppleData
import ShinAppleKit
import ShinAppServices
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let shinVocabularyDidChange = Notification.Name("shin.vocabularyDidChange")
}

/// 单词本导出文本封装（UTF-8，用于 `.fileExporter`）。
struct VocabularyTextDocument: FileDocument {
    static let markdownType = UTType(filenameExtension: "md") ?? .plainText
    static var writableContentTypes: [UTType] {
        [.tabSeparatedText, .commaSeparatedText, markdownType, .plainText]
    }
    static var readableContentTypes: [UTType] { writableContentTypes }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(
            data: configuration.file.regularFileContents ?? Data(),
            encoding: .utf8
        ) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct VocabularyBookPendingExport {
    let format: VocabularyExportFormat
    let document: VocabularyTextDocument
    let defaultFilename: String
    let contentType: UTType
}

// swiftlint:disable inclusive_language
struct VocabularyFlashcardStats: Equatable {
    var reviewedCount = 0
    var learningCount = 0
    var reviewingCount = 0
    var masteredCount = 0
}
// swiftlint:enable inclusive_language

enum VocabularyBookStatusTone: Equatable {
    case info
    case success
    case warning
}

// MARK: - 闪卡自测、导出与语言映射扩展

// swiftlint:disable inclusive_language
@MainActor
extension VocabularyBookModel {
    private static let languageNames: [String: String] = [
        "ja": "日语",
        "en": "英语",
        "ko": "韩语",
        "zh": "中文",
        "zh-hans": "中文",
        "zh-hant": "中文",
        "fr": "法语",
        "de": "德语",
        "es": "西班牙语",
        "it": "意大利语",
        "pt": "葡萄牙语",
        "ru": "俄语"
    ]

    @discardableResult
    func prepareExport(format: VocabularyExportFormat) -> VocabularyTextDocument {
        let text = VocabularyExportService.export(
            entries: filteredEntries,
            occurrencesByEntryId: occurrencesByEntryId,
            format: format
        )
        let document = VocabularyTextDocument(text: text)
        pendingExport = VocabularyBookPendingExport(
            format: format,
            document: document,
            defaultFilename: Self.exportFilename(for: format),
            contentType: Self.contentType(for: format)
        )
        return document
    }

    func startFlashcards() {
        let source = filteredEntries
        guard !source.isEmpty else { return }
        resetFlashcardSession(from: source)
    }

    func restartFlashcards() {
        guard !flashcardDeck.isEmpty else {
            isFlashcardPresented = false
            return
        }
        let refreshed = flashcardDeck.map { old in
            entries.first(where: { $0.id == old.id }) ?? old
        }
        resetFlashcardSession(from: refreshed)
    }

    private func resetFlashcardSession(from source: [VocabularyEntry]) {
        flashcardDeck = source.sorted { lhs, rhs in
            Self.masterySortOrder(lhs.mastery) < Self.masterySortOrder(rhs.mastery)
        }
        flashcardIndex = 0
        isFlashcardRevealed = false
        flashcardCompleted = false
        flashcardStats = VocabularyFlashcardStats()
        isFlashcardPresented = true
    }

    func revealFlashcard() {
        guard !flashcardCompleted, currentFlashcardEntry != nil else { return }
        isFlashcardRevealed = true
    }

    func gradeCurrentFlashcard(as mastery: VocabularyMastery) {
        guard let entry = currentFlashcardEntry else { return }
        updateMastery(mastery, for: entry)
        flashcardStats.reviewedCount += 1
        switch mastery {
        case .learning: flashcardStats.learningCount += 1
        case .reviewing: flashcardStats.reviewingCount += 1
        case .mastered: flashcardStats.masteredCount += 1
        }
        if flashcardIndex + 1 < flashcardDeck.count {
            flashcardIndex += 1
            isFlashcardRevealed = false
        } else {
            flashcardIndex = flashcardDeck.count
            isFlashcardRevealed = false
            flashcardCompleted = true
        }
    }

    static func languageDisplayName(_ code: String?) -> String? {
        guard let normalized = normalizedLanguageCode(code) else { return nil }
        return languageNames[normalized] ?? normalized.uppercased()
    }

    static func formatTimestampMMSS(_ ms: Int64) -> String {
        let totalSeconds = max(0, ms) / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let minuteText = minutes < 10 ? "0\(minutes)" : "\(minutes)"
        let secondText = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        return "\(minuteText):\(secondText)"
    }

    static func normalizedLanguageCode(_ code: String?) -> String? {
        nonEmptyTrimmed(code)?.lowercased()
    }

    static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func trackAttributionText(
        for occurrence: VocabularyOccurrence,
        fallback: String
    ) -> String {
        let title = nonEmptyTrimmed(occurrence.trackTitleHint)
        let artist = nonEmptyTrimmed(occurrence.artistHint)
        switch (title, artist) {
        case let (title?, artist?): return "\(title) — \(artist)"
        case let (title?, nil): return title
        case let (nil, artist?): return artist
        case (nil, nil): return fallback
        }
    }

    private static func masterySortOrder(_ mastery: VocabularyMastery) -> Int {
        switch mastery {
        case .learning: return 0
        case .reviewing: return 1
        case .mastered: return 2
        }
    }

    private static func exportFilename(for format: VocabularyExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        formatter.timeZone = TimeZone.current
        return "ShinApple-单词本-\(formatter.string(from: Date())).\(format.fileExtension)"
    }

    private static func contentType(for format: VocabularyExportFormat) -> UTType {
        switch format {
        case .ankiTSV: return .tabSeparatedText
        case .csv: return .commaSeparatedText
        case .markdown: return VocabularyTextDocument.markdownType
        }
    }
}
// swiftlint:enable inclusive_language
