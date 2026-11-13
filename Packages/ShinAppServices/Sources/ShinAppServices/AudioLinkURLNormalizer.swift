import Foundation

/// 链接导入识别出的常见平台类型，用于自动精简追踪参数与格式引导。
public enum AudioLinkPlatform: String, CaseIterable, Equatable, Sendable {
    case bilibili
    case youtube
    case netease
    case other

    public var displayName: String {
        switch self {
        case .bilibili: return "B 站"
        case .youtube: return "YouTube"
        case .netease: return "网易云音乐"
        case .other: return "通用链接"
        }
    }

    public var formatHint: String {
        switch self {
        case .bilibili: return "https://www.bilibili.com/video/BV...（多 P 可加 ?p=1）"
        case .youtube: return "https://www.youtube.com/watch?v=..."
        case .netease: return "https://music.163.com/song?id=..."
        case .other: return "https://...（具体视频或音频页面链接）"
        }
    }
}

/// 链接检查与规范化结果。
public struct AudioLinkNormalization: Equatable, Sendable {
    public var normalizedURLString: String
    public var platform: AudioLinkPlatform
    public var wasModified: Bool
    public var notice: String?
    public var formatWarning: String?

    public init(
        normalizedURLString: String,
        platform: AudioLinkPlatform,
        wasModified: Bool,
        notice: String? = nil,
        formatWarning: String? = nil
    ) {
        self.normalizedURLString = normalizedURLString
        self.platform = platform
        self.wasModified = wasModified
        self.notice = notice
        self.formatWarning = formatWarning
    }
}

/// 纯本地链接规范化器：提取分享文案中的链接、识别平台、移除追踪参数并检查页面格式。
public enum AudioLinkURLNormalizer {
    private struct PlatformNormalization {
        let url: String
        let platform: AudioLinkPlatform
        let warning: String?
    }

    private static let trackingQueryNames: Set<String> = [
        "spm_id_from",
        "vd_source",
        "share_source",
        "share_medium",
        "utm_source",
        "utm_medium",
        "utm_campaign",
        "utm_term",
        "utm_content",
        "si",
        "feature",
        "pp"
    ]

    private static let delimiterScalars = CharacterSet(
        charactersIn: "\"'<>「」【】《》，。；！？、"
    )

