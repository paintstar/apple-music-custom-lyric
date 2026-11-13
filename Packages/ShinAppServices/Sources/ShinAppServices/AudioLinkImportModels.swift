import Foundation
import ShinAppleKit

/// 链接导入音频时写入的自定义元数据；空字符串表示保留工具或源文件原有标签。
public struct AudioLinkMetadata: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String

    public init(title: String = "", artist: String = "", album: String = "", genre: String = "") {
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
    }
}

/// 支持从本地浏览器读取 Cookies 的浏览器类型，原始值对应 `yt-dlp --cookies-from-browser` 参数。
public enum AudioCookieBrowser: String, CaseIterable, Identifiable, Equatable, Sendable {
    case chrome
    case safari
    case edge
    case firefox
    case brave

    public var id: String { rawValue }

    public var shortName: String {
        switch self {
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .edge: return "Edge"
        case .firefox: return "Firefox"
        case .brave: return "Brave"
        }
    }

    public var displayName: String {
        switch self {
        case .chrome: return "Chrome 浏览器"
        case .safari: return "Safari 浏览器"
        case .edge: return "Edge 浏览器"
        case .firefox: return "Firefox 浏览器"
        case .brave: return "Brave 浏览器"
        }
    }
}

/// 链接下载阶段的 Cookies 来源；服务层绝不读取或记录 Cookies 内容。
public enum AudioCookieSource: Equatable, Sendable {
    case none
    case browser(AudioCookieBrowser)
    case cookiesFile(URL)
}

/// 链接下载并导入「音乐」资料库的请求参数。
public struct AudioLinkImportRequest: Equatable, Sendable {
    public var urlString: String
    public var metadata: AudioLinkMetadata
    public var embedThumbnail: Bool
    public var cookieSource: AudioCookieSource
    /// 非 nil 时在指定目录额外保留一份 `<安全标题>.m4a` 副本；nil 表示仅导入「音乐」资料库。
    public var keepCopyDirectory: URL?
    public var audioQuality: AudioQualityOption
    public var includeSourceMetadata: Bool
    public var trimStart: String
    public var trimEnd: String
    public var proxy: String

    public init(
        urlString: String,
        metadata: AudioLinkMetadata = AudioLinkMetadata(),
        embedThumbnail: Bool = true,
        cookieSource: AudioCookieSource = .none,
        keepCopyDirectory: URL? = nil,
        audioQuality: AudioQualityOption = .best,
        includeSourceMetadata: Bool = true,
        trimStart: String = "",
        trimEnd: String = "",
        proxy: String = ""
    ) {
        self.urlString = urlString
        self.metadata = metadata
        self.embedThumbnail = embedThumbnail
        self.cookieSource = cookieSource
        self.keepCopyDirectory = keepCopyDirectory
        self.audioQuality = audioQuality
        self.includeSourceMetadata = includeSourceMetadata
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.proxy = proxy
    }
}

/// 链接导入的实时阶段进度。
public enum AudioLinkImportStage: Equatable, Sendable {
    case validating
    case downloading(progress: Double?, detail: String?)
    case tagging
    case importingToMusic
    case savingCopy

    public var statusTitle: String {
        switch self {
        case .validating: return "正在校验链接与工具……"
        case .downloading: return "正在下载并提取音频……"
        case .tagging: return "正在写入歌曲标签与封面……"
        case .importingToMusic: return "正在导入「音乐」资料库……"
        case .savingCopy: return "正在保存本地 .m4a 副本……"
        }
    }
}

/// 链接导入成功结果。
public struct AudioLinkImportResult: Equatable, Sendable {
    public var importedTrack: MusicLibraryImportedTrack
    public var savedCopyURL: URL?
    public var keptInStaging: Bool
    public var stagedFileURL: URL?

    public var storageSummary: String {
        if keptInStaging, let stagedURL = stagedFileURL {
            return "「音乐」App 直接引用源文件，已在应用支持目录保留：\(stagedURL.path)"
        }
        if let resolved = importedTrack.resolvedFileURL {
            return "「音乐」App 已拷贝至媒体库（\(resolved.path)），临时暂存已清理。"
        }
        return "已完成导入「音乐」资料库。"
    }

