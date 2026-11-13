import Foundation
import os
import ShinAppleKit
import Testing
@testable import ShinAppServices

struct AudioLinkImportServiceTests {
    @Test("URL 校验接受 http/https 链接，拒绝 file://、空白、控制字符与前置短横线注入")
    func urlValidation() throws {
        let valid = try LiveAudioLinkImportService.validateURL("  https://www.bilibili.com/video/BV1xx411c7mD?p=1  ")
        #expect(valid.absoluteString == "https://www.bilibili.com/video/BV1xx411c7mD?p=1")

        let invalidInputs = [
            "",
            "   \n\t ",
            "file:///tmp/audio.m4a",
            "ftp://example.com/audio.m4a",
            "--exec=touch",
            "-o",
            "https://example.com/with space",
            "https://example.com/line\nbreak",
            "https:///missing-host"
        ]
        for input in invalidInputs {
            #expect(throws: AudioLinkImportError.invalidURL) {
                _ = try LiveAudioLinkImportService.validateURL(input)
            }
        }
    }

    @Test("工具探测可从搜索目录识别可执行 yt-dlp 与 ffmpeg，缺失时返回对应错误")
    func toolDiscoveryWithTemporaryExecutables() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let fakeYtdlp = binDir.appendingPathComponent("yt-dlp")
        let fakeFfmpeg = binDir.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeYtdlp)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeFfmpeg)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeYtdlp.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFfmpeg.path)

        let service = LiveAudioLinkImportService(
            importer: { url in makeImportedTrack(resolvedFileURL: url) },
            additionalSearchPaths: [binDir.path],
            stagingRootDirectory: root.appendingPathComponent("staging", isDirectory: true),
            temporaryRootDirectory: root.appendingPathComponent("tmp", isDirectory: true)
        )
        let availability = await service.detectTools()
        #expect(availability.ytdlpURL == fakeYtdlp.standardizedFileURL)
        #expect(availability.ffmpegURL == fakeFfmpeg.standardizedFileURL)
        #expect(availability.isReady)

        // 缺少 yt-dlp 时直接抛 ytdlpNotFound
        let missingYtdlpService = LiveAudioLinkImportService(
            importer: { url in makeImportedTrack(resolvedFileURL: url) },
            executableResolver: { tool, _ in tool == "ffmpeg" ? fakeFfmpeg : nil },
            processRunner: MockAudioProcessRunner(),
            stagingRootDirectory: root.appendingPathComponent("staging", isDirectory: true),
            temporaryRootDirectory: root.appendingPathComponent("tmp", isDirectory: true)
        )
        await #expect(throws: AudioLinkImportError.ytdlpNotFound(searchedPaths: LiveAudioLinkImportService.searchDirectories())) {
            _ = try await missingYtdlpService.importFromLink(
                AudioLinkImportRequest(urlString: "https://example.com/video"),
                onStage: { _ in }
            )
        }
    }

    @Test("端到端参数构造正确传递特殊字符元数据、Cookies 来源与封面开关，并解析下载进度")
    func endToEndArgumentArraysAndProgress() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let cookiesFile = root.appendingPathComponent("cookies.txt")
        try Data("# Netscape HTTP Cookie File\n".utf8).write(to: cookiesFile)

        let runner = MockAudioProcessRunner()
        let stagingDir = root.appendingPathComponent("staging", isDirectory: true)
        let tempRoot = root.appendingPathComponent("tmp", isDirectory: true)

        let service = makeTestService(
            runner: runner,
            stagingDir: stagingDir,
            tempRoot: tempRoot
        ) { stagedURL in
            makeImportedTrack(title: "Crack0day/Caribdis", resolvedFileURL: stagedURL)
        }

        let stages = OSAllocatedUnfairLock(initialState: [AudioLinkImportStage]())
        let metadata = AudioLinkMetadata(
            title: "Crack0day/Caribdis",
            artist: "Who are you/Eternum-0.9 \"Remix\"",
            album: "测试专辑",
            genre: "轻音乐, 英语"
        )

        // 1. 测试浏览器 Cookies + 嵌入封面
        _ = try await service.importFromLink(
            AudioLinkImportRequest(
                urlString: "https://www.bilibili.com/video/BV1test123",
                metadata: metadata,
                embedThumbnail: true,
                cookieSource: .browser(.firefox),
                keepCopyDirectory: nil
            )
        ) { stage in
            stages.withLock { $0.append(stage) }
        }

        let calls1 = runner.recordedCalls
        #expect(calls1.count == 2)

        let ytdlpCall = calls1[0]
        #expect(ytdlpCall.executableURL.lastPathComponent == "yt-dlp")
        #expect(ytdlpCall.arguments.contains("--embed-thumbnail"))
        #expect(containsPair(ytdlpCall.arguments, "--cookies-from-browser", "firefox"))
        #expect(containsPair(ytdlpCall.arguments, "--ffmpeg-location", "/mock/bin/ffmpeg"))
        #expect(ytdlpCall.arguments.suffix(2) == ["--", "https://www.bilibili.com/video/BV1test123"])

        let ffmpegCall = calls1[1]
        #expect(ffmpegCall.executableURL.lastPathComponent == "ffmpeg")
        #expect(containsPair(ffmpegCall.arguments, "-metadata", "title=Crack0day/Caribdis"))
        #expect(containsPair(ffmpegCall.arguments, "-metadata", "artist=Who are you/Eternum-0.9 \"Remix\""))
        #expect(containsPair(ffmpegCall.arguments, "-metadata", "album=测试专辑"))
        #expect(containsPair(ffmpegCall.arguments, "-metadata", "genre=轻音乐, 英语"))
        #expect(ffmpegCall.arguments.suffix(3).prefix(2) == ["-movflags", "+faststart"])

        let recordedStages = stages.withLock { $0 }
        #expect(recordedStages.contains(.validating))
        #expect(recordedStages.contains(.downloading(progress: 0.423, detail: "[download]  42.3% of 10.00MiB at 2.00MiB/s")))
        #expect(recordedStages.contains(.tagging))
        #expect(recordedStages.contains(.importingToMusic))

        // 2. 测试 Cookies 文件 + 关闭嵌入封面
        runner.reset()
        _ = try await service.importFromLink(
            AudioLinkImportRequest(
                urlString: "https://www.bilibili.com/video/BV1test456",
                metadata: AudioLinkMetadata(title: "测试"),
                embedThumbnail: false,
                cookieSource: .cookiesFile(cookiesFile),
                keepCopyDirectory: nil
            )
        ) { _ in }

        let ytdlpCall2 = runner.recordedCalls[0]
        #expect(!ytdlpCall2.arguments.contains("--embed-thumbnail"))
        #expect(containsPair(ytdlpCall2.arguments, "--cookies", cookiesFile.standardizedFileURL.path))
    }

    @Test("Music 拷贝到自有媒体目录时清理暂存文件；直接引用暂存路径时保留文件")
    func stagingCleanupMatchesMusicBehavior() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let stagingDir = root.appendingPathComponent("staging", isDirectory: true)
        let tempRoot = root.appendingPathComponent("tmp", isDirectory: true)
        let musicMediaDir = root.appendingPathComponent("MusicMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: musicMediaDir, withIntermediateDirectories: true)

        // 情形 1：Music 拷贝到自己的 Media 目录
        let copiedDestination = musicMediaDir.appendingPathComponent("CopiedTrack.m4a")
        let runner1 = MockAudioProcessRunner()
        let serviceCopy = makeTestService(runner: runner1, stagingDir: stagingDir, tempRoot: tempRoot) { stagedURL in
            try FileManager.default.copyItem(at: stagedURL, to: copiedDestination)
            return makeImportedTrack(title: "Copied", resolvedFileURL: copiedDestination)
        }
        let resultCopy = try await serviceCopy.importFromLink(
            AudioLinkImportRequest(urlString: "https://example.com/1")
        ) { _ in }
        #expect(resultCopy.keptInStaging == false)
        #expect(resultCopy.stagedFileURL == nil)
        let remainingInStaging = (try? FileManager.default.contentsOfDirectory(atPath: stagingDir.path)) ?? []
        #expect(remainingInStaging.isEmpty)

        // 情形 2：Music 直接引用 staging 中的文件
        let runner2 = MockAudioProcessRunner()
        let serviceInPlace = makeTestService(runner: runner2, stagingDir: stagingDir, tempRoot: tempRoot) { stagedURL in
            makeImportedTrack(title: "InPlace", resolvedFileURL: stagedURL)
        }
        let resultInPlace = try await serviceInPlace.importFromLink(
            AudioLinkImportRequest(urlString: "https://example.com/2")
        ) { _ in }
        #expect(resultInPlace.keptInStaging == true)
        let keptURL = try #require(resultInPlace.stagedFileURL)
        #expect(FileManager.default.fileExists(atPath: keptURL.path))
        #expect(keptURL.lastPathComponent.hasPrefix("shin-import-"))
        #expect(keptURL.pathExtension == "m4a")
    }

    @Test("keepCopyDirectory 导出安全命名副本并在重名时自动递增编号")
    func keepCopyDirectoryAvoidsOverwrite() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let copyDir = root.appendingPathComponent("Copies", isDirectory: true)
        let runner = MockAudioProcessRunner()
        let service = makeTestService(
            runner: runner,
            stagingDir: root.appendingPathComponent("staging", isDirectory: true),
            tempRoot: root.appendingPathComponent("tmp", isDirectory: true)
        ) { stagedURL in
            makeImportedTrack(title: "FallbackTitle", resolvedFileURL: stagedURL)
        }

        let request = AudioLinkImportRequest(
            urlString: "https://example.com/song",
            metadata: AudioLinkMetadata(title: "A/B:C\nSong"),
            keepCopyDirectory: copyDir
        )

        let first = try await service.importFromLink(request) { _ in }
        let firstCopy = try #require(first.savedCopyURL)
        #expect(firstCopy.lastPathComponent == "ABCSong.m4a")
        #expect(FileManager.default.fileExists(atPath: firstCopy.path))

        let second = try await service.importFromLink(request) { _ in }
        let secondCopy = try #require(second.savedCopyURL)
        #expect(secondCopy.lastPathComponent == "ABCSong (2).m4a")
        #expect(FileManager.default.fileExists(atPath: secondCopy.path))
    }

    @Test("任务取消可终止正在运行的子进程并清理临时目录与未完成暂存文件")
    func cancellationTerminatesSubprocessAndCleansTempDirectory() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let tempRoot = root.appendingPathComponent("tmp", isDirectory: true)
        let stagingDir = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let sleepPath = "/bin/sleep"
        let hasSleep = FileManager.default.isExecutableFile(atPath: sleepPath)

        // 先直接验证 FoundationAudioProcessRunner 对真实子进程的取消终止（不依赖网络）。
        if hasSleep {
            let liveRunner = FoundationAudioProcessRunner()
            let task = Task {
                try await liveRunner.run(
                    executableURL: URL(fileURLWithPath: sleepPath),
                    arguments: ["30"],
                    environment: [:],
                    onOutputLine: { _ in }
                )
            }
            try await Task.sleep(for: .milliseconds(80))
            task.cancel()
            await #expect(throws: AudioLinkImportError.cancelled) {
                _ = try await task.value
            }
        }

        // 再验证服务层取消会触发 runner 取消并清理 tempRoot 下的临时工作目录。
        let startedSignal = AsyncSignal()
        let blockingRunner = CancellingMockProcessRunner(onStart: {
            await startedSignal.signal()
        })
        let service = makeTestService(
            runner: blockingRunner,
            stagingDir: stagingDir,
            tempRoot: tempRoot
        ) { stagedURL in
            makeImportedTrack(resolvedFileURL: stagedURL)
        }

        let importTask = Task {
            try await service.importFromLink(
                AudioLinkImportRequest(urlString: "https://example.com/slow")
            ) { _ in }
        }
        await startedSignal.wait()
        importTask.cancel()

        await #expect(throws: AudioLinkImportError.cancelled) {
            _ = try await importTask.value
        }

        let leftoverTemp = (try? FileManager.default.contentsOfDirectory(atPath: tempRoot.path)) ?? []
        let leftoverStaging = (try? FileManager.default.contentsOfDirectory(atPath: stagingDir.path)) ?? []
        #expect(leftoverTemp.isEmpty)
        #expect(leftoverStaging.isEmpty)
    }

    // MARK: - 测试辅助

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioLinkImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTestService(
        runner: any AudioProcessRunning,
        stagingDir: URL,
        tempRoot: URL,
        importer: @escaping @Sendable (URL) async throws -> MusicLibraryImportedTrack
    ) -> LiveAudioLinkImportService {
        LiveAudioLinkImportService(
            importer: importer,
            executableResolver: { tool, _ in
                URL(fileURLWithPath: "/mock/bin/\(tool)")
            },
            processRunner: runner,
            stagingRootDirectory: stagingDir,
            temporaryRootDirectory: tempRoot
        )
    }

    private func makeImportedTrack(
        title: String = "导入测试曲目",
        resolvedFileURL: URL?
    ) -> MusicLibraryImportedTrack {
        let track = MusicLibraryTrack(
            persistentID: "A000000000001001",
            title: title,
            durationMs: 180_000,
            isFavorite: false,
            dateAdded: Date()
        )
        return MusicLibraryImportedTrack(track: track, resolvedFileURL: resolvedFileURL)
    }

    private func containsPair(_ args: [String], _ flag: String, _ value: String) -> Bool {
        for index in 0..<max(0, args.count - 1) where args[index] == flag && args[index + 1] == value {
            return true
        }
        return false
    }
}

