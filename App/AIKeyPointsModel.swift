import Foundation
import ShinAIProvider
import ShinAppleData
import ShinAppleKit
import ShinAppServices

/// AI 重点词汇预习卡的候选可勾选词条。
struct SelectableKeyPoint: Identifiable, Equatable {
    let point: AIKeyStudyPoint
    let lineTextExcerpt: String
    var isSelected: Bool

    var id: UUID { point.id }
}

/// AI 提炼本曲重点词汇预习卡状态机。
@MainActor
final class AIKeyPointsModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case ready([SelectableKeyPoint])
        case saving
        case saved(count: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var loadingStartedAt: Date?
    @Published private(set) var configuredServiceSummary = ""
    @Published private(set) var missingKeyWarning: String?

    let document: LyricDocument
    let songTitle: String?
    let artist: String?
    let trackKeyHint: String?
    let isMock: Bool

    private let workflowService: AIStudyWorkflowService
    private let settingsStore: AIServiceSettingsStore
    private let credentialStore: any AICredentialStoring
    private var onVocabularyChanged: (() -> Void)?
    private var generation = 0
    private var currentTask: Task<Void, Never>?
    private let lineTextsById: [UUID: String]

    init(
        store: GRDBLyricsStore,
        document: LyricDocument,
        songTitle: String?,
        artist: String?,
        trackKeyHint: String?,
        isMock: Bool,
        aiClient: (any AIStudyProviding)? = nil,
        settingsStore: AIServiceSettingsStore = AIServiceSettingsStore(),
        credentialStore: (any AICredentialStoring)? = nil,
        onVocabularyChanged: (() -> Void)? = nil
    ) {
        self.document = document
        self.songTitle = songTitle
        self.artist = artist
        self.trackKeyHint = trackKeyHint
        self.isMock = isMock
        self.settingsStore = settingsStore
        self.onVocabularyChanged = onVocabularyChanged
        self.lineTextsById = Dictionary(
            document.lines.map { ($0.id, $0.text) },
            uniquingKeysWith: { first, _ in first }
        )

        let resolvedCredentials: any AICredentialStoring = credentialStore
            ?? (isMock ? InMemoryAICredentialStore() : SystemKeychainCredentialStore())
        self.credentialStore = resolvedCredentials
        let resolvedClient: any AIStudyProviding = aiClient
            ?? (isMock ? MockKeyPointsClient() : OpenAICompatibleClient(credentialStore: resolvedCredentials))

        self.workflowService = AIStudyWorkflowService(
            store: store,
            aiClient: resolvedClient,
            configurationProvider: { settingsStore.load() },
            apiKeyProvider: {
                guard !isMock else { return nil }
                let config = settingsStore.load()
                return try? resolvedCredentials.apiKey(for: config.preset)
            }
        )
        refreshServiceStatus()
    }

    var nonEmptyLineCount: Int {
        document.lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    var items: [SelectableKeyPoint] {
        if case let .ready(list) = phase { return list }
        return []
    }

    var selectedCount: Int {
        items.filter(\.isSelected).count
    }

    var isSaving: Bool {
        if case .saving = phase { return true }
        return false
    }

    var allSelected: Bool {
        !items.isEmpty && items.allSatisfy(\.isSelected)
    }

    func refreshServiceStatus() {
        if isMock {
            configuredServiceSummary = "模拟模式 · 本地示例提炼（不发送网络请求）"
            missingKeyWarning = nil
            return
        }
        let config = settingsStore.load()
        let trimmedModel = config.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        configuredServiceSummary = "\(config.preset.displayName) · \(trimmedModel.isEmpty ? "未填写模型" : trimmedModel)"
        guard config.preset.requiresAPIKey else {
            missingKeyWarning = nil
            return
        }
        do {
            let key = try credentialStore.apiKey(for: config.preset)
            missingKeyWarning = key == nil
                ? "尚未配置「\(config.preset.displayName)」的 API Key，请前往「设置 → AI 学习服务」保存密钥。"
                : nil
        } catch {
            missingKeyWarning = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func startIfIdle() {
        guard case .idle = phase else { return }
        extract()
    }

    func extract() {
        refreshServiceStatus()
        guard nonEmptyLineCount > 0 else {
            phase = .failed(AIStudyWorkflowError.emptyLyrics.message)
            return
        }
        currentTask?.cancel()
        generation += 1
        let expectedGeneration = generation
        loadingStartedAt = Date()
        phase = .loading

        let service = workflowService
        let sourceDocument = document
        let title = songTitle
        let artistName = artist
        currentTask = Task { [weak self] in
            do {
                let points = try await service.extractKeyStudyPoints(
                    for: sourceDocument,
                    songTitle: title,
                    artist: artistName
                )
                guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
                self.currentTask = nil
                self.loadingStartedAt = nil
                self.phase = .ready(points.map { point in
                    let excerpt = point.lineId.flatMap { self.lineTextsById[$0] } ?? ""
                    return SelectableKeyPoint(
                        point: point,
                        lineTextExcerpt: excerpt.trimmingCharacters(in: .whitespacesAndNewlines),
                        isSelected: true
                    )
                })
            } catch is CancellationError {
                self?.finishCancelled(expectedGeneration: expectedGeneration, fallback: .idle)
            } catch let error as AIStudyWorkflowError where error == .cancelled {
                self?.finishCancelled(expectedGeneration: expectedGeneration, fallback: .idle)
            } catch {
                guard let self, self.generation == expectedGeneration else { return }
                self.currentTask = nil
                self.loadingStartedAt = nil
                self.phase = .failed(Self.describeError(error))
            }
        }
    }

    func cancelExtraction() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
        loadingStartedAt = nil
        if case .loading = phase {
            phase = .idle
        }
    }

    func setSelected(_ selected: Bool, for id: UUID) {
        guard case var .ready(list) = phase,
              let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].isSelected = selected
        phase = .ready(list)
    }

    func selectAll() {
        guard case var .ready(list) = phase else { return }
        for index in list.indices { list[index].isSelected = true }
        phase = .ready(list)
    }

    func deselectAll() {
        guard case var .ready(list) = phase else { return }
        for index in list.indices { list[index].isSelected = false }
        phase = .ready(list)
    }

    func saveSelected() {
        guard case let .ready(list) = phase else { return }
        let chosenPoints = list.filter(\.isSelected).map(\.point)
        guard !chosenPoints.isEmpty else { return }

        currentTask?.cancel()
        generation += 1
        let expectedGeneration = generation
        phase = .saving

        let service = workflowService
        let doc = document
        let trackKey = trackKeyHint
        let title = songTitle
        let artistName = artist
        currentTask = Task { [weak self] in
            do {
                let savedCount = try await service.saveKeyStudyPoints(
                    chosenPoints,
                    in: doc,
                    trackKeyHint: trackKey,
                    trackTitleHint: title,
                    artistHint: artistName
                )
                guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
                self.currentTask = nil
                self.phase = .saved(count: savedCount)
                self.onVocabularyChanged?()
            } catch is CancellationError {
                self?.finishCancelled(expectedGeneration: expectedGeneration, fallback: .ready(list))
            } catch let error as AIStudyWorkflowError where error == .cancelled {
                self?.finishCancelled(expectedGeneration: expectedGeneration, fallback: .ready(list))
            } catch {
                guard let self, self.generation == expectedGeneration else { return }
                self.currentTask = nil
                self.phase = .failed(Self.describeError(error))
            }
        }
    }

    func invalidate() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
        loadingStartedAt = nil
        onVocabularyChanged = nil
    }

    private func finishCancelled(expectedGeneration: Int, fallback: Phase) {
        guard generation == expectedGeneration else { return }
        currentTask = nil
        loadingStartedAt = nil
        phase = fallback
    }

    private static func describeError(_ error: Error) -> String {
        if let workflowError = error as? AIStudyWorkflowError {
            return workflowError.message
        }
        return ErrorText.describe(error)
    }
}

