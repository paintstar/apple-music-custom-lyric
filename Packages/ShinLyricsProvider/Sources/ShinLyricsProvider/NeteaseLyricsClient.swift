import CommonCrypto
import CryptoKit
import Foundation

// 网易云歌词 HTTP 客户端。
//
// 网络与响应边界：
// - 搜索走 music.163.com 的明文 GET（`/api/search/get`）；歌词走
//   interface3.music.163.com 的 eapi 端点（`/eapi/song/lyric`，POST）。
//   二者为网易云客户端实际使用的未公开接口，无官方文档，随时可能变更——
//   所有结构解析失败都归为 apiChanged，绝不猜测字段含义。
// - 歌词使用 eapi，以兼容明文接口可能只返回翻译字段、原文字段为空的响应。
//   eapi 加密使用公开协议实现中的固定常量（见下方注释），不是账号凭据。
// - 用户文本只经 URL query 参数值（百分号编码）传递，不拼接任何可执行内容。
// - 请求串行 + 最小间隔（默认 1.5s，礼貌限速）；不并发轰炸接口。
// - 本模块不读不存任何凭据；匿名访问拿不到的内容如实归类 restricted。

/// 网易云歌词客户端。actor 串行化全部请求（限速在先），
/// URLSession 可注入（测试经 URLProtocol 拦截，不打真实网络）。
public actor NeteaseLyricsClient {

    /// 请求之间的最小间隔（礼貌限速）。测试可注入更小值。
    private let minimumRequestInterval: TimeInterval
    /// 上次请求放行时刻；nil = 尚未发过请求。
    private var lastRequestAt: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    private let session: URLSession

    /// 端点与固定请求头。host 集中定义，便于审计脚本核对（scripts/audit-outbound.sh）。
    public static let apiHost = "music.163.com"
    public static let eapiHost = "interface3.music.163.com"
    public static let searchPath = "/api/search/get"
    public static let eapiLyricPath = "/eapi/song/lyric"
    /// eapi 加密体内的业务路径。
    private static let eapiLyricAPIPath = "/api/song/lyric"
    /// 匿名请求的固定兼容标识；系统字段不代表运行机器或用户身份。
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ShinApple/0.1.0 (lyrics fetch)"

    // eapi 协议固定常量（公开逆向资料，如 NeteaseCloudMusicApi 的 eapi 封装；
    // 对所有客户端一致，不是本机或账号凭据，无保密性要求）。
    private static let eapiAESKey = "e82ckenh8dichen8"
    private static let eapiSeparator = "-36cd479b6b5-"
    private static let eapiDigestSuffix = "md5forencrypt"

    public init(
        session: URLSession = NeteaseLyricsClient.makeDefaultSession(),
        minimumRequestInterval: TimeInterval = 1.5
    ) {
        self.session = session
        self.minimumRequestInterval = minimumRequestInterval
    }

    /// 默认会话：短超时，不跟随缓存（歌词/搜索结果实时性优先）。
    public static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    // MARK: - 搜索

    /// 按关键词搜索候选曲目（type=1 单曲）。
    /// - Throws: `NeteaseLyricsError`。空关键词抛 `emptyQuery`；零结果抛 `noResults`。
    public func searchSongs(query: String, limit: Int = 30) async throws -> [NeteaseSongCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NeteaseLyricsError.emptyQuery }
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.apiHost
        components.path = Self.searchPath
        components.queryItems = [
            URLQueryItem(name: "s", value: trimmed),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 100)))),
            URLQueryItem(name: "offset", value: "0")
        ]
        let data = try await get(components.url!)
        let root = try Self.decodeObject(from: data)
        // 零结果时网易云返回 result 为空对象（无 songs 键）——如实区分。
        guard let result = root["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]]
        else {
            if let code = root["code"] as? Int, code != 200 {
                throw NeteaseLyricsError.apiChanged("搜索返回 code=\(code)")
            }
            throw NeteaseLyricsError.noResults
        }
        guard !songs.isEmpty else { throw NeteaseLyricsError.noResults }
        return songs.compactMap(Self.decodeCandidate)
    }

    /// 取指定曲目的歌词文本（原文 + 可选翻译）。走 eapi 加密端点。
    /// - Throws: `NeteaseLyricsError`。服务端标记无歌词抛 `noLyrics`；
    ///   原文与翻译字段全为空同样归为 `noLyrics`（不为空文本冒充成功）。
    public func fetchLyrics(songId: Int64) async throws -> NeteaseLyrics {
        // eapi：业务参数（id 与歌词开关）加密进 POST body，query 不带业务数据。
        let body: [String: Any] = [
            "header": ["os": "pc", "appver": "2.10.6"], // eapi 兼容字段，版本指网易云客户端，不是本应用。
            "id": String(songId),
            "lv": -1,   // 原文
            "kv": -1,   // 卡拉OK逐字（不使用，按端点惯例请求）
            "tv": -1,   // 翻译
            "rv": -1
        ]
        let params = try Self.eapiParams(apiPath: Self.eapiLyricAPIPath, body: body)
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.eapiHost
        components.path = Self.eapiLyricPath
        guard let url = components.url else {
            throw NeteaseLyricsError.apiChanged("eapi URL 构造失败")
        }
        let data = try await post(url: url, formBody: "params=\(params)")
        let root = try Self.decodeObject(from: data)
        if let code = root["code"] as? Int, code != 200 {
            throw NeteaseLyricsError.apiChanged("歌词 eapi 返回 code=\(code)")
        }
        if root["nolyric"] as? Bool == true {
            throw NeteaseLyricsError.noLyrics
        }
        let originalField = Self.lyricText(in: root, key: "lrc")
        let translatedField = Self.lyricText(in: root, key: "tlyric")

        // 网易云存在「原文位为空、整份歌词文本放在翻译位」的曲目
        // （明文老接口形态；eapi 亦不排除），此时以翻译位文本作为歌词原文，
        // 不再叠加翻译位。
        let originalLRC: String
        let translatedLRC: String?
        if let originalField {
            originalLRC = originalField
            translatedLRC = translatedField
        } else if let translatedField {
            originalLRC = translatedField
            translatedLRC = nil
        } else {
            throw NeteaseLyricsError.noLyrics
        }
        return NeteaseLyrics(
            songId: songId,
            originalLRC: originalLRC,
            translatedLRC: translatedLRC
        )
    }

    /// 取歌词字段文本；字段缺失或全空白返回 nil。
    private static func lyricText(in root: [String: Any], key: String) -> String? {
        guard let text = (root[key] as? [String: Any])?["lyric"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - eapi 参数加密（公开协议常量，非凭据）

    /// 构造 eapi `params`（大写 hex）：
    /// digest = MD5("nobody{path}use{text}md5forencrypt")；
    /// payload = "{path}-36cd479b6b5-{text}-36cd479b6b5-{digest}"；
    /// params = AES-128-ECB(PKCS7, key=e82ckenh8dichen8).hex.uppercase。
    static func eapiParams(apiPath: String, body: [String: Any]) throws -> String {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: bodyData, encoding: .utf8)
        else {
            throw NeteaseLyricsError.apiChanged("eapi 请求体构造失败")
        }
        let digestInput = "nobody\(apiPath)use\(text)\(Self.eapiDigestSuffix)"
        let digest = Insecure.MD5
            .hash(data: Data(digestInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let payload = "\(apiPath)\(Self.eapiSeparator)\(text)\(Self.eapiSeparator)\(digest)"
        let encrypted = try aes128ECBEncrypt(Data(payload.utf8), key: Data(Self.eapiAESKey.utf8))
        return encrypted.map { String(format: "%02X", $0) }.joined()
    }

    /// AES-128-ECB + PKCS7（CryptoKit 不提供 ECB；用系统 CommonCrypto）。
    private static func aes128ECBEncrypt(_ plaintext: Data, key: Data) throws -> Data {
        var output = Data(repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputRaw in
            key.withUnsafeBytes { keyRaw in
                plaintext.withUnsafeBytes { plainRaw in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyRaw.baseAddress,
                        kCCKeySizeAES128,
                        nil,
                        plainRaw.baseAddress,
                        plaintext.count,
                        outputRaw.baseAddress,
                        outputRaw.count,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw NeteaseLyricsError.apiChanged("AES 加密失败（CCCrypt 状态 \(status)）")
        }
        return output.prefix(outputLength)
    }

    // MARK: - 请求执行（限速在先）

    private func get(_ url: URL?) async throws -> Data {
        guard let url else { throw NeteaseLyricsError.apiChanged("URL 构造失败") }
        await paceRequests()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    /// eapi POST：application/x-www-form-urlencoded，body 为 `params=<hex>`；
    /// 端点惯例携带 `os=pc` Cookie（接口形态参数，非账号态）。
    private func post(url: URL, formBody: String) async throws -> Data {
        await paceRequests()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(formBody.utf8)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("os=pc", forHTTPHeaderField: "Cookie")
        return try await perform(request)
    }

    /// 执行请求并统一映射网络/HTTP 错误。
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NeteaseLyricsError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NeteaseLyricsError.apiChanged("非 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw NeteaseLyricsError.httpStatus(http.statusCode)
        }
        return data
    }

    /// 串行限速：距上次请求不足最小间隔时挂起等待。
    private func paceRequests() async {
        if let last = lastRequestAt {
            let elapsed = clock.now - last
            let minimum = Duration.seconds(minimumRequestInterval)
            if elapsed < minimum {
                try? await Task.sleep(for: minimum - elapsed)
            }
        }
        lastRequestAt = clock.now
    }

    // MARK: - JSON 解析（结构不符一律 apiChanged，不猜测）

    private static func decodeObject(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else {
            throw NeteaseLyricsError.apiChanged("响应不是 JSON 对象")
        }
        return root
    }

    private static func decodeCandidate(_ song: [String: Any]) -> NeteaseSongCandidate? {
        guard let id = song["id"] as? Int64 ?? (song["id"] as? Int).map(Int64.init),
              let name = song["name"] as? String
        else { return nil }
        let artists = (song["artists"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        let album = (song["album"] as? [String: Any])?["name"] as? String
        let duration = (song["duration"] as? Int).map(Int64.init)
            ?? song["duration"] as? Int64
        return NeteaseSongCandidate(
            songId: id,
            title: name,
            artists: artists,
            album: (album?.isEmpty == true) ? nil : album,
            durationMs: duration
        )
    }
}
