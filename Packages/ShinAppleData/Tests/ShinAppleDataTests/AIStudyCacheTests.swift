import Foundation
import GRDB
import ShinAppleKit
import Testing
@testable import ShinAppleData

@Suite("AI 学习结果缓存")
struct AIStudyCacheTests {
    private static let payload = Data("原创测试解析".utf8)
    private static let generatedAt = Date.now

    @Test("从 v4 升级保留笔记，缓存可重新打开且不写入学习备份")
    func migrationAndReopening() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }

        var fixture = Fixture.documentA()
        fixture.lines[0].studyNote = LineStudyNote(
            grammarSummary: "原有人工笔记", source: .manual(), updatedAt: Fixture.fixedTimestamp
        )
        let document = fixture
        try makeV4Store(at: TestEnv.storePath(in: directory), document: document)

        let originalBackup: Data
        do {
            let store = try TestEnv.makeStore(directory)
            let generation = try #require(await store.aiStudyCacheGeneration())
            #expect(try await store.document(id: document.id) == document)
            originalBackup = try await store.exportBackup(at: Self.generatedAt)
            try await store.saveAIStudyCachePayload(
                Self.payload, documentID: document.id, key: "analysis", generation: generation, now: Self.generatedAt
            )
        }

        let reopened = try TestEnv.makeStore(directory)
        #expect(try await reopened.aiStudyCachePayload(
            documentID: document.id, key: "analysis", now: Self.generatedAt
        ) == Self.payload)
        #expect(try await reopened.exportBackup(at: Self.generatedAt) == originalBackup)
        #expect(try await reopened.document(id: document.id) == document)
    }

    @Test("v5 原有缓存可读，同库清空后拒绝旧代次的批次与整句结果")
    func migrationFromV5AndGenerationGuard() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let path = TestEnv.storePath(in: directory)
        let document = Fixture.documentA()
        let legacy = try DatabasePool(path: path)
        try Schema.v5Migrator().migrate(legacy)
        try await legacy.write { db in
            var row = try LyricDocumentRow(from: document)
            try row.save(db)
            try AIStudyCacheLimit.upsert(
                Self.payload, in: db, documentID: document.id, key: "v5", timestamp: Self.generatedAt.timeIntervalSince1970
            )
        }
        try legacy.close()

        let store = try TestEnv.makeStore(directory)
        let peer = try TestEnv.makeStore(directory)
        #expect(try await store.document(id: document.id) == document)
        #expect(try await store.aiStudyCachePayload(documentID: document.id, key: "v5") == Self.payload)
        let oldGeneration = try #require(await store.aiStudyCacheGeneration())
        #expect(try await peer.aiStudyCacheGeneration() == oldGeneration)
        try await peer.clearAIStudyCache()
        let newGeneration = try #require(await store.aiStudyCacheGeneration())
        #expect(newGeneration != oldGeneration)

        try await store.saveAIStudyCachePayload(Self.payload, documentID: document.id, key: "line", generation: oldGeneration)
        try await store.saveAIStudyCacheBatch(
            Self.payload, documentID: document.id, keys: ("batch", "index"), generation: oldGeneration
        ) { _ in Self.payload }
        let keys = try await store.performRead { db in
            try String.fetchAll(db, sql: "SELECT cacheKey FROM aiStudyCache")
        }
        #expect(keys.isEmpty)

        try await store.saveAIStudyCachePayload(Self.payload, documentID: document.id, key: "line", generation: newGeneration)
        #expect(try await peer.aiStudyCachePayload(documentID: document.id, key: "line") == Self.payload)
    }

    @Test("缓存七天到期，有效读取不延长时限")
    func expiration() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let generation = try #require(await store.aiStudyCacheGeneration())
        let document = Fixture.documentA()
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))
        try await store.saveAIStudyCachePayload(
            Self.payload, documentID: document.id, key: "analysis", generation: generation, now: Self.generatedAt
        )

        let expiresAt = Self.generatedAt.addingTimeInterval(7 * 24 * 60 * 60)
        #expect(try await store.aiStudyCachePayload(
            documentID: document.id, key: "analysis", now: expiresAt.addingTimeInterval(-1)
        ) == Self.payload)
        #expect(try await store.aiStudyCachePayload(
            documentID: document.id, key: "analysis", now: expiresAt
        ) == nil)

        let expiredAtOpening = Self.generatedAt.addingTimeInterval(-7 * 24 * 60 * 60)
        try await store.saveAIStudyCachePayload(
            Self.payload, documentID: document.id, key: "expired", generation: generation, now: expiredAtOpening
        )
        let reopened = try TestEnv.makeStore(directory)
        let keys = try await reopened.performRead { db in
            try String.fetchAll(db, sql: "SELECT cacheKey FROM aiStudyCache")
        }
        #expect(keys == ["analysis"])
    }

    @Test("超过 20 MiB 时，先清过期结果再淘汰最早的有效结果")
    func capacityEvictsOldest() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let generation = try #require(await store.aiStudyCacheGeneration())
        let document = Fixture.documentA()
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))

        let mebibyte = 1_024 * 1_024
        let tenMiB = Data(repeating: 1, count: 10 * mebibyte)
        let sixMiB = Data(repeating: 2, count: 6 * mebibyte)
        let expired = Self.generatedAt.addingTimeInterval(-7 * 24 * 60 * 60)
        try await store.saveAIStudyCachePayload(
            tenMiB, documentID: document.id, key: "expired", generation: generation, now: expired
        )
        for (index, key) in ["old", "middle", "new"].enumerated() {
            try await store.saveAIStudyCachePayload(
                index == 2 ? tenMiB : sixMiB, documentID: document.id, key: key, generation: generation,
                now: Self.generatedAt.addingTimeInterval(Double(index))
            )
        }
        let keys = try await store.performRead { db in
            try String.fetchAll(db, sql: "SELECT cacheKey FROM aiStudyCache ORDER BY createdAt")
        }
        #expect(keys == ["middle", "new"])
    }

    @Test("草稿、清空、删除文档及换库按各自范围处理缓存")
    func libraryAndDocumentIsolation() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let relocatedDirectory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(relocatedDirectory) }
        let store = try TestEnv.makeStore(directory)
        let generation = try #require(await store.aiStudyCacheGeneration())
        let first = Fixture.documentA()
        let second = Fixture.textDocument()
        let key = "analysis"
        let now = Self.generatedAt

        try await store.saveAIStudyCachePayload(
            Self.payload, documentID: first.id, key: key, generation: generation, now: now
        )
        try await store.save(document: first, binding: Fixture.binding(Fixture.trackA, to: first))
        try await store.save(document: second, binding: Fixture.binding(Fixture.trackB, to: second))
        #expect(try await store.aiStudyCachePayload(documentID: first.id, key: key, now: now) == nil)

        let marker = "ORIGINAL_CACHE_RELOCATION_FIXTURE"
        let payload = Data(String(repeating: marker, count: (60 * 1_024) / marker.utf8.count).utf8)
        for document in [first, second] {
            try await store.saveAIStudyCachePayload(payload, documentID: document.id, key: key, generation: generation, now: now)
        }
        try await store.deleteDocument(id: first.id, deletingAffectedBindings: true)
        #expect(try await store.aiStudyCachePayload(documentID: first.id, key: key, now: now) == nil)
        #expect(try await store.aiStudyCachePayload(documentID: second.id, key: key, now: now) == payload)

        let targetPath = TestEnv.storePath(in: relocatedDirectory)
        try store.backupDatabase(toFileAt: targetPath)
        let contents = try Data(contentsOf: URL(fileURLWithPath: targetPath))
        #expect(contents.range(of: Data(marker.utf8)) == nil)
        let targetFiles = try FileManager.default.contentsOfDirectory(atPath: relocatedDirectory)
        #expect(targetFiles == [URL(fileURLWithPath: targetPath).lastPathComponent])
        #expect(try await store.aiStudyCachePayload(documentID: second.id, key: key, now: now) == payload)
        let relocated = try TestEnv.makeStore(relocatedDirectory)
        #expect(try await relocated.document(id: second.id) == second)
        #expect(try await relocated.aiStudyCachePayload(documentID: second.id, key: key, now: now) == nil)
        let relocatedGeneration = try #require(await relocated.aiStudyCacheGeneration())
        #expect(relocatedGeneration != generation)
        try await relocated.saveAIStudyCachePayload(
            Self.payload, documentID: second.id, key: key, generation: relocatedGeneration, now: now
        )
        try await store.clearAIStudyCache()
        #expect(try await store.document(id: second.id) == second)
        #expect(try await store.aiStudyCachePayload(documentID: second.id, key: key, now: now) == nil)
        #expect(try await relocated.aiStudyCachePayload(documentID: second.id, key: key, now: now) == Self.payload)
    }

    private func makeV4Store(at path: String, document: LyricDocument) throws {
        let pool = try DatabasePool(path: path)
        try Schema.v4Migrator().migrate(pool)
        try pool.write { db in
            var row = try LyricDocumentRow(from: document)
            try row.save(db)
        }
        try pool.close()
    }
}
