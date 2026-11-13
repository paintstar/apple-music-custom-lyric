import Foundation
import os
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

    public init(
        urlString: String,
        metadata: AudioLinkMetadata = AudioLinkMetadata(),
        embedThumbnail: Bool = true,
        cookieSource: AudioCookieSource = .none,
        keepCopyDirectory: URL? = nil
    ) {
        self.urlString = urlString
        self.metadata = metadata
        self.embedThumbnail = embedThumbnail
        self.cookieSource = cookieSource
        self.keepCopyDirectory = keepCopyDirectory
    }
}

/// 链接导入的实时阶段进度。
public enum AudioLinkImportStage: Equatable, Sendable {
    case validating
    case downloading(progress: Double?, detail: String?)
    case tagging
    case importingToMusic
    case savingCopy
}

/// 链接导入成功结果。
public struct AudioLinkImportResult: Equatable, Sendable {
    public var importedTrack: MusicLibraryImportedTrack
    public var savedCopyURL: URL?
    public var keptInStaging: Bool
    public var stagedFileURL: URL?

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

// MARK: - 纯参数校验与路径/进度辅助（不含子进程调用）

extension LiveAudioLinkImportService {

    static func validateURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            throw AudioLinkImportError.invalidURL
        }
        return url
    }

    static func validateCookieSource(_ cookieSource: AudioCookieSource) throws {
        guard case .cookiesFile(let url) = cookieSource else { return }
        var isDirectory: ObjCBool = false
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw AudioLinkImportError.invalidCookiesFile
        }
    }

    static func buildYtdlpArguments(
        url: URL,
        request: AudioLinkImportRequest,
        ffmpegURL: URL,
        outputTemplate: String
    ) -> [String] {
        var args: [String] = [
            "-x",
            "--audio-format", "m4a",
            "--audio-quality", "0",
            "--add-metadata",
            "--no-playlist",
            "--newline",
            "--ffmpeg-location", ffmpegURL.path
        ]
        if request.embedThumbnail {
            args.append("--embed-thumbnail")
        }
        switch request.cookieSource {
        case .none:
            break
        case .browser(let browser):
            args.append(contentsOf: ["--cookies-from-browser", browser.rawValue])
        case .cookiesFile(let cookieURL):
            args.append(contentsOf: ["--cookies", cookieURL.standardizedFileURL.path])
        }
        args.append(contentsOf: ["-o", outputTemplate, "--", url.absoluteString])
        return args
    }

    static func buildFfmpegArguments(
        sourceURL: URL,
        stagedURL: URL,
        metadata: AudioLinkMetadata
    ) -> [String] {
        var args: [String] = [
            "-y",
            "-i", sourceURL.path,
            "-map", "0",
            "-c", "copy"
        ]
        let fields: [(String, String)] = [
            ("title", metadata.title),
            ("artist", metadata.artist),
            ("album", metadata.album),
            ("genre", metadata.genre)
        ]
        for (key, rawValue) in fields {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                args.append(contentsOf: ["-metadata", "\(key)=\(trimmed)"])
            }
        }
        args.append(contentsOf: ["-movflags", "+faststart", stagedURL.path])
        return args
    }

    static func parseYtdlpProgress(from line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[download]") else { return nil }
        let afterTag = trimmed.dropFirst("[download]".count).drop(while: { $0.isWhitespace })
        let numberPart = afterTag.prefix(while: { $0.isNumber || $0 == "." })
        guard !numberPart.isEmpty,
              afterTag.dropFirst(numberPart.count).first == "%",
              let percent = Double(String(numberPart)),
              percent.isFinite else {
            return nil
        }
        return min(max(percent / 100.0, 0.0), 1.0)
    }

    static func findDownloadedM4A(in directory: URL) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = items.filter { url in
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? true
            return isRegular && url.pathExtension.lowercased() == "m4a"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let found = candidates.first else {
            throw AudioLinkImportError.downloadedAudioNotFound
        }
        return found.standardizedFileURL
    }

    static func sanitizedFileBaseName(preferredTitle: String, fallbackTitle: String) -> String {
        let trimmedPreferred = preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmedPreferred.isEmpty ? fallbackTitle : trimmedPreferred
        let filtered = raw.unicodeScalars.filter { scalar in
            scalar != "/" && scalar != ":" && !CharacterSet.controlCharacters.contains(scalar)
        }
        let cleaned = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "导入音频" : cleaned
    }

    static func uniqueDestinationURL(in directory: URL, baseName: String) -> URL {
        let primary = directory.appendingPathComponent("\(baseName).m4a")
        if !FileManager.default.fileExists(atPath: primary.path) {
            return primary
        }
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(baseName) (\(index)).m4a")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    static func searchDirectories(additionalPaths: [String] = []) -> [String] {
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true).path
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let raw = additionalPaths + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            localBin
        ] + envPaths

        var seen = Set<String>()
        var result: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static let defaultExecutableResolver: AudioExecutableResolver = { toolName, searchedDirectories in
        for directory in searchedDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(toolName)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    static func buildEnvironment(searchDirectories: [String], ffmpegDirectory: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var pathParts = [ffmpegDirectory] + searchDirectories
        var seen = Set<String>()
        pathParts = pathParts.filter { !$0.isEmpty && seen.insert($0).inserted }
        env["PATH"] = pathParts.joined(separator: ":")
        return env
    }

    static func defaultStagingRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("ShinApple/ImportedAudio", isDirectory: true)
    }

    static func conciseFailureDetail(_ output: AudioProcessOutput) -> String {
        let source = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? output.stdout
            : output.stderr
        let lines = source
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else {
            return "退出码 \(output.terminationStatus)"
        }
        return String(last.prefix(300))
    }
}

// MARK: - 管道行缓冲辅助

final class PipeLineBuffer: Sendable {
    private struct State: Sendable {
        var collected = Data()
        var lineBuffer = Data()
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ chunk: Data, onLine: @Sendable (String) -> Void) {
        let lines: [String] = state.withLock { s in
            guard !s.closed else { return [] }
            s.collected.append(chunk)
            s.lineBuffer.append(chunk)
            var extracted: [String] = []
            while let newlineIndex = s.lineBuffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = s.lineBuffer[..<newlineIndex]
                s.lineBuffer.removeSubrange(...newlineIndex)
                let line = (String(bytes: lineData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    extracted.append(line)
                }
            }
            return extracted
        }
        for line in lines {
            onLine(line)
        }
    }

    func finish() -> (shouldLeave: Bool, trailingLine: String?) {
        state.withLock { s in
            guard !s.closed else { return (false, nil) }
            s.closed = true
            guard !s.lineBuffer.isEmpty else { return (true, nil) }
            let trailing = (String(bytes: s.lineBuffer, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            s.lineBuffer.removeAll(keepingCapacity: false)
            return (true, trailing.isEmpty ? nil : trailing)
        }
    }

    func text() -> String {
        state.withLock { String(bytes: $0.collected, encoding: .utf8) ?? "" }
    }
}
