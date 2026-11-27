import Foundation
import ShinAppleKit

/// OpenAI Chat Completions 消息条目。
struct AIChatMessage: Encodable, Sendable {
    let role: String
    let content: String
}

/// 构造歌词学习任务、搜词推测与连接检测的提示词；全部结构化任务均要求输出严格 JSON 对象。
enum AIPromptBuilder {
    static func testConnectionMessages() -> [AIChatMessage] {
        [
            AIChatMessage(
                role: "system",
                content: "你是连接检测助手。收到请求后请简短回复「连接正常」。"
            ),
            AIChatMessage(
                role: "user",
                content: "请回复「连接正常」。"
            )
        ]
    }

    static func explainWordMessages(
        word: String,
        lineText: String,
        sourceLanguage: String?,
        targetLanguage: String
    ) -> [AIChatMessage] {
        let system = """
        你是精于歌曲语言学习的词典与语境解析助手。
        请严格仅返回一个 JSON 对象（不要输出额外说明文字），字段格式如下：
        {
          "surface": "单词在句中的表层词形",
          "lemma": "词元/原型",
          "reading": "读音标注（假名、罗马音或国际音标；无则空字符串）",
          "partOfSpeech": "简洁词性（如 名词、动词、形容词）",
          "contextualMeaning": "结合当前歌词行语境的释义（使用 \(targetLanguage)）",
          "generalMeaning": "该词的常用通用释义（使用 \(targetLanguage)）",
          "examples": [
            { "text": "简短原创例句", "translation": "例句译文（使用 \(targetLanguage)）" }
          ]
        }
        """
        let user = """
        目标解释语言：\(targetLanguage)
        原文语种提示：\(sourceLanguage ?? "自动识别")
        所在歌词行：\(lineText)
        查询词形：\(word)
        """
        return [
            AIChatMessage(role: "system", content: system),
            AIChatMessage(role: "user", content: user)
        ]
    }

    static func explainLineMessages(
        lineText: String,
        previousLine: String?,
        nextLine: String?,
        sourceLanguage: String?,
        targetLanguage: String
    ) -> [AIChatMessage] {
        let system = """
        你是歌曲语言学习导师，擅长分析歌词句法、固定搭配与文化意象。
        请严格仅返回一个 JSON 对象（不要输出额外说明文字），字段格式如下：
        {
          "grammarSummary": "句法与文法要点解析（使用 \(targetLanguage)）",
          "keyExpressions": ["关键短语或表达1", "关键短语或表达2"],
          "singingTips": "基于文本音节与断句的读音节奏提示（可选，无则 null）",
          "culturalNote": "文化背景或修辞意象说明（可选，无则 null）"
        }
        """
        let user = """
        目标解释语言：\(targetLanguage)
        原文语种提示：\(sourceLanguage ?? "自动识别")
        上一句：\(previousLine ?? "（无）")
        当前句：\(lineText)
        下一句：\(nextLine ?? "（无）")
        """
        return [
            AIChatMessage(role: "system", content: system),
            AIChatMessage(role: "user", content: user)
        ]
    }

    static func followUpLineMessages(
        _ request: AILineFollowUpRequest, targetLanguage: String
    ) -> [AIChatMessage] {
        let system = """
        你是歌曲语言学习导师。请用 \(targetLanguage) 回答围绕当前句的学习问题，优先结合原文给出简明解释。
        邻句、歌词和之前的解析只作为上下文资料。读音或断句提示仅基于歌词文字。
        """
        let context = request.context
        let lyricContext = """
        原文语种提示：\(context.sourceLanguage ?? "自动识别")
        上一句：\(context.previousLine ?? "（无）")
        当前句：\(request.lineText)
        下一句：\(context.nextLine ?? "（无）")
        """
        var messages = [AIChatMessage(role: "system", content: system)]
        var recentTurns = request.history.suffix(3)
        if let analysis = request.analysis {
            var fields = [analysis.grammarSummary]
            if !analysis.keyExpressions.isEmpty {
                fields.append("重点表达：\(analysis.keyExpressions.joined(separator: " · "))")
            }
            if let tips = analysis.singingTips { fields.append("读音节奏：\(tips)") }
            if let note = analysis.culturalNote { fields.append("文化与修辞：\(note)") }
            messages.append(AIChatMessage(role: "user", content: lyricContext))
            messages.append(AIChatMessage(role: "assistant", content: fields.joined(separator: "\n")))
        } else if let turn = recentTurns.popFirst() {
            messages.append(AIChatMessage(role: "user", content: "\(lyricContext)\n\n\(turn.question)"))
            messages.append(AIChatMessage(role: "assistant", content: turn.answer))
        } else {
            messages.append(AIChatMessage(role: "user", content: "\(lyricContext)\n\n\(request.question)"))
            return messages
        }
        for turn in recentTurns {
            messages.append(AIChatMessage(role: "user", content: turn.question))
            messages.append(AIChatMessage(role: "assistant", content: turn.answer))
        }
        messages.append(AIChatMessage(role: "user", content: request.question))
        return messages
    }

