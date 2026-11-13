import Foundation
import os
import ShinAppleKit
import Testing
@testable import ShinAppServices

struct AudioLinkURLNormalizerTests {
    @Test("B 站链接裁剪追踪参数并保留合法分 P 参数")
    func bilibiliNormalization() throws {
        let dirty = "https://www.bilibili.com/video/BV1hAj16dESQ/?spm_id_from=333.337.search-card.all.click&vd_source=abc123"
        let cleanResult = try #require(AudioLinkURLNormalizer.inspect(dirty))
        #expect(cleanResult.platform == .bilibili)
        #expect(cleanResult.normalizedURLString == "https://www.bilibili.com/video/BV1hAj16dESQ")
        #expect(cleanResult.wasModified)
        #expect(cleanResult.formatWarning == nil)

        let multiPage = "https://m.bilibili.com/video/BV1hAj16dESQ/?p=2&vd_source=xyz&share_source=copy"
        let multiResult = try #require(AudioLinkURLNormalizer.inspect(multiPage))
        #expect(multiResult.normalizedURLString == "https://www.bilibili.com/video/BV1hAj16dESQ?p=2")
        #expect(multiResult.wasModified)

        let pageOne = "https://www.bilibili.com/video/BV1xx411c7mD?p=1"
        let pageOneResult = try #require(AudioLinkURLNormalizer.inspect(pageOne))
        #expect(pageOneResult.normalizedURLString == "https://www.bilibili.com/video/BV1xx411c7mD?p=1")
        #expect(!pageOneResult.wasModified)

        let audio = "https://www.bilibili.com/audio/au123456/?type=1"
        let audioResult = try #require(AudioLinkURLNormalizer.inspect(audio))
        #expect(audioResult.normalizedURLString == "https://www.bilibili.com/audio/au123456")

        let shortLink = "https://b23.tv/abcXYZ?share_medium=iphone"
        let shortResult = try #require(AudioLinkURLNormalizer.inspect(shortLink))
        #expect(shortResult.normalizedURLString == "https://b23.tv/abcXYZ")
        #expect(shortResult.platform == .bilibili)
    }

    @Test("分享文案自动提取链接并清理追踪参数")
    func shareTextExtraction() throws {
        let share = "【测试歌曲MV】 https://www.bilibili.com/video/BV1hAj16dESQ/?spm_id_from=333.999.0.0 快来听"
        let inspected = try #require(AudioLinkURLNormalizer.inspect(share))
        #expect(inspected.platform == .bilibili)
        #expect(inspected.normalizedURLString == "https://www.bilibili.com/video/BV1hAj16dESQ")
        #expect(inspected.wasModified)
        #expect(inspected.notice != nil)
        #expect(inspected.formatWarning == nil)
        #expect(AudioLinkURLNormalizer.normalize(share) == "https://www.bilibili.com/video/BV1hAj16dESQ")
    }

    @Test("YouTube 与通用链接规范化并移除追踪参数")
    func youtubeAndOtherNormalization() throws {
        let watch = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ&si=track123"
        let watchResult = try #require(AudioLinkURLNormalizer.inspect(watch))
        #expect(watchResult.platform == .youtube)
        #expect(watchResult.normalizedURLString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(watchResult.wasModified)

        let musicWatch = "https://music.youtube.com/watch?v=abc123&si=xyz"
        let musicResult = try #require(AudioLinkURLNormalizer.inspect(musicWatch))
        #expect(musicResult.platform == .youtube)
        #expect(musicResult.normalizedURLString == "https://music.youtube.com/watch?v=abc123")

        let shortYT = "https://youtu.be/dQw4w9WgXcQ?si=sharetoken"
        let shortResult = try #require(AudioLinkURLNormalizer.inspect(shortYT))
        #expect(shortResult.platform == .youtube)
        #expect(shortResult.normalizedURLString == "https://youtu.be/dQw4w9WgXcQ")

        let shorts = "https://www.youtube.com/shorts/shortID99?feature=share"
        let shortsResult = try #require(AudioLinkURLNormalizer.inspect(shorts))
        #expect(shortsResult.normalizedURLString == "https://www.youtube.com/shorts/shortID99")

        let other = "https://example.com/listen?id=42&utm_source=test&si=abc"
        let otherResult = try #require(AudioLinkURLNormalizer.inspect(other))
        #expect(otherResult.platform == .other)
        #expect(otherResult.normalizedURLString == "https://example.com/listen?id=42")
    }

    @Test("B 站或 YouTube 非具体视频页触发 formatWarning 并被服务层拒绝")
    func nonVideoPagesEmitWarningAndAreRejected() async throws {
        let invalidPages = [
            "https://www.bilibili.com/",
            "https://search.bilibili.com/all?keyword=test",
            "https://space.bilibili.com/12345",
            "https://b23.tv/",
            "https://www.youtube.com/",
            "https://www.youtube.com/watch?list=PL123",
            "https://youtu.be/"
        ]

        for page in invalidPages {
            let inspected = try #require(AudioLinkURLNormalizer.inspect(page))
            let warning = try #require(inspected.formatWarning)
            #expect(!warning.isEmpty)

            do {
                _ = try LiveAudioLinkImportService.validateURL(page)
                Issue.record("预期拒绝非具体视频页：\(page)")
            } catch let error as AudioLinkImportError {
                #expect(error == .unsupportedPlatformURL(detail: warning))
                #expect(error.errorDescription == warning)
            }
        }
    }

