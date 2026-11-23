import Foundation
import GRDB
import ShinAppleKit

// MARK: - 生词本数据库行映射与 CRUD（schema v4）

/// vocabularyEntry 行映射。examples 以 sortedKeys JSON 文本存入 examplesJSON。
struct VocabularyEntryRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "vocabularyEntry"

    var id: String
    var surface: String
    var lemma: String
    var reading: String?
    var language: String?
    var partOfSpeech: String?
    var generalMeaning: String
    var examplesJSON: String
    var userNote: String?
    // swiftlint:disable:next inclusive_language
    var mastery: String
    var createdAt: String
    var updatedAt: String

    init(from entry: VocabularyEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry.examples)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CorruptRowError(reason: "生词例句 JSON 不是合法 UTF-8")
        }
        self.id = entry.id.uuidString
        self.surface = entry.surface
        self.lemma = entry.lemma
        self.reading = entry.reading
        self.language = entry.language
        self.partOfSpeech = entry.partOfSpeech
        self.generalMeaning = entry.generalMeaning
        self.examplesJSON = json
        self.userNote = entry.userNote
        self.mastery = entry.mastery.rawValue
        self.createdAt = entry.createdAt
        self.updatedAt = entry.updatedAt
    }

    func vocabularyEntry() throws -> VocabularyEntry {
        guard let entryId = UUID(uuidString: id) else {
            throw CorruptRowError(reason: "vocabularyEntry.id 不是合法 UUID：\(id)")
        }
        // swiftlint:disable inclusive_language
        guard let parsedMastery = VocabularyMastery(rawValue: mastery) else {
            throw CorruptRowError(reason: "vocabularyEntry.mastery 非法：\(mastery)")
        }
        // swiftlint:enable inclusive_language
        guard let data = examplesJSON.data(using: .utf8) else {
            throw CorruptRowError(reason: "vocabularyEntry.examplesJSON 不是合法 UTF-8")
        }
        let examples = try JSONDecoder().decode([VocabularyExample].self, from: data)
        return VocabularyEntry(
            id: entryId,
            surface: surface,
            lemma: lemma,
            reading: reading,
            language: language,
            partOfSpeech: partOfSpeech,
            generalMeaning: generalMeaning,
            examples: examples,
            userNote: userNote,
            mastery: parsedMastery,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

/// vocabularyOccurrence 行映射。
struct VocabularyOccurrenceRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "vocabularyOccurrence"

    var id: String
    var entryId: String
    var lyricDocumentId: String?
    var lineId: String?
    var utf16Location: Int
    var utf16Length: Int
    var surfaceInLine: String
    var contextualMeaning: String
    var lineTextSnapshot: String
    var lineTranslationSnapshot: String?
    var startMsSnapshot: Int64?
    var trackKeyHint: String?
    var trackTitleHint: String?
    var artistHint: String?
    var createdAt: String

    init(from occurrence: VocabularyOccurrence) {
        self.id = occurrence.id.uuidString
        self.entryId = occurrence.entryId.uuidString
        self.lyricDocumentId = occurrence.lyricDocumentId?.uuidString
        self.lineId = occurrence.lineId?.uuidString
        self.utf16Location = occurrence.utf16Location
        self.utf16Length = occurrence.utf16Length
        self.surfaceInLine = occurrence.surfaceInLine
        self.contextualMeaning = occurrence.contextualMeaning
        self.lineTextSnapshot = occurrence.lineTextSnapshot
        self.lineTranslationSnapshot = occurrence.lineTranslationSnapshot
        self.startMsSnapshot = occurrence.startMsSnapshot
        self.trackKeyHint = occurrence.trackKeyHint
        self.trackTitleHint = occurrence.trackTitleHint
        self.artistHint = occurrence.artistHint
        self.createdAt = occurrence.createdAt
    }

    func vocabularyOccurrence() throws -> VocabularyOccurrence {
        guard let occurrenceId = UUID(uuidString: id) else {
            throw CorruptRowError(reason: "vocabularyOccurrence.id 不是合法 UUID：\(id)")
        }
        guard let parsedEntryId = UUID(uuidString: entryId) else {
            throw CorruptRowError(reason: "vocabularyOccurrence.entryId 不是合法 UUID：\(entryId)")
        }
        let parsedDocumentId: UUID?
        if let lyricDocumentId {
            guard let uuid = UUID(uuidString: lyricDocumentId) else {
                throw CorruptRowError(reason: "vocabularyOccurrence.lyricDocumentId 不是合法 UUID：\(lyricDocumentId)")
            }
            parsedDocumentId = uuid
        } else {
            parsedDocumentId = nil
        }
        let parsedLineId: UUID?
        if let lineId {
            guard let uuid = UUID(uuidString: lineId) else {
                throw CorruptRowError(reason: "vocabularyOccurrence.lineId 不是合法 UUID：\(lineId)")
            }
            parsedLineId = uuid
        } else {
            parsedLineId = nil
        }
        return VocabularyOccurrence(
            id: occurrenceId,
            entryId: parsedEntryId,
            lyricDocumentId: parsedDocumentId,
            lineId: parsedLineId,
            utf16Location: utf16Location,
            utf16Length: utf16Length,
            surfaceInLine: surfaceInLine,
            contextualMeaning: contextualMeaning,
            lineTextSnapshot: lineTextSnapshot,
            lineTranslationSnapshot: lineTranslationSnapshot,
            startMsSnapshot: startMsSnapshot,
            trackKeyHint: trackKeyHint,
            trackTitleHint: trackTitleHint,
            artistHint: artistHint,
            createdAt: createdAt
        )
    }
}

public extension GRDBLyricsStore {

    /// 列出全部生词词条（按 updatedAt 降序、id 升序）。
    func allVocabularyEntries() async throws -> [VocabularyEntry] {
        try await performRead { db in
            let rows = try VocabularyEntryRow.fetchAll(db)
            return try rows.map { try $0.vocabularyEntry() }.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    if let lhsDate = LyricTimestamp.date(from: lhs.updatedAt),
                       let rhsDate = LyricTimestamp.date(from: rhs.updatedAt),
                       lhsDate != rhsDate {
                        return lhsDate > rhsDate
                    }
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    /// 列出全部生词出处快照（按 id 升序，输出确定）。
    func allVocabularyOccurrences() async throws -> [VocabularyOccurrence] {
        try await performRead { db in
            let rows = try VocabularyOccurrenceRow.fetchAll(db)
            return try rows
                .map { try $0.vocabularyOccurrence() }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    /// 列出指定歌词文档关联的全部生词出处。
    func vocabularyOccurrences(forDocumentId documentId: UUID) async throws -> [VocabularyOccurrence] {
        try await performRead { db in
            let rows = try VocabularyOccurrenceRow
                .filter(Column("lyricDocumentId") == documentId.uuidString)
                .fetchAll(db)
            return try rows
                .map { try $0.vocabularyOccurrence() }
                .sorted { lhs, rhs in
                    let lhsTime = lhs.startMsSnapshot ?? Int64.max
                    let rhsTime = rhs.startMsSnapshot ?? Int64.max
                    if lhsTime != rhsTime { return lhsTime < rhsTime }
                    if lhs.utf16Location != rhs.utf16Location { return lhs.utf16Location < rhs.utf16Location }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
        }
    }

    /// 列出指定生词词条的全部语境出处。
    func vocabularyOccurrences(forEntryId entryId: UUID) async throws -> [VocabularyOccurrence] {
        try await performRead { db in
            let rows = try VocabularyOccurrenceRow
                .filter(Column("entryId") == entryId.uuidString)
                .fetchAll(db)
            return try rows
                .map { try $0.vocabularyOccurrence() }
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt {
                        if let lhsDate = LyricTimestamp.date(from: lhs.createdAt),
                           let rhsDate = LyricTimestamp.date(from: rhs.createdAt),
                           lhsDate != rhsDate {
                            return lhsDate > rhsDate
                        }
                        return lhs.createdAt > rhs.createdAt
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
        }
    }

    /// 单事务保存生词词条与可选出处：
    /// - 按 `entry.id` 或相同 `(normalizedLanguage, normalizedLemma)` 查找已有词条，
    ///   存在则合并更新非空字段并保留原 `id` 与 `createdAt`，否则插入新词条；
    /// - 若传入 `occurrence`，将其 `entryId` 对齐至最终词条 `id`，并按
    ///   `(entryId, lyricDocumentId, lineId, utf16Location, utf16Length)` 幂等更新或插入。
    func saveVocabulary(
        entry: VocabularyEntry,
        occurrence: VocabularyOccurrence? = nil
    ) async throws -> VocabularyEntry {
        try await performWrite { db in
            let savedEntry: VocabularyEntry
            if let existingRow = try Self.findMatchingEntryRow(for: entry, in: db) {
                let existing = try existingRow.vocabularyEntry()
                savedEntry = Self.mergeVocabularyEntry(existing: existing, incoming: entry)
            } else {
                savedEntry = entry
            }
            var entryRow = try VocabularyEntryRow(from: savedEntry)
            try entryRow.save(db)

            if var incomingOccurrence = occurrence {
                incomingOccurrence.entryId = savedEntry.id
                if let documentId = incomingOccurrence.lyricDocumentId,
                   try LyricDocumentRow.fetchOne(db, key: documentId.uuidString) == nil {
                    throw ShinAppleDataError.documentNotFound(documentId)
                }
                if let existingOccRow = try Self.findMatchingOccurrenceRow(for: incomingOccurrence, in: db) {
                    let existingOcc = try existingOccRow.vocabularyOccurrence()
                    let mergedOcc = Self.mergeVocabularyOccurrence(
                        existing: existingOcc, incoming: incomingOccurrence
                    )
                    var occRow = VocabularyOccurrenceRow(from: mergedOcc)
                    try occRow.save(db)
                } else {
                    var occRow = VocabularyOccurrenceRow(from: incomingOccurrence)
                    try occRow.save(db)
                }
            }
            return savedEntry
        }
    }

    /// 更新已存在的生词词条（用于修改掌握程度、笔记或释义等）。
    func updateVocabularyEntry(_ entry: VocabularyEntry) async throws {
        try await performWrite { db in
            guard try VocabularyEntryRow.fetchOne(db, key: entry.id.uuidString) != nil else {
                throw ShinAppleDataError.documentNotFound(entry.id)
            }
            var row = try VocabularyEntryRow(from: entry)
            try row.save(db)
        }
    }

    /// 删除生词词条（级联删除其全部出处）；不存在时为幂等 no-op。
    func deleteVocabularyEntry(id: UUID) async throws {
        try await performWrite { db in
            _ = try VocabularyEntryRow.deleteOne(db, key: id.uuidString)
        }
    }

    /// 删除单条生词出处（保留父词条）；不存在时为幂等 no-op。
    func deleteVocabularyOccurrence(id: UUID) async throws {
        try await performWrite { db in
            _ = try VocabularyOccurrenceRow.deleteOne(db, key: id.uuidString)
        }
    }
}

// MARK: - 内部归并、查询与备份读写助手

extension GRDBLyricsStore {

    static func fetchVocabularySnapshot(
        in db: Database
    ) throws -> (entries: [UUID: VocabularyEntry], occurrences: [UUID: VocabularyOccurrence]) {
        var entries: [UUID: VocabularyEntry] = [:]
        for row in try VocabularyEntryRow.fetchAll(db) {
            let entry = try row.vocabularyEntry()
            entries[entry.id] = entry
        }
        var occurrences: [UUID: VocabularyOccurrence] = [:]
        for row in try VocabularyOccurrenceRow.fetchAll(db) {
            let occurrence = try row.vocabularyOccurrence()
            occurrences[occurrence.id] = occurrence
        }
        return (entries, occurrences)
    }

    static func writeVocabularyBackup(
        entries: [VocabularyEntry],
        occurrences: [VocabularyOccurrence],
        in db: Database
    ) throws {
        for entry in entries {
            var entryRow = try VocabularyEntryRow(from: entry)
            try entryRow.save(db)
        }
        for occurrence in occurrences {
            guard try VocabularyEntryRow.fetchOne(db, key: occurrence.entryId.uuidString) != nil else {
                throw ShinAppleDataError.invalidBackup(
                    .wrongType(
                        path: "root.vocabularyOccurrences.entryId",
                        expected: "备份内存在的生词条 id（\(occurrence.entryId.uuidString)）"
                    )
                )
            }
            var sanitized = occurrence
            if let documentId = occurrence.lyricDocumentId,
               try LyricDocumentRow.fetchOne(db, key: documentId.uuidString) == nil {
                // 保护历史生词快照：若备份中引用了本地不存在的文档，置 nil 而非触发悬空外键失败。
                sanitized.lyricDocumentId = nil
            }
            var occurrenceRow = VocabularyOccurrenceRow(from: sanitized)
            try occurrenceRow.save(db)
        }
    }

    private static func findMatchingEntryRow(
        for entry: VocabularyEntry,
        in db: Database
    ) throws -> VocabularyEntryRow? {
        if let byId = try VocabularyEntryRow.fetchOne(db, key: entry.id.uuidString) {
            return byId
        }
        let targetLemma = normalizedLemma(entry.lemma, fallbackSurface: entry.surface)
        guard !targetLemma.isEmpty else { return nil }
        let targetLanguage = normalizedLanguage(entry.language)
        let rows = try VocabularyEntryRow
            .order(Column("createdAt").asc, Column("id").asc)
            .fetchAll(db)
        return rows.first { row in
            normalizedLanguage(row.language) == targetLanguage
                && normalizedLemma(row.lemma, fallbackSurface: row.surface) == targetLemma
        }
    }

    private static func findMatchingOccurrenceRow(
        for occurrence: VocabularyOccurrence,
        in db: Database
    ) throws -> VocabularyOccurrenceRow? {
        try VocabularyOccurrenceRow.fetchOne(
            db,
            sql: """
            SELECT * FROM vocabularyOccurrence
            WHERE entryId = ?
              AND lyricDocumentId IS ?
              AND lineId IS ?
              AND utf16Location = ?
              AND utf16Length = ?
            LIMIT 1
            """,
            arguments: [
                occurrence.entryId.uuidString,
                occurrence.lyricDocumentId?.uuidString,
                occurrence.lineId?.uuidString,
                occurrence.utf16Location,
                occurrence.utf16Length
            ]
        )
    }

    private static func mergeVocabularyEntry(
        existing: VocabularyEntry,
        incoming: VocabularyEntry
    ) -> VocabularyEntry {
        let matchedById = existing.id == incoming.id
        let surface = matchedById
            ? (nonEmpty(incoming.surface) ?? existing.surface)
            : (nonEmpty(existing.surface) ?? incoming.surface)
        let lemma = matchedById
            ? (nonEmpty(incoming.lemma) ?? existing.lemma)
            : (nonEmpty(existing.lemma) ?? incoming.lemma)
        let examples = existing.examples + incoming.examples.filter { !existing.examples.contains($0) }
        // swiftlint:disable inclusive_language
        let mergedMastery = higherMastery(existing.mastery, incoming.mastery)
        return VocabularyEntry(
            id: existing.id,
            surface: surface,
            lemma: lemma,
            reading: nonEmpty(incoming.reading) ?? existing.reading,
            language: nonEmpty(incoming.language) ?? existing.language,
            partOfSpeech: nonEmpty(incoming.partOfSpeech) ?? existing.partOfSpeech,
            generalMeaning: nonEmpty(incoming.generalMeaning) ?? existing.generalMeaning,
            examples: examples,
            userNote: nonEmpty(incoming.userNote) ?? existing.userNote,
            mastery: mergedMastery,
            createdAt: existing.createdAt,
            updatedAt: latestTimestamp(existing.updatedAt, incoming.updatedAt)
        )
        // swiftlint:enable inclusive_language
    }

    private static func mergeVocabularyOccurrence(
        existing: VocabularyOccurrence,
        incoming: VocabularyOccurrence
    ) -> VocabularyOccurrence {
        VocabularyOccurrence(
            id: existing.id,
            entryId: existing.entryId,
            lyricDocumentId: existing.lyricDocumentId,
            lineId: existing.lineId,
            utf16Location: existing.utf16Location,
            utf16Length: existing.utf16Length,
            surfaceInLine: nonEmpty(incoming.surfaceInLine) ?? existing.surfaceInLine,
            contextualMeaning: nonEmpty(incoming.contextualMeaning) ?? existing.contextualMeaning,
            lineTextSnapshot: nonEmpty(incoming.lineTextSnapshot) ?? existing.lineTextSnapshot,
            lineTranslationSnapshot: nonEmpty(incoming.lineTranslationSnapshot) ?? existing.lineTranslationSnapshot,
            startMsSnapshot: incoming.startMsSnapshot ?? existing.startMsSnapshot,
            trackKeyHint: nonEmpty(incoming.trackKeyHint) ?? existing.trackKeyHint,
            trackTitleHint: nonEmpty(incoming.trackTitleHint) ?? existing.trackTitleHint,
            artistHint: nonEmpty(incoming.artistHint) ?? existing.artistHint,
            createdAt: existing.createdAt
        )
    }

    private static func normalizedLanguage(_ language: String?) -> String {
        language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func normalizedLemma(_ lemma: String, fallbackSurface: String) -> String {
        let trimmedLemma = lemma.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLemma.isEmpty {
            return trimmedLemma.lowercased()
        }
        return fallbackSurface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    // swiftlint:disable inclusive_language
    private static func higherMastery(
        _ lhs: VocabularyMastery,
        _ rhs: VocabularyMastery
    ) -> VocabularyMastery {
        masteryRank(lhs) >= masteryRank(rhs) ? lhs : rhs
    }

    private static func masteryRank(_ mastery: VocabularyMastery) -> Int {
        switch mastery {
        case .learning: return 0
        case .reviewing: return 1
        case .mastered: return 2
        }
    }
    // swiftlint:enable inclusive_language

    private static func latestTimestamp(_ first: String, _ second: String) -> String {
        guard let firstDate = LyricTimestamp.date(from: first),
              let secondDate = LyricTimestamp.date(from: second) else {
            return second >= first ? second : first
        }
        return secondDate >= firstDate ? second : first
    }
}