private final class MockAudioProcessRunner: AudioProcessRunning, @unchecked Sendable {
    struct Call: Sendable {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
    }

    private let calls = OSAllocatedUnfairLock(initialState: [Call]())

    var recordedCalls: [Call] { calls.withLock { $0 } }

    func reset() {
        calls.withLock { $0.removeAll() }
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> AudioProcessOutput {
        calls.withLock { $0.append(Call(executableURL: executableURL, arguments: arguments, environment: environment)) }

        let tool = executableURL.lastPathComponent
        if tool == "yt-dlp" {
            if let templateIndex = arguments.firstIndex(of: "-o"),
               templateIndex + 1 < arguments.count {
                let templatePath = arguments[templateIndex + 1]
                let outputURL = URL(fileURLWithPath: templatePath.replacingOccurrences(of: "%(ext)s", with: "m4a"))
                try Data("fake-m4a-audio".utf8).write(to: outputURL)
            }
            onOutputLine("[download]  42.3% of 10.00MiB at 2.00MiB/s")
            onOutputLine("[ExtractAudio] Destination: download.m4a")
            return AudioProcessOutput(terminationStatus: 0, stdout: "", stderr: "")
        }

        if tool == "ffmpeg", let outputPath = arguments.last {
            try Data("tagged-m4a-audio".utf8).write(to: URL(fileURLWithPath: outputPath))
            return AudioProcessOutput(terminationStatus: 0, stdout: "", stderr: "")
        }

        return AudioProcessOutput(terminationStatus: 1, stdout: "", stderr: "unexpected tool: \(tool)")
    }
}

private actor AsyncSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class CancellingMockProcessRunner: AudioProcessRunning, @unchecked Sendable {
    private let onStart: @Sendable () async -> Void

    init(onStart: @escaping @Sendable () async -> Void) {
        self.onStart = onStart
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> AudioProcessOutput {
        await onStart()
        do {
            try await Task.sleep(for: .seconds(10))
        } catch is CancellationError {
            throw AudioLinkImportError.cancelled
        }
        return AudioProcessOutput(terminationStatus: 0, stdout: "", stderr: "")
    }
}