    public static func inspect(_ rawInput: String) -> AudioLinkNormalization? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }

        guard let extracted = extractURLCandidate(from: trimmed) else { return nil }
        guard let components = URLComponents(string: extracted.urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = components.host,
              !rawHost.isEmpty else {
            return nil
        }

        let host = rawHost.lowercased()
        let result: PlatformNormalization
        if host == "b23.tv" || host == "www.b23.tv" {
            result = normalizeBilibiliShort(components: components, rawURL: extracted.urlString)
        } else if host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
            result = normalizeBilibili(components: components, rawURL: extracted.urlString)
        } else if host == "youtu.be" || host == "www.youtu.be" {
            result = normalizeYouTubeShort(components: components, rawURL: extracted.urlString)
        } else if isYouTubeHost(host) {
            result = normalizeYouTube(components: components, host: host, rawURL: extracted.urlString)
        } else {
            let platform: AudioLinkPlatform = isNeteaseHost(host) ? .netease : .other
            let cleaned = stripTrackingParameters(from: components, fallback: extracted.urlString)
            result = PlatformNormalization(url: cleaned, platform: platform, warning: nil)
        }

        let wasModified = result.url != trimmed
        let urlChangedAfterExtraction = result.url != extracted.urlString
        let notice = buildNotice(
            platform: result.platform,
            extractedFromText: extracted.extractedFromText,
            urlChangedAfterExtraction: urlChangedAfterExtraction,
            hasWarning: result.warning != nil
        )
        return AudioLinkNormalization(
            normalizedURLString: result.url,
            platform: result.platform,
            wasModified: wasModified,
            notice: notice,
            formatWarning: result.warning
        )
    }

    public static func normalize(_ rawInput: String) -> String {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return inspect(trimmed)?.normalizedURLString ?? trimmed
    }

    // MARK: - 链接提取与平台规范化

    private static func extractURLCandidate(from trimmed: String) -> (urlString: String, extractedFromText: Bool)? {
        let lower = trimmed.lowercased()
        let startsWithHTTP = lower.hasPrefix("https://") || lower.hasPrefix("http://")
        if startsWithHTTP {
            let hasWhitespaceOrControl = trimmed.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }
            if hasWhitespaceOrControl {
                return nil
            }
            return (trimmed, false)
        }

        let httpsRange = trimmed.range(of: "https://", options: .caseInsensitive)
        let httpRange = trimmed.range(of: "http://", options: .caseInsensitive)
        let startRange: Range<String.Index>?
        switch (httpsRange, httpRange) {
        case let (a?, b?):
            startRange = a.lowerBound <= b.lowerBound ? a : b
        case let (a?, nil):
            startRange = a
        case let (nil, b?):
            startRange = b
        case (nil, nil):
            startRange = nil
        }
        guard let start = startRange?.lowerBound else { return nil }

        var end = start
        while end < trimmed.endIndex {
            let ch = trimmed[end]
            let scalars = ch.unicodeScalars
            let stops = scalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
                    || delimiterScalars.contains($0)
            }
            if stops { break }
            end = trimmed.index(after: end)
        }
        let candidate = String(trimmed[start..<end])
        return candidate.isEmpty ? nil : (candidate, true)
    }

    private static func normalizeBilibiliShort(
        components: URLComponents,
        rawURL: String
    ) -> PlatformNormalization {
        let segments = pathSegments(from: components.path)
        guard segments.count == 1, !segments[0].isEmpty else {
            return PlatformNormalization(
                url: rawURL,
                platform: .bilibili,
                warning: "B 站短链格式不完整，应为 https://b23.tv/<短码>"
            )
        }
        return PlatformNormalization(url: "https://b23.tv/\(segments[0])", platform: .bilibili, warning: nil)
    }

    private static func normalizeBilibili(
        components: URLComponents,
        rawURL: String
    ) -> PlatformNormalization {
        let segments = pathSegments(from: components.path)
        if segments.count >= 2, segments[0].lowercased() == "video" {
            let videoID = segments[1]
            if isValidBilibiliVideoID(videoID) {
                let normalizedID = canonicalBilibiliVideoID(videoID)
                var base = "https://www.bilibili.com/video/\(normalizedID)"
                if let page = validBilibiliPageParam(from: components.queryItems) {
                    base += "?p=\(page)"
                }
                return PlatformNormalization(url: base, platform: .bilibili, warning: nil)
            }
        }
        if segments.count >= 2, segments[0].lowercased() == "audio" {
            let audioID = segments[1]
            if isValidBilibiliAudioID(audioID) {
                return PlatformNormalization(
                    url: "https://www.bilibili.com/audio/\(audioID.lowercased())",
                    platform: .bilibili,
                    warning: nil
                )
            }
        }
        return PlatformNormalization(
            url: rawURL,
            platform: .bilibili,
            warning: "B 站链接需指向具体视频或音频页，例如：https://www.bilibili.com/video/BV..."
        )
    }

    private static func normalizeYouTubeShort(
        components: URLComponents,
        rawURL: String
    ) -> PlatformNormalization {
        let segments = pathSegments(from: components.path)
        guard segments.count == 1, !segments[0].isEmpty else {
            return PlatformNormalization(
                url: rawURL,
                platform: .youtube,
                warning: "YouTube 短链格式不完整，应为 https://youtu.be/<视频ID>"
            )
        }
        return PlatformNormalization(url: "https://youtu.be/\(segments[0])", platform: .youtube, warning: nil)
    }

    private static func normalizeYouTube(
        components: URLComponents,
        host: String,
        rawURL: String
    ) -> PlatformNormalization {
        let canonicalHost = host == "music.youtube.com" ? "music.youtube.com" : "www.youtube.com"
        let segments = pathSegments(from: components.path)
        if segments == ["watch"] {
            if let videoID = components.queryItems?
                .first(where: { $0.name == "v" })?
                .value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !videoID.isEmpty {
                return PlatformNormalization(
                    url: "https://\(canonicalHost)/watch?v=\(videoID)",
                    platform: .youtube,
                    warning: nil
                )
            }
            return PlatformNormalization(
                url: rawURL,
                platform: .youtube,
                warning: "YouTube 播放链接缺少 v 视频参数，例如：https://www.youtube.com/watch?v=..."
            )
        }
        if segments.count == 2, segments[0] == "shorts", !segments[1].isEmpty {
            return PlatformNormalization(
                url: "https://\(canonicalHost)/shorts/\(segments[1])",
                platform: .youtube,
                warning: nil
            )
        }
        return PlatformNormalization(
            url: rawURL,
            platform: .youtube,
            warning: "YouTube 链接需指向具体视频页，例如：https://www.youtube.com/watch?v=..."
        )
    }

    private static func stripTrackingParameters(from components: URLComponents, fallback: String) -> String {
        var copy = components
        if let items = copy.queryItems {
            let filtered = items.filter { !trackingQueryNames.contains($0.name.lowercased()) }
            copy.queryItems = filtered.isEmpty ? nil : filtered
        }
        return copy.string ?? fallback
    }

    private static func buildNotice(
        platform: AudioLinkPlatform,
        extractedFromText: Bool,
        urlChangedAfterExtraction: Bool,
        hasWarning: Bool
    ) -> String? {
        guard !hasWarning else { return nil }
        if extractedFromText && urlChangedAfterExtraction {
            return "已从分享文本提取链接，并自动裁剪多余追踪参数"
        }
        if extractedFromText {
            return "已从分享文本中自动提取链接"
        }
        guard urlChangedAfterExtraction else { return nil }
        switch platform {
        case .bilibili:
            return "已自动去除 B 站追踪参数并规范化为标准视频链接"
        case .youtube:
            return "已自动去除 YouTube 多余追踪参数并规范化链接"
        case .netease, .other:
            return "已自动去除多余追踪参数"
        }
    }

    // MARK: - 字符与路径辅助

    private static func pathSegments(from path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtube.com"
            || host == "www.youtube.com"
            || host == "m.youtube.com"
            || host == "music.youtube.com"
    }

    private static func isNeteaseHost(_ host: String) -> Bool {
        host == "music.163.com" || host.hasSuffix(".music.163.com")
    }

    private static func isValidBilibiliVideoID(_ segment: String) -> Bool {
        if segment.hasPrefix("BV"), segment.count > 2 {
            return segment.dropFirst(2).unicodeScalars.allSatisfy(isASCIIAlphanumeric)
        }
        if segment.lowercased().hasPrefix("av"), segment.count > 2 {
            return segment.dropFirst(2).unicodeScalars.allSatisfy(isASCIIDigit)
        }
        return false
    }

    private static func canonicalBilibiliVideoID(_ segment: String) -> String {
        segment.hasPrefix("BV") ? segment : "av" + segment.dropFirst(2)
    }

    private static func isValidBilibiliAudioID(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        guard lower.hasPrefix("au"), lower.count > 2 else { return false }
        return lower.dropFirst(2).unicodeScalars.allSatisfy(isASCIIDigit)
    }

    private static func validBilibiliPageParam(from queryItems: [URLQueryItem]?) -> String? {
        guard let raw = queryItems?.first(where: { $0.name == "p" })?.value,
              !raw.isEmpty,
              raw.unicodeScalars.allSatisfy(isASCIIDigit),
              let value = Int(raw),
              value >= 1 else {
            return nil
        }
        return String(value)
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIDigit(scalar)
            || (0x41...0x5A).contains(scalar.value)
            || (0x61...0x7A).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
    }
}
