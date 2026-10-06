import Foundation
import Testing
@testable import ShinLyricsProvider

// 测试夹具全部为原创虚构内容：歌名、歌手、专辑、
// 歌词行均为编造，不使用任何真实歌曲数据；HTTP 层经 URLProtocol 拦截，
// 单测不访问真实网络。

/// 请求拦截器：按最近一次注册的 handler 返回响应或抛错。
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    // URLProtocol 钩子要求 class 方法 override（static 不可 override），规则豁免。
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// 注册响应体（200 + JSON 文本）。
    static func respond(json: String, status: Int = 200) {
        handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
    }

    /// 注册网络层失败。
    static func failNetwork() {
        handler = { _ in throw URLError(.notConnectedToInternet) }
    }

    static func reset() {
        handler = nil
    }

    /// 构造走本拦截器的客户端（测试注入用）。
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - 虚构搜索/歌词响应夹具

enum Fixtures {
    /// 两首虚构候选：同名精确 + 带 Live 后缀变体。
    static let searchJSON = #"""
    {"code":200,"result":{"songCount":2,"songs":[
      {"id":1001,"name":"测试歌A","duration":234567,
       "artists":[{"name":"虚拟歌手X"}],"album":{"name":"虚构专辑一"}},
      {"id":1002,"name":"测试歌A (Live版)","duration":251234,
       "artists":[{"name":"虚拟歌手X"},{"name":"客串歌手Y"}],"album":{"name":""}}
    ]}}
    """#

    /// 零结果响应：result 无 songs 键。
    static let emptySearchJSON = #"{"code":200,"result":{"songCount":0}}"#

    /// 原文 + 翻译歌词（虚构行）。
    static let lyricsJSON = #"""
    {"sgc":false,"nolyric":false,
     "lrc":{"version":5,"lyric":"[00:01.000]虚构原文行一\n[00:05.500]虚构原文行二"},
     "tlyric":{"lyric":"[00:01.000]虚构译文行一\n[00:05.500]虚构译文行二"}}
    """#

    /// 服务端明确无歌词。
    static let noLyricsJSON = #"{"nolyric":true}"#

    /// 原文歌词字段为空的响应。
    static let missingLrcJSON = #"{"sgc":false,"lrc":{"version":1,"lyric":""}}"#

    /// 原文位为空、歌词文本在翻译位；行内容为虚构。
    static let lyricsOnlyInTranslationJSON = #"""
    {"sgc":false,"lrc":{"version":1,"lyric":""},
     "tlyric":{"version":2,"lyric":"[00:15.437]虚构原文位空测试行\n[00:18.380]第二行虚构测试文本"}}
    """#
}
