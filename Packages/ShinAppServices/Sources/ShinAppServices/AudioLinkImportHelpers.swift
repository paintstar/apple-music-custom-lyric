import Foundation
import os
import ShinAppleKit

// MARK: - 纯参数校验与路径/进度辅助（不含子进程调用）

extension LiveAudioLinkImportService {

    static func validateURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              let inspection = AudioLinkURLNormalizer.inspect(trimmed) else {
            throw AudioLinkImportError.invalidURL
        }
        if let warning = inspection.formatWarning {
            throw AudioLinkImportError.unsupportedPlatformURL(detail: warning)
        }
        let normalized = inspection.normalizedURLString
        guard !normalized.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }),
              let url = URL(string: normalized),
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
        outputTemplate: String,
        proxy: String? = nil
    ) -> [String] {
        var args: [String] = [
            "-x",
            "--audio-format", "m4a",
            "--audio-quality", request.audioQuality.rawValue,
            "--no-playlist",
            "--newline",
            "--ffmpeg-location", ffmpegURL.path
        ]
        if request.includeSourceMetadata {
            args.append("--add-metadata")
        }
        if request.embedThumbnail {
            args.append("--embed-thumbnail")
        }
        if let proxy, !proxy.isEmpty {
            args.append(contentsOf: ["--proxy", proxy])
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

    static func buildFfmpegTagArguments(
        sourceURL: URL,
        stagedURL: URL,
        metadata: AudioLinkMetadata,
        trimStart: String? = nil,
        trimEnd: String? = nil
    ) -> [String] {
        var args: [String] = [
            "-y",
            "-i", sourceURL.path,
            "-map", "0",
            "-c", "copy"
        ]
        var hasTrim = false
        if let trimStart, !trimStart.isEmpty {
            args.append(contentsOf: ["-ss", trimStart])
            hasTrim = true
        }
        if let trimEnd, !trimEnd.isEmpty {
            args.append(contentsOf: ["-to", trimEnd])
            hasTrim = true
        }
        if hasTrim {
            args.append(contentsOf: ["-avoid_negative_ts", "make_zero"])
        }
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

// MARK: - 裁剪时间与代理地址规范化

extension AudioLinkURLNormalizer {
    public static func normalizeTrimTime(_ raw: String) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("-"),
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }),
              parseTrimSeconds(trimmed) != nil else {
            throw AudioLinkImportError.invalidTrimTime(
                detail: "裁剪时间格式无效，请使用秒数、mm:ss 或 hh:mm:ss（如 00:15 或 01:23.5）。"
            )
        }
        return trimmed
    }

    public static func validateTrimRange(start: String, end: String) throws -> (start: String?, end: String?) {
        let normalizedStart = try normalizeTrimTime(start)
        let normalizedEnd = try normalizeTrimTime(end)
        if let s = normalizedStart, let e = normalizedEnd,
           let startSeconds = parseTrimSeconds(s), let endSeconds = parseTrimSeconds(e),
           startSeconds >= endSeconds {
            throw AudioLinkImportError.invalidTrimTime(detail: "裁剪结束时间必须晚于起始时间。")
        }
        return (normalizedStart, normalizedEnd)
    }

    public static func normalizeProxy(_ raw: String) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("-"),
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AudioLinkImportError.invalidProxy(
                detail: "代理地址格式无效，请使用 http://、https:// 或 socks5:// 地址。"
            )
        }
        let candidate = (!trimmed.contains("://") && trimmed.contains(":")) ? "http://\(trimmed)" : trimmed
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "socks5", "socks5h"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            throw AudioLinkImportError.invalidProxy(
                detail: "代理地址仅支持 http、https、socks5 或 socks5h，且须包含主机名（如 127.0.0.1:7890）。"
            )
        }
        return components.string ?? candidate
    }

    private static func parseTrimSeconds(_ value: String) -> Double? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            return parseSecondsComponent(parts[0])
        case 2:
            guard let minutes = parseIntegerComponent(parts[0]),
                  let seconds = parseSecondsComponent(parts[1]),
                  seconds < 60 else {
                return nil
            }
            return Double(minutes) * 60.0 + seconds
        case 3:
            guard let hours = parseIntegerComponent(parts[0]),
                  let minutes = parseIntegerComponent(parts[1]),
                  minutes < 60,
                  let seconds = parseSecondsComponent(parts[2]),
                  seconds < 60 else {
                return nil
            }
            return Double(hours) * 3600.0 + Double(minutes) * 60.0 + seconds
        default:
            return nil
        }
    }

    private static func parseIntegerComponent(_ text: String) -> Int? {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(isASCIIDigit) else { return nil }
        return Int(text)
    }

    private static func parseSecondsComponent(_ text: String) -> Double? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 {
            return parseIntegerComponent(parts[0]).map(Double.init)
        }
        if parts.count == 2,
           !parts[0].isEmpty, !parts[1].isEmpty,
           parts[0].unicodeScalars.allSatisfy(isASCIIDigit),
           parts[1].unicodeScalars.allSatisfy(isASCIIDigit) {
            return Double(text)
        }
        return nil
    }
}
