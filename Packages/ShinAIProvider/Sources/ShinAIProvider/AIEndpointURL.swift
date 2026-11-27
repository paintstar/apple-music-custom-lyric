import Foundation

enum AIEndpointURL {
    static func chatCompletions(from baseURL: URL) -> URL {
        if baseURL.path.hasSuffix("/chat/completions") {
            return baseURL
        }
        return baseURL.appendingPathComponent("chat/completions")
    }

    static func isSameOrigin(from originalURL: URL?, to destinationURL: URL?) -> Bool {
        guard let originalOrigin = Origin(originalURL), let destinationOrigin = Origin(destinationURL) else {
            return false
        }
        return originalOrigin == destinationOrigin
    }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL?) {
            guard let url,
                  url.user() == nil, url.password() == nil,
                  let scheme = url.scheme?.lowercased(),
                  let host = url.host()?.lowercased(), !host.isEmpty
            else { return nil }

            // 未显式指定端口时，按 HTTP(S) 标准端口比较来源。
            let defaultPort: Int
            switch scheme {
            case "https": defaultPort = 443
            case "http": defaultPort = 80
            default: return nil
            }
            let port = url.port ?? defaultPort
            guard (1...65_535).contains(port) else { return nil }

            self.scheme = scheme
            self.host = host
            self.port = port
        }
    }
}
