import Foundation
import Testing
@testable import ShinAIProvider

// 测试夹具全部为原创虚构文本；HTTP 层经 URLProtocol 拦截，绝不访问真实网络。

/// 请求拦截器：按最近一次注册的 handler 返回响应或抛错。
final class MockAIURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockAIURLProtocol.handler else {
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

    static func respondChatContent(
        _ content: String,
        model: String = "demo-model",
        status: Int = 200
    ) throws {
        let envelope: [String: Any] = [
            "model": model,
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": content
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        respondRaw(data: data, status: status)
    }

    static func respondRaw(json: String, status: Int = 200) {
        respondRaw(data: Data(json.utf8), status: status)
    }

    static func respondRaw(data: Data, status: Int = 200) {
        handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
    }

    static func failNetwork() {
        handler = { _ in throw URLError(.notConnectedToInternet) }
    }

    static func reset() {
        handler = nil
    }

    static func makeClient(
        credentialStore: (any AICredentialStoring)? = nil
    ) -> OpenAICompatibleClient {
        let session = OpenAICompatibleClient.makeDefaultSession(
            protocolClasses: [MockAIURLProtocol.self]
        )
        return OpenAICompatibleClient(session: session, credentialStore: credentialStore)
    }

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            guard readCount > 0 else { break }
            data.append(buffer, count: readCount)
        }
        return data
    }
}
