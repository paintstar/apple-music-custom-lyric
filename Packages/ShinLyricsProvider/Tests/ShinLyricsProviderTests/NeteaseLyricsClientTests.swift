import Foundation
import Testing
@testable import ShinLyricsProvider

// 客户端解析与错误分类单测（全部走 MockURLProtocol，不打真实网络）。
// 限速间隔注入 0：单测只验证分类正确性，不验证间隔（间隔由调用方节奏保证）。

@Suite("NeteaseLyricsClient", .serialized)
struct NeteaseLyricsClientTests {

    private func makeClient() -> NeteaseLyricsClient {
        NeteaseLyricsClient(session: MockURLProtocol.makeSession(), minimumRequestInterval: 0)
    }

    /// 期望表达式抛出指定 NeteaseLyricsError 并逐项核对。
    private func expectTypedError<T: Sendable>(
        _ expression: @autoclosure () async throws -> T,
        _ check: (NeteaseLyricsError) -> Void
    ) async {
        do {
            _ = try await expression()
            Issue.record("期望抛出 NeteaseLyricsError，但成功返回了")
        } catch let error as NeteaseLyricsError {
            check(error)
        } catch {
            Issue.record("期望 NeteaseLyricsError，实际抛出：\(error)")
        }
    }

    @Test("搜索：解析候选字段与搜索词透传")
    func searchParsesCandidates() async throws {
        var capturedQuery: String?
        MockURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            capturedQuery = components?.queryItems?.first(where: { $0.name == "s" })?.value
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Fixtures.searchJSON.utf8))
        }
        let client = makeClient()
        let candidates = try await client.searchSongs(query: "测试歌A")
        #expect(capturedQuery == "测试歌A")
        #expect(candidates.count == 2)

        let first = try #require(candidates.first)
        #expect(first.songId == 1001)
        #expect(first.title == "测试歌A")
        #expect(first.artists == ["虚拟歌手X"])
        #expect(first.album == "虚构专辑一")
        #expect(first.durationMs == 234_567)

        let second = try #require(candidates.last)
        #expect(second.artists == ["虚拟歌手X", "客串歌手Y"])
        // 空专辑名不冒充有值。
        #expect(second.album == nil)
        #expect(second.externalRef == "netease:song:1002")
    }

    @Test("搜索：零结果归类 noResults，不与失败混淆")
    func searchEmptyIsNoResults() async {
        MockURLProtocol.respond(json: Fixtures.emptySearchJSON)
        await expectTypedError(
            try await makeClient().searchSongs(query: "不存在的歌")
        ) { #expect($0 == .noResults) }
    }

    @Test("搜索：code 非 200 归类 apiChanged")
    func searchServerCodeIsApiChanged() async {
        MockURLProtocol.respond(json: #"{"code":400,"msg":"拒绝"}"#)
        await expectTypedError(
            try await makeClient().searchSongs(query: "任意词")
        ) { error in
            guard case .apiChanged = error else {
                Issue.record("期望 apiChanged，实际 \(error)")
                return
            }
        }
    }

    @Test("搜索：空白关键词拒绝在本地，不发请求")
    func searchEmptyQueryRejectedLocally() async {
        MockURLProtocol.reset()
        await expectTypedError(
            try await makeClient().searchSongs(query: "   ")
        ) { #expect($0 == .emptyQuery) }
    }

    @Test("歌词请求走 eapi 形态：POST + 加密 body + interface3 host")
    func lyricsRequestUsesEAPI() async throws {
        var captured: URLRequest?
        MockURLProtocol.handler = { request in
            captured = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Fixtures.lyricsJSON.utf8))
        }
        _ = try await makeClient().fetchLyrics(songId: 1001)
        let request = try #require(captured)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.host == "interface3.music.163.com")
        #expect(request.url?.path == "/eapi/song/lyric")
        let body = String(
            data: try #require(request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    guard read > 0 else { break }
                    data.append(buffer, count: read)
                }
                return data
            }),
            encoding: .utf8
        ) ?? ""
        #expect(body.hasPrefix("params="))
        let hex = String(body.dropFirst("params=".count))
        #expect(!hex.isEmpty)
        #expect(hex.allSatisfy { $0.isHexDigit && !$0.isLowercase })
        #expect(hex.count % 32 == 0)   // AES 块（16 字节 = 32 hex 字符）的整数倍
    }

    @Test("eapi 参数加密：结构自洽（含路径/分隔符/摘要，可确定性重现）")
    func eapiParamsStructure() throws {
        let body: [String: Any] = [
            "header": ["os": "pc"],
            "id": "1001",
            "lv": -1, "kv": -1, "tv": -1, "rv": -1
        ]
        let params = try NeteaseLyricsClient.eapiParams(
            apiPath: "/api/song/lyric", body: body
        )
        // 同一输入确定性输出（ECB 无 IV；body 经 JSONSerialization 键序在单次
        // 进程内稳定——此处只断言两次生成一致与基本形态）。
        let again = try NeteaseLyricsClient.eapiParams(
            apiPath: "/api/song/lyric", body: body
        )
        #expect(params == again)
        #expect(params.range(of: "^[0-9A-F]+$", options: .regularExpression) != nil)
    }

    @Test("歌词：原文与翻译文本原样取回")
    func lyricsFetchParsesText() async throws {
        MockURLProtocol.respond(json: Fixtures.lyricsJSON)
        let lyrics = try await makeClient().fetchLyrics(songId: 1001)
        #expect(lyrics.songId == 1001)
        #expect(lyrics.originalLRC.contains("虚构原文行一"))
        #expect(lyrics.originalLRC.contains("[00:05.500]虚构原文行二"))
        #expect(lyrics.translatedLRC?.contains("虚构译文行二") == true)
    }

    @Test("歌词：nolyric 明确归类无歌词")
    func lyricsNoLyricFlag() async {
        MockURLProtocol.respond(json: Fixtures.noLyricsJSON)
        await expectTypedError(
            try await makeClient().fetchLyrics(songId: 1)
        ) { #expect($0 == .noLyrics) }
    }

    @Test("歌词：原文字段为空归类无歌词，不返回空文本冒充成功")
    func lyricsEmptyTextIsNoLyrics() async {
        MockURLProtocol.respond(json: Fixtures.missingLrcJSON)
        await expectTypedError(
            try await makeClient().fetchLyrics(songId: 1)
        ) { #expect($0 == .noLyrics) }
    }

    @Test("歌词：HTTP 异常状态原样透传")
    func lyricsHTTPStatusPropagates() async {
        MockURLProtocol.respond(json: "{}", status: 503)
        await expectTypedError(
            try await makeClient().fetchLyrics(songId: 1)
        ) { #expect($0 == .httpStatus(503)) }
    }

    @Test("网络层失败归类 network，附中文说明")
    func networkFailureClassified() async {
        MockURLProtocol.failNetwork()
        await expectTypedError(
            try await makeClient().searchSongs(query: "测试")
        ) { error in
            guard case .network = error else {
                Issue.record("期望 network，实际 \(error)")
                return
            }
            #expect(error.userMessage.contains("网络"))
        }
    }

    @Test("歌词：原文位为空但翻译位有文本——以翻译位作为歌词原文")
    func lyricsOnlyInTranslationFallsBack() async throws {
        // 原文字段为空、翻译字段包含完整歌词时，仍应返回可导入的文本。
        // 修复前被误报 noLyrics；修复后 tlyric 文本即歌词原文，且不再叠加翻译。
        MockURLProtocol.respond(json: Fixtures.lyricsOnlyInTranslationJSON)
        let lyrics = try await makeClient().fetchLyrics(songId: 1)
        #expect(lyrics.originalLRC.contains("虚构原文位空测试行"))
        #expect(lyrics.originalLRC.contains("[00:18.380]"))
        #expect(lyrics.translatedLRC == nil)
    }

    @Test("歌词：翻译缺失时 translatedLRC 为 nil")
    func lyricsWithoutTranslation() async throws {
        MockURLProtocol.respond(
            json: #"{"lrc":{"version":1,"lyric":"[00:01.000]虚构原文行"}}"#
        )
        let lyrics = try await makeClient().fetchLyrics(songId: 7)
        #expect(lyrics.translatedLRC == nil)
    }
}