    @Test("服务层传给 yt-dlp 的参数已使用裁剪规范化后的干净链接")
    func importFromLinkPassesNormalizedURLToYtdlp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NormalizerServiceTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = NormalizerMockRunner()
        let service = LiveAudioLinkImportService(
            importer: { stagedURL in
                let track = MusicLibraryTrack(
                    persistentID: "A000000000001099",
                    title: "Normalized",
                    durationMs: 120_000,
                    isFavorite: false,
                    dateAdded: Date()
                )
                return MusicLibraryImportedTrack(track: track, resolvedFileURL: stagedURL)
            },
            executableResolver: { tool, _ in URL(fileURLWithPath: "/mock/bin/\(tool)") },
            processRunner: runner,
            stagingRootDirectory: root.appendingPathComponent("staging", isDirectory: true),
            temporaryRootDirectory: root.appendingPathComponent("tmp", isDirectory: true)
        )

        _ = try await service.importFromLink(
            AudioLinkImportRequest(
                urlString: "【推荐】 https://www.bilibili.com/video/BV1hAj16dESQ/?spm_id_from=333.337&vd_source=xyz"
            )
        ) { _ in }

        let ytdlpArgs = try #require(runner.ytdlpArguments)
        #expect(ytdlpArgs.suffix(2) == ["--", "https://www.bilibili.com/video/BV1hAj16dESQ"])
    }

    @Test("裁剪时间与代理规范化支持常用格式并拒绝非法或倒置输入")
    func trimTimeAndProxyNormalization() throws {
        #expect(try AudioLinkURLNormalizer.normalizeTrimTime("   ") == nil)
        #expect(try AudioLinkURLNormalizer.normalizeTrimTime(" 00:15 ") == "00:15")
        #expect(try AudioLinkURLNormalizer.normalizeTrimTime("01:23.5") == "01:23.5")
        #expect(try AudioLinkURLNormalizer.normalizeTrimTime("1:02:03") == "1:02:03")
        #expect(try AudioLinkURLNormalizer.normalizeTrimTime("90") == "90")

        let validRange = try AudioLinkURLNormalizer.validateTrimRange(start: "00:05", end: "03:45")
        #expect(validRange.start == "00:05")
        #expect(validRange.end == "03:45")

        for badTime in ["-5", "01:60", "1::2", "01:", "abc", "1.2.3"] {
            #expect(throws: AudioLinkImportError.self) {
                _ = try AudioLinkURLNormalizer.normalizeTrimTime(badTime)
            }
        }
        #expect(throws: AudioLinkImportError.invalidTrimTime(detail: "裁剪结束时间必须晚于起始时间。")) {
            _ = try AudioLinkURLNormalizer.validateTrimRange(start: "01:00", end: "00:30")
        }

        #expect(try AudioLinkURLNormalizer.normalizeProxy("  ") == nil)
        #expect(try AudioLinkURLNormalizer.normalizeProxy("127.0.0.1:7890") == "http://127.0.0.1:7890")
        #expect(try AudioLinkURLNormalizer.normalizeProxy("socks5://127.0.0.1:1080") == "socks5://127.0.0.1:1080")
        for badProxy in ["--proxy=x", "ftp://127.0.0.1:21", "not-a-proxy", "http://bad host:80"] {
            #expect(throws: AudioLinkImportError.self) {
                _ = try AudioLinkURLNormalizer.normalizeProxy(badProxy)
            }
        }

        #expect(AudioQualityOption.best.rawValue == "0")
        #expect(AudioQualityOption.kbps320.rawValue == "320K")
        #expect(AudioCookieBrowser.chrome.shortName == "Chrome")
        #expect(AudioCookieBrowser.safari.shortName == "Safari")
    }
}

private final class NormalizerMockRunner: AudioProcessRunning, @unchecked Sendable {
    private let capturedYtdlpArgs = OSAllocatedUnfairLock<[String]?>(initialState: nil)

    var ytdlpArguments: [String]? {
        capturedYtdlpArgs.withLock { $0 }
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> AudioProcessOutput {
        let tool = executableURL.lastPathComponent
        if tool == "yt-dlp" {
            capturedYtdlpArgs.withLock { $0 = arguments }
            if let idx = arguments.firstIndex(of: "-o"), idx + 1 < arguments.count {
                let path = arguments[idx + 1].replacingOccurrences(of: "%(ext)s", with: "m4a")
                try Data("mock-m4a".utf8).write(to: URL(fileURLWithPath: path))
            }
            return AudioProcessOutput(terminationStatus: 0, stdout: "", stderr: "")
        }
        if tool == "ffmpeg", let outputPath = arguments.last {
            try Data("tagged-m4a".utf8).write(to: URL(fileURLWithPath: outputPath))
            return AudioProcessOutput(terminationStatus: 0, stdout: "", stderr: "")
        }
        return AudioProcessOutput(terminationStatus: 1, stdout: "", stderr: "unexpected tool")
    }
}
