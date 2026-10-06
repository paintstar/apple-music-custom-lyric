import Foundation

// 候选匹配打分。纯函数：输入本地曲目信息与网易云候选，
// 输出排序与置信分级。不访问网络、存储与 UI。
//
// 立场：网易云搜索只有文本信息，与 Music persistent ID 之间不存在强映射，
// 所以打分只用于两件事——候选排序（永远给用户看完整候选）与
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
    /// 歌名归一化后一方包含另一方（且非完全一致）。
    public let titleContains: Bool
    /// 任一歌手归一化完全一致。
    public let artistExact: Bool
    /// 任一歌手归一化后一方包含另一方。
    public let artistContains: Bool
    /// 双方时长都已知时的差值绝对值（毫秒）；任一未知为 nil。
    public let durationDeltaMs: Int64?
    /// 排序用总分（只影响展示顺序，不单独决定自动落位）。
    public let totalScore: Int
    /// 置信分级。
    public let confidence: MatchConfidence
    /// 自动落位门槛：歌名精确 + 歌手精确 +（若可比）时长差 ≤3s。
    /// durationMs 任一未知时时长项按通过处理（文本双证已够，不硬卡）。
    public let isAutoHighEligible: Bool
}

/// 打分器。全部逻辑为纯函数，便于单测与复核。
public enum LyricsMatchRanker {

    /// 时长差阈值：≤3s 视为同一录音的常规元数据误差。
    public static let closeDurationToleranceMs: Int64 = 3_000
    /// 时长差在 3–8s 之间：疑似（单曲版 / MV 混音常见），给部分分。
    public static let looseDurationToleranceMs: Int64 = 8_000

    /// 对候选列表打分并按总分降序排序（同分保持网易云返回顺序，稳定）。
    public static func rank(candidates: [NeteaseSongCandidate], query: LyricsMatchQuery) -> [RankedCandidate] {
        candidates
            .map { candidate in
                RankedCandidate(
                    candidate: candidate,
                    score: score(candidate: candidate, query: query)
                )
            }
            .sorted { lhs, rhs in
                lhs.score.totalScore != rhs.score.totalScore
                    ? lhs.score.totalScore > rhs.score.totalScore
                    : lhs.candidate.songId < rhs.candidate.songId
            }
    }

    /// 单个候选打分。
    public static func score(candidate: NeteaseSongCandidate, query: LyricsMatchQuery) -> LyricsMatchScore {
        let queryTitle = normalizeTitle(query.title)
        let candidateTitle = normalizeTitle(candidate.title)
        let titleExact = !queryTitle.isEmpty && queryTitle == candidateTitle
        let titleContains = !titleExact
            && !queryTitle.isEmpty && !candidateTitle.isEmpty
            && (queryTitle.contains(candidateTitle) || candidateTitle.contains(queryTitle))

        let queryArtists = artistTokens(query.artist)
        let candidateArtists = candidate.artists.flatMap(artistTokens)
        let artistExact = !queryArtists.isEmpty
            && !candidateArtists.isEmpty
            && !Set(queryArtists).isDisjoint(with: candidateArtists)
        let artistContains = !artistExact
            && !queryArtists.isEmpty && !candidateArtists.isEmpty
            && queryArtists.contains { queryArtist in
                candidateArtists.contains { $0.contains(queryArtist) || queryArtist.contains($0) }
            }

        var durationDelta: Int64?
        if let local = query.durationMs, let remote = candidate.durationMs {
            durationDelta = abs(local - remote)
        }

        var total = 0
        total += titleExact ? 50 : 0
        total += titleContains ? 25 : 0
        total += artistExact ? 30 : 0
        total += artistContains ? 15 : 0
        if let delta = durationDelta {
            if delta <= closeDurationToleranceMs {
                total += 20
            } else if delta <= looseDurationToleranceMs {
                total += 10
            } else {
                total -= 10
            }
        }

        // 自动落位门槛：歌名精确 + 歌手精确 + 时长不冲突（未知视为通过）。
        let durationConflicts = durationDelta.map { $0 > closeDurationToleranceMs } ?? false
        let autoEligible = titleExact && artistExact && !durationConflicts

        let confidence: MatchConfidence
        if autoEligible {
            confidence = .high
        } else if total >= 60 {
            confidence = .medium
        } else {
            confidence = .low
        }

        return LyricsMatchScore(
            titleExact: titleExact,
            titleContains: titleContains,
            artistExact: artistExact,
            artistContains: artistContains,
            durationDeltaMs: durationDelta,
            totalScore: total,
            confidence: confidence,
            isAutoHighEligible: autoEligible
        )
    }

    // MARK: - 归一化

    /// 歌名归一化：NFKC（全半角统一）→ 小写 → 去所有括号块（(…) （…） […] 【…】
    /// ——「晴天 (Live)」「晴天(Live版)」都归到「晴天」→ 去空白与标点。
    /// 这是打分专用归一化，不改写任何用户可见数据。
    public static func normalizeTitle(_ value: String) -> String {
        var text = value.precomposedStringWithCompatibilityMapping.lowercased()
        for opener in ["(", "（", "[", "【"] {
            let closer = Self.closingBracket(for: opener)
            while let openRange = text.range(of: opener) {
                let after = text.index(after: openRange.lowerBound)
                if let closeRange = text[after...].range(of: closer) {
                    text.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                } else {
                    text.removeSubrange(openRange.lowerBound...)
                    break
                }
            }
        }
        return text.filter { !$0.isWhitespace && !isPunctuation($0) }
    }

    /// 歌手归一化：NFKC + 小写后，按分隔符（`, / 、 + &`）与常见合作连接词
    /// （feat. / ft. / with / vs.，需前后空格的词形）切分为 token 集合，每段
    /// 再去空白与标点。「A feat. B」「A / B & C」→ {a, b, c}。
    public static func artistTokens(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        let lowered = value.precomposedStringWithCompatibilityMapping.lowercased()
        var pieces = lowered.components(separatedBy: CharacterSet(charactersIn: ",/、+&"))
        for joiner in [" feat. ", " ft. ", " feat ", " ft ", " with ", " vs. ", " vs "] {
            pieces = pieces.flatMap { $0.components(separatedBy: joiner) }
        }
        return pieces
            .map { $0.filter { !$0.isWhitespace && !$0.isPunctuation } }
            .filter { !$0.isEmpty }
    }

    private static func closingBracket(for opener: String) -> String {
        switch opener {
        case "(": return ")"
        case "（": return "）"
        case "[": return "]"
        case "【": return "】"
        default: return ")"
        }
    }

    /// 只过滤标点符号（含全角），保留所有字母/数字/CJK。
    private static func isPunctuation(_ character: Character) -> Bool {
        character.isPunctuation
    }
}

/// 打分后的候选（排序产物）。
public struct RankedCandidate: Equatable, Sendable, Identifiable {
    public let candidate: NeteaseSongCandidate
    public let score: LyricsMatchScore

    public var id: Int64 { candidate.songId }
}
