import Foundation

// 候选匹配打分。纯函数：输入本地曲目信息与网易云候选，
// 输出排序与置信分级。不访问网络、存储与 UI。
//
// 立场：网易云搜索只有文本信息，与 Music persistent ID 之间不存在强映射，
// 明确标为伴奏的候选先排除；打分只用于两件事——其余候选排序与
// 「高置信自动落位」的门槛判定。达不到门槛的一律进待确认队列，不猜。

/// 本地一侧的匹配查询（来自 Music 库或播放快照的曲目信息）。
public struct LyricsMatchQuery: Equatable, Sendable {
    public let title: String
    public let artist: String?
    public let durationMs: Int64?

    public init(title: String, artist: String? = nil, durationMs: Int64? = nil) {
        self.title = title
        self.artist = artist
        self.durationMs = durationMs
    }
}

/// 匹配置信分级。
public enum MatchConfidence: Int, Comparable, Equatable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .high: return "高度匹配"
        case .medium: return "疑似匹配"
        case .low: return "不确定"
        }
    }
}

/// 单个候选的打分结果。
public struct LyricsMatchScore: Equatable, Sendable {
    /// 归一化后歌名完全一致。
    public let titleExact: Bool
    /// 查询标题与候选标题经罗马音↔假名音译后完全一致。
    public let titleTransliterationMatch: Bool
    /// 查询标题或其假名音译与候选别名完全一致。
    public let titleAliasMatch: Bool
    /// 歌名归一化后一方包含另一方（且非完全一致）。
    public let titleContains: Bool
    /// 任一歌手归一化完全一致。
    public let artistExact: Bool
    /// 任一歌手经日语读音跨文字音译匹配。
    public let artistTransliterationMatch: Bool
    /// 任一歌手归一化后一方包含另一方。
    public let artistContains: Bool
    /// 双方时长都已知时的差值绝对值（毫秒）；任一未知为 nil。
    public let durationDeltaMs: Int64?
    /// 排序用总分（只影响展示顺序，不单独决定自动落位）。
    public let totalScore: Int
    /// 置信分级。
    public let confidence: MatchConfidence
    /// 自动落位门槛：歌名精确 + 歌手精确 +（若可比）时长差 ≤3s；
    /// 或标题/歌手任一经跨文字音译匹配（另一项精确或音译）+ 双方时长均已知且差值 ≤3s。
    public let isAutoHighEligible: Bool
}

/// 打分器。全部逻辑为纯函数，便于单测与复核。
public enum LyricsMatchRanker {

    /// 时长差阈值：≤3s 视为同一录音的常规元数据误差。
    public static let closeDurationToleranceMs: Int64 = 3_000
    /// 时长差在 3–8s 之间：疑似（单曲版 / MV 混音常见），给部分分。
    public static let looseDurationToleranceMs: Int64 = 8_000

    // 固定版本标签规则，只识别标题中的明确标记，不根据歌手或专辑推断。
    // 「伴奏」需独立成段；「伴奏版」可紧接歌名；英文按完整单词识别，可接「版」。
    private static let instrumentalVersionPatterns = [
        #"(?:^|[\s\p{P}])伴奏(?=$|[\s\p{P}])"#,
        #"伴奏\s*版(?=$|[\s\p{P}])"#,
        #"(?<![\p{L}\p{N}_])instrument(?:al)?(?:\s*版)?(?![\p{L}\p{N}_])"#
    ]

