import Foundation
import Testing
@testable import ShinAppleKit

/// schema v1 校验测试（schema 各行）与歌词模型基础测试。
/// 校验器是纯函数：只返回问题清单，绝不改动传入数据。
@Suite("LyricSchema 校验")
struct LyricSchemaValidationTests {

    @Test("合法文档 → 无问题")
    func validDocumentPasses() {
        let document = LyricDocument(lines: [
            LyricLine(startMs: 1_000, text: "第一句测试文本"),
            LyricLine(startMs: nil, text: "第二句测试文本")
        ])
        #expect(LyricSchemaValidator.issues(in: document).isEmpty)
    }

    @Test("未来 schemaVersion → 拒绝且不改动文档")
    func futureSchemaVersionRejected() {
        var document = LyricDocument(lines: [LyricLine(startMs: 1_000, text: "第一句测试文本")])
        document.schemaVersion = 2
        let before = document
        #expect(LyricSchemaValidator.issues(in: document) == [.unsupportedSchemaVersion(found: 2)])
        #expect(document == before)
    }

    @Test("重复 line.id → 拒绝")
    func duplicateLineIdRejected() {
        let sharedId = UUID()
        let document = LyricDocument(lines: [
            LyricLine(id: sharedId, startMs: 1_000, text: "第一句测试文本"),
            LyricLine(id: sharedId, startMs: 2_000, text: "第二句测试文本")
        ])
        #expect(LyricSchemaValidator.issues(in: document) == [.duplicateLineId(sharedId)])
    }

    @Test("合法备份 JSON（含 null startMs 与未知键）→ 无问题")
    func validBackupJSONPasses() throws {
        let json = """
        {"schemaVersion":1,"futureField":{"a":1},"lines":[
          {"id":"\(UUID().uuidString)","startMs":1000,"futureLineField":"x"},
          {"id":"\(UUID().uuidString)","startMs":null}
        ]}
        """
        #expect(LyricSchemaValidator.issuesInBackupJSON(Data(json.utf8)).isEmpty)
    }

    @Test("小数毫秒 → 拒绝（不静默取整）")
    func fractionalMillisecondsRejected() throws {
        let lineId = UUID()
        let json = """
        {"schemaVersion":1,"lines":[{"id":"\(lineId.uuidString)","startMs":1000.5}]}
        """
        #expect(LyricSchemaValidator.issuesInBackupJSON(Data(json.utf8)) == [.fractionalMilliseconds(lineId: lineId)])
    }

    @Test("非有限时间（无穷大 NSNumber）→ 拒绝")
    func nonFiniteTimeRejected() throws {
        let lineId = UUID()
        let object: [String: Any] = [
            "schemaVersion": 1,
            "lines": [["id": lineId.uuidString, "startMs": NSNumber(value: Double.infinity)]]
        ]
        #expect(LyricSchemaValidator.issues(inJSONObject: object) == [.nonFiniteTime(lineId: lineId)])

        // 非有限字面量（1e999）在 JSON 解析层即被拒绝。
        let rawJSON = """
        {"schemaVersion":1,"lines":[{"id":"\(lineId.uuidString)","startMs":1e999}]}
        """
        #expect(LyricSchemaValidator.issuesInBackupJSON(Data(rawJSON.utf8)).first?.isInvalidStructure == true)
    }

    @Test("时间超出 Int64 毫秒范围 → 拒绝")
    func outOfRangeTimeRejected() throws {
        let lineId = UUID()
        let json = """
        {"schemaVersion":1,"lines":[{"id":"\(lineId.uuidString)","startMs":1e30}]}
        """
        #expect(LyricSchemaValidator.issuesInBackupJSON(Data(json.utf8)) == [.timeOutOfRange(lineId: lineId)])
    }

    @Test("备份 JSON 未来 schemaVersion → 拒绝")
    func backupFutureVersionRejected() throws {
        let json = """
        {"schemaVersion":2,"lines":[]}
        """
        let issues = LyricSchemaValidator.issuesInBackupJSON(Data(json.utf8))
        #expect(issues == [.unsupportedSchemaVersion(found: 2)])
    }

    @Test("备份 JSON 结构非法 → invalidStructure")
    func invalidBackupStructuresRejected() throws {
        let notAnObject = Data("[1,2,3]".utf8)
        #expect(
            LyricSchemaValidator.issuesInBackupJSON(notAnObject) == [.invalidStructure("顶层必须是 JSON 对象")]
        )

