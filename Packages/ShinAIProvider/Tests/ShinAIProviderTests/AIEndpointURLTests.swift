import Foundation
import Testing
@testable import ShinAIProvider

struct AIEndpointURLTests {
    @Test("默认会话禁用 Cookie 存储、接收与发送")
    func defaultSessionDisablesCookies() {
        let session = OpenAICompatibleClient.makeDefaultSession()
        #expect(session.configuration.httpCookieStorage == nil)
        #expect(session.configuration.httpCookieAcceptPolicy == .never)
        #expect(!session.configuration.httpShouldSetCookies)
    }

    @Test("同源重定向允许更换路径，按标准端口和主机大小写比较", arguments: [
        ("https://api.example.test/v1/chat/completions", "HTTPS://API.EXAMPLE.TEST:443/chat/completions"),
        ("https://api.example.test:443/v1/chat/completions", "https://api.example.test/chat/completions"),
        ("http://LOCALHOST/v1/chat/completions", "http://localhost:80/chat/completions"),
        ("http://[::1]:11434/v1/chat/completions", "http://[::1]:11434/chat/completions")
    ])
    func sameOriginAllowsNewRoute(original: String, destination: String) throws {
        let originalURL = try #require(URL(string: original))
        let destinationURL = try #require(URL(string: destination))
        #expect(AIEndpointURL.isSameOrigin(from: originalURL, to: destinationURL))
    }

    @Test("重定向拒绝更换协议、主机、端口或使用内嵌用户信息", arguments: [
        "http://api.example.test:443/chat/completions",
        "https://other.example.test/chat/completions",
        "https://api.example.test:444/chat/completions",
        "https://user@api.example.test/chat/completions",
        "https://:pass@api.example.test/chat/completions",
        "https://@api.example.test/chat/completions",
        "/v2/chat/completions"
    ])
    func redirectRequiresSameOriginWithoutUserInfo(destination: String) throws {
        let originalURL = try #require(URL(string: "https://api.example.test/v1/chat/completions"))
        let destinationURL = try #require(URL(string: destination))
        #expect(!AIEndpointURL.isSameOrigin(from: originalURL, to: destinationURL))
    }
}
