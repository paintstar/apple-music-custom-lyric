import Foundation
import GRDB
import Testing
import ShinAppleKit
@testable import ShinAppleData

// v3 摘要列（增删改查性能补强）：
// - v2 → v3 迁移回填正确（行数/打轴数/offset/标题/原文件名）；
// - 写路径（保存/更新）维护摘要列；
// - 库总览读摘要不解码 payload（规模冒烟见文末，打印耗时供人工审阅）。
struct DocumentSummaryTests {

    /// 用 v2 迁移器建一个真实旧库并写入 v2 时代的行（不含摘要列）。
    private func makeV2Store(_ directory: String, document: LyricDocument) throws -> GRDBLyricsStore {
        let path = TestEnv.storePath(in: directory)
        let pool = try DatabasePool(path: path)
        try Schema.v2Migrator().migrate(pool)
        // 模拟 v2 时代写入：手工构造 payload（不走 LyricDocumentRow——它现在
        // 会写 v3 列，旧库还没有这些列）。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = String(data: try encoder.encode(document), encoding: .utf8)!
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO lyricDocument (id, schemaVersion, revision, payload, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [document.id.uuidString, document.schemaVersion, document.revision, payload, document.updatedAt]
            )
            try db.execute(
                sql: """
                INSERT INTO songBinding (trackKey, persistentId, lyricDocumentId,
                    userDelayMs, titleHint, artistHint, durationHintMs, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    SongBinding(persistentID: "ABCDEF01", lyricDocumentId: document.id).trackKey,
                    "ABCDEF01", document.id.uuidString, 500, "测试曲目提示", "测试艺人提示", 183_000, document.updatedAt
                ]
            )
        }
        // 关闭 v2 连接，交还给正常打开路径跑 v3 迁移。
        try pool.close()
        return try GRDBLyricsStore(path: path)
    }

    @Test("v2 → v3 迁移回填摘要列")
    func migrationBackfillsSummaryColumns() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let source = Fixture.documentA()
        let store = try makeV2Store(directory, document: source)

        let summaries = try await store.allDocumentSummaries()
        #expect(summaries.count == 1)
        guard let summary = summaries.first else { return }
        #expect(summary.id == source.id)
        #expect(summary.revision == source.revision)
        #expect(summary.updatedAt == source.updatedAt)
        // 夹具：4 行（3 行打轴 + 1 行未打轴，其中一行空文本仍计入行数）。
        #expect(summary.lineCount == 4)
        #expect(summary.timedLineCount == 3)
        #expect(summary.untimedLineCount == 1)
        #expect(summary.sourceOffsetMs == 200)
        #expect(summary.titleHint == "测试曲目甲")
        #expect(summary.originalFilename == "fixture-a.lrc")
    }

    @Test("保存与更新维护摘要列")
    func writesMaintainSummaryColumns() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)

        let document = Fixture.documentA()
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))
        var summaries = try await store.allDocumentSummaries()
        #expect(summaries.count == 1)
        #expect(summaries[0].lineCount == 4 && summaries[0].timedLineCount == 3)

        // 文档级更新通道改行数后摘要同步。
        var updated = document
        updated.revision = document.revision + 1
        updated.lines = [LyricLine(startMs: 1_000, text: "更新后唯一一行")]
        try await store.updateDocument(updated)
        summaries = try await store.allDocumentSummaries()
        #expect(summaries.count == 1)
        #expect(summaries[0].lineCount == 1 && summaries[0].timedLineCount == 1)
        #expect(summaries[0].revision == document.revision + 1)

        // 删除后摘要消失。
        try await store.deleteDocument(id: document.id, deletingAffectedBindings: true)
        #expect(try await store.allDocumentSummaries().isEmpty)
    }

    @Test("规模冒烟：摘要总览与增删改查在千级文档下可用（打印耗时）")
    func scaleSmoke() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)

        // 200 篇 × 60 行 = 12_000 行歌词 + 200 个绑定（超产品上限也快速通过）。
        let documentCount = 200
        let linesPerDocument = 60
        let start = ContinuousClock.now
        for index in 0..<documentCount {
            let lines = (0..<linesPerDocument).map { line in
                LyricLine(startMs: Int64(line * 1_000), text: "规模冒烟第 \(index) 篇第 \(line) 行")
            }
            let document = LyricDocument(id: UUID(), lines: lines)
            try await store.save(
                document: document,
                binding: SongBinding(
                    persistentID: String(format: "AB%06X", index), lyricDocumentId: document.id
                )
            )
        }
        let seedDuration = ContinuousClock.now - start

        let lookupStart = ContinuousClock.now
        let summaries = try await store.allDocumentSummaries()
        let summaryDuration = ContinuousClock.now - lookupStart
        #expect(summaries.count == documentCount)
        #expect(summaries.allSatisfy { $0.lineCount == linesPerDocument && $0.timedLineCount == linesPerDocument })

        // 对比：全量解码路径（备份导出仍需要）同库耗时，验证摘要路径的收益。
        let decodeStart = ContinuousClock.now
        let documents = try await store.allDocuments()
        let decodeDuration = ContinuousClock.now - decodeStart
        #expect(documents.count == documentCount)

        // 更新与删除路径各走一次。
        let updateTarget = documents[0]
        var updated = updateTarget
        updated.revision = updateTarget.revision + 1
        updated.lines = [LyricLine(startMs: 0, text: "冒烟更新行")]
        let updateStart = ContinuousClock.now
        try await store.updateDocument(updated)
        let updateDuration = ContinuousClock.now - updateStart

        let deleteStart = ContinuousClock.now
        try await store.deleteDocument(id: documents[1].id, deletingAffectedBindings: true)
        let deleteDuration = ContinuousClock.now - deleteStart

        #expect(try await store.allDocumentSummaries().count == documentCount - 1)

        print(
            "规模冒烟（\(documentCount) 篇 × \(linesPerDocument) 行）："
                + "写入 \(seedDuration)，摘要总览 \(summaryDuration)，"
                + "全量解码 \(decodeDuration)，更新 \(updateDuration)，删除 \(deleteDuration)"
        )
    }
}