        let missingLines = Data("{\"schemaVersion\":1}".utf8)
        #expect(
            LyricSchemaValidator.issuesInBackupJSON(missingLines) == [.invalidStructure("缺少 lines 数组")]
        )

        let badId = Data("{\"schemaVersion\":1,\"lines\":[{\"id\":\"不是UUID\",\"startMs\":1}]}".utf8)
        #expect(
            LyricSchemaValidator.issuesInBackupJSON(badId).first?.isInvalidStructure == true
        )

        let stringStartMs = Data(
            "{\"schemaVersion\":1,\"lines\":[{\"id\":\"\(UUID().uuidString)\",\"startMs\":\"1000\"}]}".utf8
        )
        #expect(
            LyricSchemaValidator.issuesInBackupJSON(stringStartMs).first?.isInvalidStructure == true
        )

        let booleanStartMs = Data(
            "{\"schemaVersion\":1,\"lines\":[{\"id\":\"\(UUID().uuidString)\",\"startMs\":true}]}".utf8
        )
        #expect(
            LyricSchemaValidator.issuesInBackupJSON(booleanStartMs).first?.isInvalidStructure == true
        )
    }

    @Test("备份 JSON 半截内容 → invalidStructure，原数据不受影响")
    func truncatedBackupJSONRejected() throws {
        let data = Data("{\"schemaVersion\":1,\"lines\":[{\"id\":\"".utf8)
        #expect(LyricSchemaValidator.issuesInBackupJSON(data).first?.isInvalidStructure == true)
    }
}

extension LyricSchemaIssue {
    /// 测试辅助：是否为结构/类型非法。
    var isInvalidStructure: Bool {
        if case .invalidStructure = self { return true }
        return false
    }
}

/// 歌词模型基础行为测试。
@Suite("歌词模型基础")
struct LyricModelTests {

    @Test("LyricDocument 默认值与 ISO8601 时间戳")
    func documentDefaults() {
        let document = LyricDocument()
        #expect(document.schemaVersion == 1)
        #expect(document.revision == 1)
        #expect(document.sourceFormat == .lrc)
        #expect(document.sourceOffsetMs == 0)
        #expect(document.lines.isEmpty)
        #expect(document.metadata.isEmpty)
        #expect(LyricTimestamp.date(from: document.createdAt) != nil)
        #expect(document.createdAt == document.updatedAt)
    }

    @Test("LyricTimestamp 与固定时间往返")
    func timestampFormatting() {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let text = LyricTimestamp.string(from: date)
        #expect(text == "2026-01-01T00:00:00Z")
        #expect(LyricTimestamp.date(from: text) == date)
        #expect(LyricTimestamp.date(from: "不是时间") == nil)
    }

    @Test("SongBinding.trackKey 使用项目命名空间格式")
    func trackKeyFormat() {
        let track = CatalogIdentity(storefront: "cn", catalogSongId: "song-1")
        #expect(SongBinding.trackKey(for: track) == "apple-music:catalog:cn:song-1")
        let binding = SongBinding(track: track, lyricDocumentId: UUID(), userDelayMs: 500)
        #expect(binding.trackKey == "apple-music:catalog:cn:song-1")
        #expect(binding.userDelayMs == 500)
        #expect(binding.titleHint == nil)
        #expect(binding.artistHint == nil)
        #expect(binding.durationHintMs == nil)
    }

    @Test("sourceFormat nativeJSON 原始值")
    func nativeJSONRawValue() {
        #expect(LyricSourceFormat.nativeJSON.rawValue == "native-json")
        #expect(LyricSourceFormat.lrc.rawValue == "lrc")
        #expect(LyricSourceFormat.text.rawValue == "text")
    }

    @Test("LyricDocument Codable 往返保留翻译与元信息")
    func codableRoundTrip() throws {
        let document = LyricDocument(
            sourceFormat: .lrc,
            sourceOffsetMs: 200,
            originalText: "[00:01.00]第一句测试文本",
            originalFilename: "测试.lrc",
            metadata: ["ti": ["测试曲目"]],
            lines: [
                LyricLine(
                    startMs: 1_000,
                    text: "第一句测试文本",
                    translations: ["zh-Hans": Translation(text: "译文测试文本", source: .manual, needsReview: true)]
                )
            ]
        )
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(LyricDocument.self, from: data)
        #expect(decoded == document)
    }
}