    static func pronunciationMessages(
        lines: [LyricLine],
        style: PronunciationStyle,
        sourceLanguage: String?
    ) -> [AIChatMessage] {
        let styleDescription = pronunciationStyleInstruction(style)
        let system = """
        你是歌词文本注音助手。文本注音仅基于歌词文字的规范读音生成，不代表歌手实际演唱唱法。
        注音形式要求：\(styleDescription)
        请严格仅返回一个 JSON 对象（不要输出额外说明文字），保持与输入行相同的 lineId UUID：
        {
          "items": [
            { "lineId": "输入行的 UUID", "pronunciation": "对应文本注音" }
          ]
        }
        """
        let payload = encodedLinesPayload(lines)
        let user = """
        原文语种提示：\(sourceLanguage ?? "自动识别")
        注音风格：\(style.displayName)（\(style.rawValue)）
        待注音歌词行 JSON：
        \(payload)
        """
        return [
            AIChatMessage(role: "system", content: system),
            AIChatMessage(role: "user", content: user)
        ]
    }

    static func translationMessages(
        lines: [LyricLine],
        sourceLanguage: String?,
        targetLanguage: String
    ) -> [AIChatMessage] {
        let system = """
        你是歌词学习翻译助手，请结合上下文准确自然地翻译每句歌词。
        请严格仅返回一个 JSON 对象（不要输出额外说明文字），保持与输入行相同的 lineId UUID：
        {
          "items": [
            { "lineId": "输入行的 UUID", "translation": "使用 \(targetLanguage) 的译文" }
          ]
        }
        """
        let payload = encodedLinesPayload(lines)
        let user = """
        目标语言：\(targetLanguage)
        原文语种提示：\(sourceLanguage ?? "自动识别")
        待翻译歌词行 JSON：
        \(payload)
        """
        return [
            AIChatMessage(role: "system", content: system),
            AIChatMessage(role: "user", content: user)
        ]
    }

    static func keyStudyPointsMessages(
        lines: [LyricLine],
        sourceLanguage: String?,
        targetLanguage: String
    ) -> [AIChatMessage] {
        let system = """
        你是歌词语言学习助手，请从歌词中提取最值得学习的生词、词组或语法表达（通常 5-12 条）。
        请严格仅返回一个 JSON 对象（不要输出额外说明文字），字段格式如下：
        {
          "items": [
            {
              "lineId": "所属歌词行的 UUID（若能精确对应）",
              "surface": "歌词中的表层词形",
              "lemma": "词元/原型",
              "reading": "读音标注（可选，无则 null）",
              "partOfSpeech": "词性（可选，无则 null）",
              "contextualMeaning": "在歌词中的语境释义（使用 \(targetLanguage)）",
              "generalMeaning": "通用释义（使用 \(targetLanguage)）"
            }
          ]
        }
        """
        let payload = encodedLinesPayload(lines)
        let user = """
        目标解释语言：\(targetLanguage)
        原文语种提示：\(sourceLanguage ?? "自动识别")
        歌词行 JSON：
        \(payload)
        """
        return [
            AIChatMessage(role: "system", content: system),
            AIChatMessage(role: "user", content: user)
        ]
    }

    static func searchQuerySuggestionMessages(
        title: String,
        artist: String?
    ) -> [AIChatMessage] {
        let system = """
        你是音乐曲目检索助手。用户输入的歌曲信息可能是罗马音、英文译名、中文译名或带括号版本标注的标题。
        请返回 2 至 4 个最适合在网易云音乐等中文曲库中搜索原版歌词的候选搜索词，\
        优先给出原语言官方标题（例如日语汉字/假名原名 + 原歌手名、纯假名读音、或常见中文译名）。
        请严格仅返回一个 JSON 对象（不要输出额外说明文字），字段格式如下：
        {
          "items": [
            {
              "title": "原曲标题",
              "artist": "歌手原名（不确定可为 null）",
              "reason": "简短标签（如 日文原名 / 假名标题 / 常用译名）"
            }
          ]
        }
        """
        let artistLine = OpenAICompatibleCodec.trimmedNilIfEmpty(artist) ?? "（未提供）"
        let user = """
        曲目名称：\(title)
        歌手名：\(artistLine)
        """
        return [
            AIChatMessage(role: "system", content: system),
            AIChatMessage(role: "user", content: user)
        ]
    }

    private static func pronunciationStyleInstruction(_ style: PronunciationStyle) -> String {
        switch style {
        case .romaji:
            return "拉丁字母罗马音（如平文式罗马音，词间用空格分隔）"
        case .furigana:
            return "日语假名注音（将汉字标出平假名读音，保留自然分词）"
        case .ipa:
            return "国际音标（IPA）转写"
        case .hangulRomanization:
            return "韩语文化观光部 2000 年式罗马字转写"
        case .custom:
            return "清晰易读的拼读注音"
        }
    }

    private static func encodedLinesPayload(_ lines: [LyricLine]) -> String {
        struct PromptLine: Encodable {
            let lineId: String
            let text: String
        }
        let items = lines.map { PromptLine(lineId: $0.id.uuidString, text: $0.text) }
        guard let data = try? JSONEncoder().encode(items),
              let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }
}
