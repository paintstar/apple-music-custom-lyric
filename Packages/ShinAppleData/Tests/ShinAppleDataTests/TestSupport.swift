import Foundation
import Testing
import ShinAppleKit
@testable import ShinAppleData

// 测试环境与夹具：全部使用原创虚构文本（"第一句测试文本" 系列），
// 不复制任何真实歌词；时间戳用固定 Date 生成，保证夹具确定。

enum TestEnv {

    static func makeTempDirectory() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShinAppleDataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    static func storePath(in directory: String) -> String {
        directory + "/lyrics.sqlite"
    }

    static func makeStore(
        _ directory: String,
        configuration: BackupConfiguration = .standard
    ) throws -> GRDBLyricsStore {
        try GRDBLyricsStore(
            path: storePath(in: directory),
            backupConfiguration: configuration
        )
    }

    /// 目录与其中文件设为只读（模拟磁盘/权限故障）。
    static func makeReadOnly(_ directory: String) throws {
        let url = URL(fileURLWithPath: directory)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory)
        for name in contents {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444], ofItemAtPath: url.appendingPathComponent(name).path
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
    }

    /// 恢复可写（清理前调用）。
    static func makeWritable(_ directory: String) throws {
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory)
        for name in contents {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.appendingPathComponent(name).path
            )
        }
    }

    static func cleanup(_ directory: String) {
        try? makeWritable(directory)
        try? FileManager.default.removeItem(atPath: directory)
    }
}

// MARK: - 夹具

enum Fixture {

    static let trackA = CatalogIdentity(storefront: "us", catalogSongId: "9000001")
    static let trackB = CatalogIdentity(storefront: "us", catalogSongId: "9000002")
    static let trackC = CatalogIdentity(storefront: "cn", catalogSongId: "8000003")

    /// 固定夹具时间（2026-05-01T00:00:00Z）。
    static let fixedDate = Date(timeIntervalSince1970: 1_777_600_000)
    static let fixedTimestamp = LyricTimestamp.string(from: fixedDate)

    /// 带 LRC 来源、译文、未打轴行、空白行、offset 与元信息的完整文档。
    static func documentA(
        id: UUID = UUID(),
        revision: Int = 3
    ) -> LyricDocument {
        LyricDocument(
            id: id,
            revision: revision,
            sourceLanguage: "ja",
            sourceFormat: .lrc,
            sourceOffsetMs: 200,
            originalText: "[00:01]第一句测试文本\n[00:03]第二句测试文本\n",
            originalFilename: "fixture-a.lrc",
            metadata: [
                "ar": ["测试歌手甲", "测试歌手乙"],
                "ti": ["测试曲目甲"],
                "unknownTag": ["未知的元信息"]
            ],
            lines: [
                LyricLine(
                    startMs: 1_000,
                    text: "第一句测试文本",
                    translations: [
                        "zh-Hans": Translation(
                            text: "第一句测试译文", source: .manual, needsReview: false
                        )
                    ]
                ),
                LyricLine(startMs: 3_000, text: "第二句测试文本"),
                LyricLine(startMs: nil, text: "未打轴测试文本"),
                LyricLine(startMs: 6_000, text: "")
            ],
            createdAt: fixedTimestamp,
            updatedAt: fixedTimestamp
        )
    }

    /// 纯文本（全部未打轴）文档。
    static func textDocument(
        id: UUID = UUID(),
        revision: Int = 1
    ) -> LyricDocument {
        LyricDocument(
            id: id,
            revision: revision,
            sourceFormat: .text,
            sourceOffsetMs: 0,
            originalFilename: "fixture-text.txt",
            lines: [
                LyricLine(startMs: nil, text: "纯文本第一行测试"),
                LyricLine(startMs: nil, text: "纯文本第二行测试")
            ],
            createdAt: fixedTimestamp,
            updatedAt: fixedTimestamp
        )
    }

    static func binding(
        _ track: CatalogIdentity,
        to document: LyricDocument,
        delayMs: Int64 = 500,
        title: String = "测试曲目提示",
        artist: String = "测试艺人提示",
        durationMs: Int64? = 183_000
    ) -> SongBinding {
        SongBinding(
            track: track,
            lyricDocumentId: document.id,
            userDelayMs: delayMs,
            titleHint: title,
            artistHint: artist,
            durationHintMs: durationMs,
            updatedAt: fixedTimestamp
        )
    }
}

// MARK: - 断言辅助

/// 断言 parseBackup 以指定原因拒绝，且（可选地）库快照保持不变。
func expectBackupRejection(
    _ data: Data,
    from store: GRDBLyricsStore,
    configuration: BackupConfiguration? = nil,
    equals expected: BackupRejection,
    librarySnapshot: BackupStoreSnapshot? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        if let configuration = configuration {
            _ = try store.parseBackup(data, configuration: configuration)
        } else {
            _ = try store.parseBackup(data)
        }
        Issue.record("备份应当被拒绝", sourceLocation: sourceLocation)
    } catch let error as ShinAppleDataError {
        guard case let .invalidBackup(rejection) = error else {
            Issue.record("错误类型不符，期望 invalidBackup，实际：\(error)", sourceLocation: sourceLocation)
            return
        }
        #expect(rejection == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("非 ShinAppleDataError：\(error)", sourceLocation: sourceLocation)
    }
    if let before = librarySnapshot {
        let after = try? await store.currentSnapshot()
        #expect(after == before, "拒绝后原库必须保持不变", sourceLocation: sourceLocation)
    }
}

/// 预置一个带文档与绑定的库，返回其快照（用于"原库不变"断言）。
func seedBackupFixture(_ store: GRDBLyricsStore) async throws -> BackupStoreSnapshot {
    let document = Fixture.documentA()
    try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))
    return try await store.currentSnapshot()
}

/// 解析被拒绝时的类型化原因；未被拒绝或类型不符时记录 Issue。
func firstBackupRejection(
    _ data: Data,
    _ store: GRDBLyricsStore,
    sourceLocation: SourceLocation = #_sourceLocation
) -> BackupRejection? {
    do {
        _ = try store.parseBackup(data)
        Issue.record("备份应当被拒绝", sourceLocation: sourceLocation)
        return nil
    } catch let error as ShinAppleDataError {
        guard case let .invalidBackup(rejection) = error else {
            Issue.record("错误类型不符：\(error)", sourceLocation: sourceLocation)
            return nil
        }
        return rejection
    } catch {
        Issue.record("非 ShinAppleDataError：\(error)", sourceLocation: sourceLocation)
        return nil
    }
}

/// 覆盖单个限制、其余取默认值的配置。
func limitsWith(
    maxBytes: Int = 2 * 1024 * 1024,
    maxDocuments: Int = 10_000,
    maxTotalLines: Int = 10_000,
    maxSettingsEntries: Int = 256
) -> BackupConfiguration {
    BackupConfiguration(
        limits: BackupLimits(
            maxBytes: maxBytes,
            maxDocuments: maxDocuments,
            maxBindings: 10_000,
            maxTotalLines: maxTotalLines,
            maxSettingsEntries: maxSettingsEntries,
            maxDepth: 32,
            maxUnknownArrayLength: 10_000
        )
    )
}