/// 模拟模式下的重点词汇提炼客户端：从当前非空歌词摘取词段并附典型学习释义，绝不联网。
private final class MockKeyPointsClient: AIStudyProviding, Sendable {
    func testConnection(
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AIConnectionTestResult {
        AIConnectionTestResult(latencyMs: 1, model: "mock-study", replyPreview: "连接正常")
    }

    func explainWord(
        _ word: String,
        inLine lineText: String,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AIWordExplanation {
        AIWordExplanation(surface: word, lemma: word, contextualMeaning: "模拟语境释义", generalMeaning: "模拟通用释义")
    }

    func explainLine(
        _ lineText: String,
        context: AILineContext,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AILineExplanation {
        AILineExplanation(grammarSummary: "模拟句法要点")
    }

    func generatePronunciations(
        for lines: [LyricLine],
        style: PronunciationStyle,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AIPronunciationLineItem] { [] }

    func generateTranslations(
        for lines: [LyricLine],
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AITranslationLineItem] { [] }

    func extractKeyStudyPoints(
        from lines: [LyricLine],
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AIKeyStudyPoint] {
        try await Task.sleep(for: .milliseconds(160))
        let isJapanese = Self.prefersJapanese(lines: lines, sourceLanguage: sourceLanguage)
        var results: [AIKeyStudyPoint] = []
        var seenSurfaces = Set<String>()

        for line in lines where results.count < 5 {
            let candidates = Self.candidateTokens(in: line.text, isJapanese: isJapanese)
            for token in candidates where seenSurfaces.insert(token.lowercased()).inserted {
                results.append(Self.makePoint(
                    token: token,
                    line: line,
                    index: results.count,
                    isJapanese: isJapanese
                ))
                break
            }
        }

        if results.count < 4, let firstLine = lines.first {
            for fallback in Self.fallbackSamples(isJapanese: isJapanese) where results.count < 4 {
                guard seenSurfaces.insert(fallback.surface.lowercased()).inserted else { continue }
                results.append(AIKeyStudyPoint(
                    lineId: firstLine.id,
                    surface: fallback.surface,
                    lemma: fallback.lemma,
                    reading: fallback.reading,
                    partOfSpeech: fallback.pos,
                    contextualMeaning: fallback.contextual,
                    generalMeaning: fallback.general
                ))
            }
        }
        return results
    }

    private static func prefersJapanese(lines: [LyricLine], sourceLanguage: String?) -> Bool {
        if let lang = sourceLanguage?.lowercased(), lang.hasPrefix("ja") { return true }
        return lines.prefix(6).contains { line in
            line.text.unicodeScalars.contains { scalar in
                (0x3040...0x309F).contains(scalar.value)
                    || (0x30A0...0x30FF).contains(scalar.value)
                    || (0x4E00...0x9FFF).contains(scalar.value)
            }
        }
    }

    private static func candidateTokens(in text: String, isJapanese: Bool) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if !isJapanese {
            let parts = trimmed
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { $0.count >= 3 }
            if !parts.isEmpty { return parts }
        }
        let segments = trimmed
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { $0.count >= 2 }
        var picked: [String] = []
        for segment in segments {
            if segment.count <= 4 {
                picked.append(segment)
            } else {
                picked.append(String(segment.prefix(3)))
            }
        }
        return picked
    }

    private static func makePoint(
        token: String,
        line: LyricLine,
        index: Int,
        isJapanese: Bool
    ) -> AIKeyStudyPoint {
        let posList = ["名词", "动词", "形容词", "副词 / 短语"]
        let pos = posList[index % posList.count]
        let snippet = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortLine = snippet.count > 18 ? String(snippet.prefix(18)) + "…" : snippet
        if isJapanese {
            return AIKeyStudyPoint(
                lineId: line.id,
                surface: token,
                lemma: token,
                reading: "もぎよみ（模拟）",
                partOfSpeech: pos,
                contextualMeaning: "在「\(shortLine)」中承接全句核心意象与语感（模拟提炼）。",
                generalMeaning: "表示「\(token)」在歌词与日常语境下的核心语义（模拟）。"
            )
        }
        return AIKeyStudyPoint(
            lineId: line.id,
            surface: token,
            lemma: token.lowercased(),
            reading: "/ˈmɒk/",
            partOfSpeech: pos,
            contextualMeaning: "In \"\(shortLine)\", conveys key lyrical imagery (mock).",
            generalMeaning: "表示「\(token)」在英语日常与抒情表达中的常见含义（模拟）。"
        )
    }

    private struct FallbackSample {
        let surface: String
        let lemma: String
        let reading: String
        let pos: String
        let contextual: String
        let general: String
    }

    private static func fallbackSamples(isJapanese: Bool) -> [FallbackSample] {
        if isJapanese {
            return [
                FallbackSample(
                    surface: "木漏れ日", lemma: "木漏れ日", reading: "こもれび", pos: "名词",
                    contextual: "描绘透过林叶洒下的微光意象（模拟）", general: "从树叶缝隙间透出的阳光"
                ),
                FallbackSample(
                    surface: "駆け抜ける", lemma: "駆け抜ける", reading: "かけぬける", pos: "动词",
                    contextual: "传达穿过微风与时光的动态感（模拟）", general: "飞奔穿过；一口气跑过"
                ),
                FallbackSample(
                    surface: "静けさ", lemma: "静けさ", reading: "しずけさ", pos: "名词",
                    contextual: "烘托夜色或转折段落的静谧氛围（模拟）", general: "宁静；安静的状态"
                ),
                FallbackSample(
                    surface: "そっと", lemma: "そっと", reading: "そっと", pos: "副词",
                    contextual: "形容动作轻柔克制、不打扰情绪（模拟）", general: "轻轻地；悄悄地"
                )
            ]
        }
        return [
            FallbackSample(
                surface: "afterglow", lemma: "afterglow", reading: "/ˈɑːftəɡləʊ/", pos: "名词",
                contextual: "Metaphorical warmth lingering after sunset (mock).", general: "余晖；事后留存的温暖感受"
            ),
            FallbackSample(
                surface: "drift away", lemma: "drift away", reading: "/drɪft əˈweɪ/", pos: "动词短语",
                contextual: "Expresses memories fading gently (mock).", general: "渐渐飘远；逐渐淡去"
            ),
            FallbackSample(
                surface: "echoes", lemma: "echo", reading: "/ˈekəʊz/", pos: "名词",
                contextual: "Sounds or emotions repeating across time (mock).", general: "回声；共鸣"
            ),
            FallbackSample(
                surface: "horizon", lemma: "horizon", reading: "/həˈraɪzən/", pos: "名词",
                contextual: "Symbolizes distance and hope ahead (mock).", general: "地平线；眼界"
            )
        ]
    }
}
