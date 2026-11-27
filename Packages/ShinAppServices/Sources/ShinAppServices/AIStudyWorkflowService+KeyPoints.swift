import Foundation
import ShinAIProvider
import ShinAppleData
import ShinAppleKit

// MARK: - AI 学习工作流：全曲重点词汇提炼与批量入库

extension AIStudyWorkflowService {

    /// 用户显式触发的全曲重点词汇提炼：
    /// 过滤空白行后送交 `aiClient.extractKeyStudyPoints`，处理 `Task.isCancelled` 与 `AIProviderError` 映射。
    public func extractKeyStudyPoints(
        for document: LyricDocument,
        songTitle: String? = nil,
        artist: String? = nil
    ) async throws -> [AIKeyStudyPoint] {
        _ = (songTitle, artist)
        if Task.isCancelled {
            throw AIStudyWorkflowError.cancelled
        }

        let nonEmptyLines = Self.nonEmptyLines(in: document)
        guard !nonEmptyLines.isEmpty else {
            throw AIStudyWorkflowError.emptyLyrics
        }

        let configuration = configurationProvider()
        let apiKey = try resolveAPIKey(for: configuration.preset)

        do {
            let points = try await aiClient.extractKeyStudyPoints(
                from: nonEmptyLines,
                sourceLanguage: document.sourceLanguage,
                configuration: configuration,
                apiKey: apiKey
            )
            if Task.isCancelled {
                throw AIStudyWorkflowError.cancelled
            }
            return points
        } catch {
            throw Self.mapAIError(error)
        }
    }

    /// 将用户勾选的 `AIKeyStudyPoint` 批量保存到 `store`：
    /// - 按 `point.lineId` 从 `document.lines` 查找原文快照、译文快照与 `startMsSnapshot`；
    /// - 在行文本内查找 `surface` 对应的 `utf16Location` / `utf16Length`（若未命中则置 `0, 0`）；
    /// - 构建 `VocabularyEntry` 与 `VocabularyOccurrence` 调用 `store.saveVocabulary`，返回成功保存条数。
    public func saveKeyStudyPoints(
        _ points: [AIKeyStudyPoint],
        in document: LyricDocument,
        trackKeyHint: String?,
        trackTitleHint: String?,
        artistHint: String?
    ) async throws -> Int {
        if Task.isCancelled {
            throw AIStudyWorkflowError.cancelled
        }
        guard !points.isEmpty else { return 0 }

        let context = VocabularyBatchContext(
            document: document,
            preferredLanguage: Self.normalizedNonEmpty(configurationProvider().preferredTargetLanguage),
            trackKeyHint: Self.normalizedNonEmpty(trackKeyHint),
            trackTitleHint: Self.normalizedNonEmpty(trackTitleHint),
            artistHint: Self.normalizedNonEmpty(artistHint)
        )

        var savedCount = 0
        for point in points {
            if Task.isCancelled {
                throw AIStudyWorkflowError.cancelled
            }
            guard let payload = Self.vocabularyPayload(for: point, context: context) else {
                continue
            }
            do {
                _ = try await store.saveVocabulary(entry: payload.entry, occurrence: payload.occurrence)
                savedCount += 1
            } catch {
                throw Self.mapStoreError(error, expectedRevision: document.revision)
            }
        }
        return savedCount
    }
}

// MARK: - 内部辅助

private extension AIStudyWorkflowService {

    struct VocabularyBatchContext {
        let documentId: UUID
        let documentLanguage: String?
        let preferredLanguage: String?
        let trackKeyHint: String?
        let trackTitleHint: String?
        let artistHint: String?
        let linesById: [UUID: LyricLine]

        init(
            document: LyricDocument,
            preferredLanguage: String?,
            trackKeyHint: String?,
            trackTitleHint: String?,
            artistHint: String?
        ) {
            self.documentId = document.id
            self.documentLanguage = AIStudyWorkflowService.normalizedNonEmpty(document.sourceLanguage)
            self.preferredLanguage = preferredLanguage
            self.trackKeyHint = trackKeyHint
            self.trackTitleHint = trackTitleHint
            self.artistHint = artistHint
            self.linesById = Dictionary(
                document.lines.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    static func vocabularyPayload(
        for point: AIKeyStudyPoint,
        context: VocabularyBatchContext
    ) -> (entry: VocabularyEntry, occurrence: VocabularyOccurrence)? {
        let cleanSurface = point.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSurface.isEmpty else { return nil }

        let trimmedLemma = point.lemma.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLemma = trimmedLemma.isEmpty ? cleanSurface : trimmedLemma
        let matchedLine = point.lineId.flatMap { context.linesById[$0] }
        let lineText = matchedLine?.text ?? ""
        let match = utf16Match(of: cleanSurface, in: lineText)
        let translationSnapshot = matchedLine.flatMap {
            resolvedTranslationSnapshot(for: $0, preferredLanguage: context.preferredLanguage)
        }

        let entry = VocabularyEntry(
            surface: cleanSurface,
            lemma: cleanLemma,
            reading: normalizedNonEmpty(point.reading),
            language: context.documentLanguage,
            partOfSpeech: normalizedNonEmpty(point.partOfSpeech),
            generalMeaning: point.generalMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let occurrence = VocabularyOccurrence(
            entryId: entry.id,
            lyricDocumentId: context.documentId,
            lineId: matchedLine?.id,
            utf16Location: match.location,
            utf16Length: match.length,
            surfaceInLine: match.surfaceInLine,
            contextualMeaning: point.contextualMeaning.trimmingCharacters(in: .whitespacesAndNewlines),
            lineTextSnapshot: lineText,
            lineTranslationSnapshot: translationSnapshot,
            startMsSnapshot: matchedLine?.startMs,
            trackKeyHint: context.trackKeyHint,
            trackTitleHint: context.trackTitleHint,
            artistHint: context.artistHint
        )
        return (entry, occurrence)
    }

    struct UTF16SurfaceMatch {
        let location: Int
        let length: Int
        let surfaceInLine: String
    }

    static func utf16Match(of surface: String, in lineText: String) -> UTF16SurfaceMatch {
        guard !surface.isEmpty, !lineText.isEmpty else {
            return UTF16SurfaceMatch(location: 0, length: 0, surfaceInLine: surface)
        }
        if let range = lineText.range(of: surface)
            ?? lineText.range(of: surface, options: [.caseInsensitive]) {
            let nsRange = NSRange(range, in: lineText)
            if nsRange.location != NSNotFound {
                return UTF16SurfaceMatch(
                    location: nsRange.location,
                    length: nsRange.length,
                    surfaceInLine: String(lineText[range])
                )
            }
        }
        return UTF16SurfaceMatch(location: 0, length: 0, surfaceInLine: surface)
    }

    static func resolvedTranslationSnapshot(
        for line: LyricLine,
        preferredLanguage: String?
    ) -> String? {
        if let preferredLanguage,
           let preferred = normalizedNonEmpty(line.translations[preferredLanguage]?.text) {
            return preferred
        }
        if let defaultChinese = normalizedNonEmpty(line.translations["zh-Hans"]?.text) {
            return defaultChinese
        }
        for key in line.translations.keys.sorted() {
            if let fallback = normalizedNonEmpty(line.translations[key]?.text) {
                return fallback
            }
        }
        return nil
    }
}