    /// 排除明确伴奏版本后按总分降序，同分按原始毫秒时长差升序（已知优先），
    /// 仍相同则保留搜索返回顺序。手动与自动获取共用此候选入口。
    public static func rank(candidates: [NeteaseSongCandidate], query: LyricsMatchQuery) -> [RankedCandidate] {
        candidates
            .filter { !isInstrumentalVersion($0.title) }
            .enumerated()
            .map { index, candidate in
                (
                    index: index,
                    ranked: RankedCandidate(
                        candidate: candidate,
                        score: score(candidate: candidate, query: query)
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.ranked.score.totalScore != rhs.ranked.score.totalScore {
                    return lhs.ranked.score.totalScore > rhs.ranked.score.totalScore
                }
                switch (lhs.ranked.score.durationDeltaMs, rhs.ranked.score.durationDeltaMs) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.index < rhs.index
                }
            }
            .map { $0.ranked }
    }

    private static func isInstrumentalVersion(_ title: String) -> Bool {
        let normalized = title.precomposedStringWithCompatibilityMapping.lowercased()
        return instrumentalVersionPatterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }

    /// 单个候选打分。
    public static func score(candidate: NeteaseSongCandidate, query: LyricsMatchQuery) -> LyricsMatchScore {
        let titleMatch = evaluateTitleMatch(candidate: candidate, query: query)
        let artistMatch = evaluateArtistMatch(candidate: candidate, query: query)

        var durationDelta: Int64?
        if let local = query.durationMs, let remote = candidate.durationMs {
            durationDelta = abs(local - remote)
        }

        var total = titleMatch.score + artistMatch.score
        if let delta = durationDelta {
            if delta <= closeDurationToleranceMs {
                total += 20
            } else if delta <= looseDurationToleranceMs {
                total += 10
            } else {
                total -= 10
            }
        }

        // 自动落位门槛：
        // 1) 歌名精确 + 歌手精确 + 时长不冲突（未知视为通过）；
        // 2) 标题或歌手任一使用跨文字音译匹配（另一项精确或音译）+ 双方时长均已知且差值 ≤3s。
        let durationConflicts = durationDelta.map { $0 > closeDurationToleranceMs } ?? false
        let durationCloseConfirmed = durationDelta.map { $0 <= closeDurationToleranceMs } ?? false
        let exactAutoEligible = titleMatch.exact && artistMatch.exact && !durationConflicts
        let transliterationAutoEligible = (titleMatch.exact || titleMatch.transliteration)
            && (artistMatch.exact || artistMatch.transliteration)
            && durationCloseConfirmed
        let autoEligible = exactAutoEligible || transliterationAutoEligible

        let confidence: MatchConfidence
        if autoEligible {
            confidence = .high
        } else if total >= 60 {
            confidence = .medium
        } else {
            confidence = .low
        }

        return LyricsMatchScore(
            titleExact: titleMatch.exact,
            titleTransliterationMatch: titleMatch.transliteration,
            titleAliasMatch: titleMatch.alias,
            titleContains: titleMatch.contains,
            artistExact: artistMatch.exact,
            artistTransliterationMatch: artistMatch.transliteration,
            artistContains: artistMatch.contains,
            durationDeltaMs: durationDelta,
            totalScore: total,
            confidence: confidence,
            isAutoHighEligible: autoEligible
        )
    }

    private struct ArtistMatchResult {
        let exact: Bool
        let transliteration: Bool
        let contains: Bool

        var score: Int {
            if exact || transliteration { return 30 }
            if contains { return 15 }
            return 0
        }
    }

    private static func evaluateArtistMatch(
        candidate: NeteaseSongCandidate,
        query: LyricsMatchQuery
    ) -> ArtistMatchResult {
        let queryArtists = artistTokens(query.artist)
        let candidateArtists = candidate.artists.flatMap(artistTokens)
        let artistExact = !queryArtists.isEmpty
            && !candidateArtists.isEmpty
            && !Set(queryArtists).isDisjoint(with: candidateArtists)

        let artistTransliteration: Bool
        if !artistExact {
            let queryRaw = rawArtistSegments(query.artist)
            let candidateRaw = candidate.artists.flatMap(rawArtistSegments)
            artistTransliteration = !queryRaw.isEmpty
                && !candidateRaw.isEmpty
                && queryRaw.contains { querySegment in
                    candidateRaw.contains { candidateSegment in
                        JapaneseRomajiTransliterator.artistsMatchByJapaneseReading(querySegment, candidateSegment)
                    }
                }
        } else {
            artistTransliteration = false
        }

        let artistContains = !artistExact
            && !queryArtists.isEmpty && !candidateArtists.isEmpty
            && queryArtists.contains { queryArtist in
                candidateArtists.contains { $0.contains(queryArtist) || queryArtist.contains($0) }
            }

        return ArtistMatchResult(
            exact: artistExact,
            transliteration: artistTransliteration,
            contains: artistContains
        )
    }

    private struct TitleMatchResult {
        let exact: Bool
        let transliteration: Bool
        let alias: Bool
        let contains: Bool

        var score: Int {
            if exact { return 50 }
            if transliteration { return 45 }
            if alias { return 40 }
            if contains { return 25 }
            return 0
        }
    }

    private static func evaluateTitleMatch(
        candidate: NeteaseSongCandidate,
        query: LyricsMatchQuery
    ) -> TitleMatchResult {
        let queryTitle = normalizeTitle(query.title)
        let candidateTitle = normalizeTitle(candidate.title)
        let titleExact = !queryTitle.isEmpty && queryTitle == candidateTitle
        let titleContains = !titleExact
            && !queryTitle.isEmpty && !candidateTitle.isEmpty
            && (queryTitle.contains(candidateTitle) || candidateTitle.contains(queryTitle))

        guard !titleExact else {
            return TitleMatchResult(exact: true, transliteration: false, alias: false, contains: false)
        }

        let queryKana = JapaneseRomajiTransliterator
            .toHiraganaIfLikelyRomaji(query.title)
            .map(normalizeTitle)
            .flatMap { $0.isEmpty ? nil : $0 }
        let candidateKana = JapaneseRomajiTransliterator
            .toHiraganaIfLikelyRomaji(candidate.title)
            .map(normalizeTitle)
            .flatMap { $0.isEmpty ? nil : $0 }

        let titleTransliteration = (!candidateTitle.isEmpty && queryKana == candidateTitle)
            || (!queryTitle.isEmpty && candidateKana == queryTitle)

        let titleAlias = candidate.aliases.contains { alias in
            let normalizedAlias = normalizeTitle(alias)
            guard !normalizedAlias.isEmpty else { return false }
            if normalizedAlias == queryTitle || queryKana == normalizedAlias {
                return true
            }
            if !queryTitle.isEmpty,
               let aliasKana = JapaneseRomajiTransliterator
                .toHiraganaIfLikelyRomaji(alias)
                .map(normalizeTitle),
               aliasKana == queryTitle {
                return true
            }
            return false
        }

        return TitleMatchResult(
            exact: false,
            transliteration: titleTransliteration,
            alias: titleAlias,
            contains: titleContains
        )
    }

    // MARK: - 归一化

    /// 歌名归一化：NFKC（全半角统一）→ 片假名转平假名 → 小写 → 去空白与标点。
    /// 保留括号内文本，让伴奏、翻唱、Live、语言版本等信息参与匹配。
    /// 这是打分专用归一化，不改写任何用户可见数据。
    public static func normalizeTitle(_ value: String) -> String {
        let nfkc = value.precomposedStringWithCompatibilityMapping
        let text = JapaneseRomajiTransliterator.katakanaToHiragana(nfkc).lowercased()
        return text.filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static let artistJoiners = [" feat. ", " ft. ", " feat ", " ft ", " with ", " vs. ", " vs "]

    /// 歌手归一化：NFKC + 片假名转平假名 + 小写后，按分隔符（`, / 、 + &`）与常见合作连接词
    /// （feat. / ft. / with / vs.，需前后空格的词形）切分为 token 集合，每段
    /// 再去空白与标点。「A feat. B」「A / B & C」→ {a, b, c}。
    public static func artistTokens(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        let nfkc = value.precomposedStringWithCompatibilityMapping
        let lowered = JapaneseRomajiTransliterator.katakanaToHiragana(nfkc).lowercased()
        var pieces = lowered.components(separatedBy: CharacterSet(charactersIn: ",/、+&"))
        for joiner in artistJoiners {
            pieces = pieces.flatMap { $0.components(separatedBy: joiner) }
        }
        return pieces
            .map { $0.filter { !$0.isWhitespace && !$0.isPunctuation } }
            .filter { !$0.isEmpty }
    }

    /// 保留大小写、词内空格与假名/汉字的歌手段切分，供跨文字日语读音分词使用。
    private static func rawArtistSegments(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        let nfkc = value.precomposedStringWithCompatibilityMapping
        var pieces = nfkc.components(separatedBy: CharacterSet(charactersIn: ",/、+&"))
        for joiner in artistJoiners {
            pieces = pieces.flatMap { splitCaseInsensitive($0, separator: joiner) }
        }
        return pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func splitCaseInsensitive(_ text: String, separator: String) -> [String] {
        var result: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: separator, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            result.append(String(text[searchStart..<range.lowerBound]))
            searchStart = range.upperBound
        }
        result.append(String(text[searchStart..<text.endIndex]))
        return result
    }
}

/// 打分后的候选（排序产物）。
public struct RankedCandidate: Equatable, Sendable, Identifiable {
    public let candidate: NeteaseSongCandidate
    public let score: LyricsMatchScore

    public var id: Int64 { candidate.songId }
}
