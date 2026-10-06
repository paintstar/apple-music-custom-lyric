import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

// 测试环境与夹具：全部为原创虚构文本（「测试文本」系列），
// 不复制任何真实歌词；每次测试使用独立的临时 GRDB 库（真实落盘）。

enum TestEnv {

    /// 在临时目录建立真实 GRDB 库（每次调用独立目录，互不干扰）。
    static func makeTempStore() throws -> (store: GRDBLyricsStore, directory: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShinAppServicesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBLyricsStore(path: dir.appendingPathComponent("lyrics.sqlite").path)
        return (store, dir)
    }

    static func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum Fixture {

    static let trackA = CatalogIdentity(storefront: "us", catalogSongId: "9100001")
    static let trackB = CatalogIdentity(storefront: "us", catalogSongId: "9100002")
    /// 与 trackA 同名但目录身份不同的歌曲（验证绝不按歌名关联）。
    static let trackSameTitleDifferentId = CatalogIdentity(storefront: "us", catalogSongId: "9100003")
    /// 第三首目录歌曲（歌词库管理/备份闭环使用；不同 storefront）。
    static let trackC = CatalogIdentity(storefront: "cn", catalogSongId: "8100004")

    static func targetA() -> ImportSessionTarget {
        ImportSessionTarget(
            track: trackA,
            titleHint: "测试曲目甲",
            artistHint: "测试歌手甲",
            durationHintMs: 183_000
        )
    }

    /// 标准 LRC 夹具：元信息 + offset + 3 行打轴 + 1 行未打轴（原创虚构）。
    static let lrcText = """
    [ti:测试曲目甲]
    [ar:测试歌手甲]
    [al:虚构专辑测试]
    [offset:200]
    [00:01.000]第一句测试文本
    [00:03.500]第二句测试文本
    [00:07]第三句测试文本
    未打轴补记测试文本
    """

    static var lrcData: Data { Data(lrcText.utf8) }

    /// 纯文本夹具：全部未打轴。
    static let plainTextData = Data("纯文本第一行测试\n纯文本第二行测试\n".utf8)

    /// 含 error 诊断的 LRC（坏时间戳；解析产出文档但不可保存）。
    static let errorLrcData = Data("[00:ab]坏时间戳测试文本\n[00:02.000]正常测试文本\n".utf8)

    /// 无法按 UTF-8/UTF-16 解码的字节（0xFF 为非法 UTF-8 首字节）。
    static let undecodableData = Data([0x61, 0xFF, 0x0A])

    /// 超过默认 2 MiB 限制的数据（解析器先检查大小，不进入解码）。
    static var oversizedData: Data {
        Data(count: 2 * 1024 * 1024 + 1)
    }

    /// 预置一个已绑定的旧文档（模拟「该歌曲已有歌词」）。
    @discardableResult
    static func seedOldDocument(
        in store: GRDBLyricsStore,
        track: CatalogIdentity = trackA
    ) async throws -> LyricDocument {
        let document = LyricDocument(
            sourceFormat: .lrc,
            sourceOffsetMs: 0,
            originalFilename: "旧文档测试.lrc",
            lines: [
                LyricLine(startMs: 1_500, text: "旧文档第一句测试文本"),
                LyricLine(startMs: 4_000, text: "旧文档第二句测试文本")
            ]
        )
        let binding = SongBinding(
            track: track,
            lyricDocumentId: document.id,
            userDelayMs: 250,
            titleHint: "旧提示曲目",
            artistHint: "旧提示歌手",
            durationHintMs: 180_000
        )
        try await store.save(document: document, binding: binding)
        return document
    }

    /// 直接保存一份全部未打轴的纯文本文档并绑定到 track。
    static func seedUntimedDocument(in store: GRDBLyricsStore, track: CatalogIdentity) async throws {
        let document = LyricDocument(
            sourceFormat: .text,
            lines: [
                LyricLine(startMs: nil, text: "纯文本第一行测试"),
                LyricLine(startMs: nil, text: "纯文本第二行测试")
            ]
        )
        try await store.save(
            document: document,
            binding: SongBinding(track: track, lyricDocumentId: document.id)
        )
    }
}

/// 断言抛出指定的 ImportWorkflowError（类型相等比较）。
func expectImportError(
    _ expected: ImportWorkflowError,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("应当抛出 \(expected)", sourceLocation: sourceLocation)
    } catch let error as ImportWorkflowError {
        #expect(error == expected, "实际错误：\(error.message)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("非 ImportWorkflowError：\(error)", sourceLocation: sourceLocation)
    }
}