    public init(
        importedTrack: MusicLibraryImportedTrack,
        savedCopyURL: URL? = nil,
        keptInStaging: Bool,
        stagedFileURL: URL? = nil
    ) {
        self.importedTrack = importedTrack
        self.savedCopyURL = savedCopyURL
        self.keptInStaging = keptInStaging
        self.stagedFileURL = stagedFileURL
    }
}

/// 本机命令行依赖探测结果。
public struct AudioToolAvailability: Equatable, Sendable {
    public var ytdlpURL: URL?
    public var ffmpegURL: URL?
    public var searchedPaths: [String]

    public var isReady: Bool { ytdlpURL != nil && ffmpegURL != nil }

    public init(ytdlpURL: URL? = nil, ffmpegURL: URL? = nil, searchedPaths: [String] = []) {
        self.ytdlpURL = ytdlpURL
        self.ffmpegURL = ffmpegURL
        self.searchedPaths = searchedPaths
    }
}

/// 链接导入错误类型，统一提供简体中文用户提示。
public enum AudioLinkImportError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case unsupportedPlatformURL(detail: String)
    case invalidTrimTime(detail: String)
    case invalidProxy(detail: String)
    case ytdlpNotFound(searchedPaths: [String])
    case ffmpegNotFound(searchedPaths: [String])
    case invalidCookiesFile
    case downloadFailed(detail: String)
    case taggingFailed(detail: String)
    case downloadedAudioNotFound
    case musicImportFailed(detail: String)
    case saveCopyFailed(detail: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请输入有效的 http 或 https 链接。"
        case .unsupportedPlatformURL(let detail),
             .invalidTrimTime(let detail),
             .invalidProxy(let detail):
            return detail
        case .ytdlpNotFound(let searchedPaths):
            return "未找到 yt-dlp 工具（已搜索：\(searchedPaths.joined(separator: "、"))）。请先安装 yt-dlp 后重试。"
        case .ffmpegNotFound(let searchedPaths):
            return "未找到 ffmpeg 工具（已搜索：\(searchedPaths.joined(separator: "、"))）。请先安装 ffmpeg 后重试。"
        case .invalidCookiesFile:
            return "指定的 Cookies 文件不存在或路径无效。"
        case .downloadFailed(let detail):
            return detail.isEmpty ? "音频下载失败，请检查链接或网络后重试。" : "音频下载失败：\(detail)"
        case .taggingFailed(let detail):
            return detail.isEmpty ? "写入音频元数据失败。" : "写入音频元数据失败：\(detail)"
        case .downloadedAudioNotFound:
            return "下载完成但未找到生成的 M4A 音频文件。"
        case .musicImportFailed(let detail):
            return detail.isEmpty ? "导入「音乐」资料库失败。" : "导入「音乐」资料库失败：\(detail)"
        case .saveCopyFailed(let detail):
            return detail.isEmpty ? "保存本地音频副本失败。" : "保存本地音频副本失败：\(detail)"
        case .cancelled:
            return "已取消链接导入。"
        }
    }
}

/// 子进程执行输出。
public struct AudioProcessOutput: Equatable, Sendable {
    public var terminationStatus: Int32
    public var stdout: String
    public var stderr: String

    public init(terminationStatus: Int32, stdout: String, stderr: String) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// 可执行文件探测回调，供测试注入替代本机 PATH 探测。
public typealias AudioExecutableResolver = @Sendable (_ toolName: String, _ searchedDirectories: [String]) -> URL?

/// 命令行工具运行协议，便于单元测试替换真实子进程。
public protocol AudioProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> AudioProcessOutput
}

/// 链接音频导入服务契约。
public protocol AudioLinkImporting: Sendable {
    func detectTools() async -> AudioToolAvailability
    func importFromLink(
        _ request: AudioLinkImportRequest,
        onStage: @escaping @Sendable (AudioLinkImportStage) -> Void
    ) async throws -> AudioLinkImportResult
}
