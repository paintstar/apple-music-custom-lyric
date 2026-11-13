import Foundation
import os
import ShinAppleKit

/// 基于 Foundation `Process` 的默认子进程执行器；流式读取管道避免缓冲区满导致的死锁。
public struct FoundationAudioProcessRunner: AudioProcessRunning, Sendable {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> AudioProcessOutput {
        if Task.isCancelled {
            throw AudioLinkImportError.cancelled
        }

        let box = ProcessCancellationBox()
        return try await withTaskCancellationHandler {
            try await runProcess(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                box: box,
                onOutputLine: onOutputLine
            )
        } onCancel: {
            box.cancel()
        }
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        box: ProcessCancellationBox,
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> AudioProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            // 不继承终端标准输入，避免子进程阻塞等待交互输入。
            process.standardInput = FileHandle.nullDevice

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading
            let stdoutBuffer = PipeLineBuffer()
            let stderrBuffer = PipeLineBuffer()
            let statusLock = OSAllocatedUnfairLock(initialState: Int32(-1))
            let group = DispatchGroup()

            group.enter()
            group.enter()
            group.enter()

            attachReadabilityHandler(to: stdoutHandle, buffer: stdoutBuffer, group: group, onOutputLine: onOutputLine)
            attachReadabilityHandler(to: stderrHandle, buffer: stderrBuffer, group: group, onOutputLine: onOutputLine)

            process.terminationHandler = { terminatedProcess in
                statusLock.withLock { $0 = terminatedProcess.terminationStatus }
                if box.markTerminationHandled() {
                    group.leave()
                }
            }

            do {
                let started = try box.attachAndRun(process)
                guard started else {
                    clearHandlers(stdoutHandle: stdoutHandle, stderrHandle: stderrHandle, process: process)
                    continuation.resume(throwing: AudioLinkImportError.cancelled)
                    return
                }
            } catch {
                clearHandlers(stdoutHandle: stdoutHandle, stderrHandle: stderrHandle, process: process)
                continuation.resume(throwing: error)
                return
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                if box.isCancelled {
                    continuation.resume(throwing: AudioLinkImportError.cancelled)
                } else {
                    continuation.resume(returning: AudioProcessOutput(
                        terminationStatus: statusLock.withLock { $0 },
                        stdout: stdoutBuffer.text(),
                        stderr: stderrBuffer.text()
                    ))
                }
            }
        }
    }

    private func attachReadabilityHandler(
        to handle: FileHandle,
        buffer: PipeLineBuffer,
        group: DispatchGroup,
        onOutputLine: @escaping @Sendable (String) -> Void
    ) {
        handle.readabilityHandler = { readableHandle in
            let data = readableHandle.availableData
            if data.isEmpty {
                readableHandle.readabilityHandler = nil
                let (shouldLeave, trailing) = buffer.finish()
                if let trailing { onOutputLine(trailing) }
                if shouldLeave { group.leave() }
            } else {
                buffer.append(data, onLine: onOutputLine)
            }
        }
    }

    private func clearHandlers(stdoutHandle: FileHandle, stderrHandle: FileHandle, process: Process) {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        process.terminationHandler = nil
    }
}

/// 协调 `yt-dlp` 下载、`ffmpeg` 元数据封装与「音乐」资料库入库的本地服务。
public final class LiveAudioLinkImportService: AudioLinkImporting, Sendable {
    private struct ResolvedTools {
        let ytdlpURL: URL
        let ffmpegURL: URL
        let searchedPaths: [String]
    }

    private struct DownloadContext {
        let url: URL
        let request: AudioLinkImportRequest
        let ytdlpURL: URL
        let ffmpegURL: URL
        let tempDir: URL
        let environment: [String: String]
        let normalizedProxy: String?
    }

    private struct RewriteContext {
        let sourceURL: URL
        let stagedURL: URL
        let metadata: AudioLinkMetadata
        let trimStart: String?
        let trimEnd: String?
        let ffmpegURL: URL
        let environment: [String: String]
    }

    private let importer: @Sendable (URL) async throws -> MusicLibraryImportedTrack
    private let executableResolver: AudioExecutableResolver
    private let processRunner: any AudioProcessRunning
    private let additionalSearchPaths: [String]
    private let stagingRootDirectory: URL
    private let temporaryRootDirectory: URL

    public convenience init(
        library: any MusicLibraryBrowsing,
        stagingRootDirectory: URL? = nil,
        temporaryRootDirectory: URL? = nil
    ) {
        self.init(
            importer: { url in try await library.importAudioFile(at: url) },
            stagingRootDirectory: stagingRootDirectory,
            temporaryRootDirectory: temporaryRootDirectory
        )
    }

    public init(
        importer: @escaping @Sendable (URL) async throws -> MusicLibraryImportedTrack,
        executableResolver: AudioExecutableResolver? = nil,
        processRunner: (any AudioProcessRunning)? = nil,
        additionalSearchPaths: [String] = [],
        stagingRootDirectory: URL? = nil,
        temporaryRootDirectory: URL? = nil
    ) {
        self.importer = importer
        self.executableResolver = executableResolver ?? Self.defaultExecutableResolver
        self.processRunner = processRunner ?? FoundationAudioProcessRunner()
        self.additionalSearchPaths = additionalSearchPaths
        self.stagingRootDirectory = (stagingRootDirectory ?? Self.defaultStagingRootDirectory()).standardizedFileURL
        self.temporaryRootDirectory = (temporaryRootDirectory ?? FileManager.default.temporaryDirectory).standardizedFileURL
    }

    public func detectTools() async -> AudioToolAvailability {
        let searchDirs = Self.searchDirectories(additionalPaths: additionalSearchPaths)
        let ytdlp = executableResolver("yt-dlp", searchDirs)
        let ffmpeg = executableResolver("ffmpeg", searchDirs)
        return AudioToolAvailability(ytdlpURL: ytdlp, ffmpegURL: ffmpeg, searchedPaths: searchDirs)
    }

    public func importFromLink(
        _ request: AudioLinkImportRequest,
        onStage: @escaping @Sendable (AudioLinkImportStage) -> Void
    ) async throws -> AudioLinkImportResult {
        try checkNotCancelled()
        onStage(.validating)

        let validatedURL = try Self.validateURL(request.urlString)
        try Self.validateCookieSource(request.cookieSource)
        let trimRange = try AudioLinkURLNormalizer.validateTrimRange(start: request.trimStart, end: request.trimEnd)
        let normalizedProxy = try AudioLinkURLNormalizer.normalizeProxy(request.proxy)
        let tools = try await resolveRequiredTools()

        try checkNotCancelled()
        let tempDir = try createTemporaryWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let childEnvironment = Self.buildEnvironment(
            searchDirectories: tools.searchedPaths,
            ffmpegDirectory: tools.ffmpegURL.deletingLastPathComponent().path
        )
        let context = DownloadContext(
            url: validatedURL,
            request: request,
            ytdlpURL: tools.ytdlpURL,
            ffmpegURL: tools.ffmpegURL,
            tempDir: tempDir,
            environment: childEnvironment,
            normalizedProxy: normalizedProxy
        )
        let downloadedM4A = try await downloadAudio(context: context, onStage: onStage)

        try checkNotCancelled()
        onStage(.tagging)
        let stagedURL = try makeStagedOutputURL()
        try await rewriteMetadata(
            context: RewriteContext(
                sourceURL: downloadedM4A,
                stagedURL: stagedURL,
                metadata: request.metadata,
                trimStart: trimRange.start,
                trimEnd: trimRange.end,
                ffmpegURL: tools.ffmpegURL,
                environment: childEnvironment
            )
        )

        try checkNotCancelled()
        onStage(.importingToMusic)
        let imported = try await importIntoMusic(stagedURL: stagedURL)

        return try finalizeImportedResult(
            request: request,
            stagedURL: stagedURL,
            imported: imported,
            onStage: onStage
        )
    }

    // MARK: - 阶段执行

    private func resolveRequiredTools() async throws -> ResolvedTools {
        let tools = await detectTools()
        guard let ytdlpURL = tools.ytdlpURL else {
            throw AudioLinkImportError.ytdlpNotFound(searchedPaths: tools.searchedPaths)
        }
        guard let ffmpegURL = tools.ffmpegURL else {
            throw AudioLinkImportError.ffmpegNotFound(searchedPaths: tools.searchedPaths)
        }
        return ResolvedTools(ytdlpURL: ytdlpURL, ffmpegURL: ffmpegURL, searchedPaths: tools.searchedPaths)
    }

    private func createTemporaryWorkingDirectory() throws -> URL {
        let tempDir = temporaryRootDirectory.appendingPathComponent("shin-audio-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func makeStagedOutputURL() throws -> URL {
        try FileManager.default.createDirectory(at: stagingRootDirectory, withIntermediateDirectories: true)
        return stagingRootDirectory.appendingPathComponent("shin-import-\(UUID().uuidString).m4a").standardizedFileURL
    }

    private func downloadAudio(
        context: DownloadContext,
        onStage: @escaping @Sendable (AudioLinkImportStage) -> Void
    ) async throws -> URL {
        onStage(.downloading(progress: nil, detail: nil))
        let args = Self.buildYtdlpArguments(
            url: context.url,
            request: context.request,
            ffmpegURL: context.ffmpegURL,
            outputTemplate: context.tempDir.appendingPathComponent("download.%(ext)s").path,
            proxy: context.normalizedProxy
        )
        let lastProgress = OSAllocatedUnfairLock<Double?>(initialState: nil)
        let output: AudioProcessOutput
        do {
            output = try await processRunner.run(
                executableURL: context.ytdlpURL,
                arguments: args,
                environment: context.environment
            ) { line in
                let parsed = Self.parseYtdlpProgress(from: line)
                let currentProgress = lastProgress.withLock { stored -> Double? in
                    if let parsed { stored = parsed }
                    return stored
                }
                onStage(.downloading(progress: currentProgress, detail: line))
            }
        } catch AudioLinkImportError.cancelled, is CancellationError {
            throw AudioLinkImportError.cancelled
        } catch {
            throw AudioLinkImportError.downloadFailed(detail: error.localizedDescription)
        }

        try checkNotCancelled()
        guard output.terminationStatus == 0 else {
            throw AudioLinkImportError.downloadFailed(detail: Self.conciseFailureDetail(output))
        }

        return try Self.findDownloadedM4A(in: context.tempDir)
    }

    private func rewriteMetadata(context: RewriteContext) async throws {
        let args = Self.buildFfmpegTagArguments(
            sourceURL: context.sourceURL,
            stagedURL: context.stagedURL,
            metadata: context.metadata,
            trimStart: context.trimStart,
            trimEnd: context.trimEnd
        )
        let output: AudioProcessOutput
        do {
            output = try await processRunner.run(
                executableURL: context.ffmpegURL,
                arguments: args,
                environment: context.environment
            ) { _ in }
        } catch AudioLinkImportError.cancelled, is CancellationError {
            try? FileManager.default.removeItem(at: context.stagedURL)
            throw AudioLinkImportError.cancelled
        } catch {
            try? FileManager.default.removeItem(at: context.stagedURL)
            throw AudioLinkImportError.taggingFailed(detail: error.localizedDescription)
        }

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: context.stagedURL)
            throw AudioLinkImportError.cancelled
        }

        guard output.terminationStatus == 0,
              FileManager.default.fileExists(atPath: context.stagedURL.path) else {
            try? FileManager.default.removeItem(at: context.stagedURL)
            let detail = output.terminationStatus == 0 ? "未生成目标音频文件。" : Self.conciseFailureDetail(output)
            throw AudioLinkImportError.taggingFailed(detail: detail)
        }
    }

    private func importIntoMusic(stagedURL: URL) async throws -> MusicLibraryImportedTrack {
        do {
            return try await importer(stagedURL)
        } catch AudioLinkImportError.cancelled, is CancellationError {
            try? FileManager.default.removeItem(at: stagedURL)
            throw AudioLinkImportError.cancelled
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw AudioLinkImportError.musicImportFailed(detail: detail)
        }
    }

    private func finalizeImportedResult(
        request: AudioLinkImportRequest,
        stagedURL: URL,
        imported: MusicLibraryImportedTrack,
        onStage: @Sendable (AudioLinkImportStage) -> Void
    ) throws -> AudioLinkImportResult {
        let stagedPath = stagedURL.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedPath = imported.resolvedFileURL?.standardizedFileURL.resolvingSymlinksInPath().path
        let musicCopiedElsewhere = resolvedPath != nil && resolvedPath != stagedPath

        var savedCopyURL: URL?
        do {
            if let copyDir = request.keepCopyDirectory {
                onStage(.savingCopy)
                savedCopyURL = try saveCopy(
                    stagedURL: stagedURL,
                    resolvedURL: imported.resolvedFileURL,
                    preferredTitle: request.metadata.title,
                    trackTitle: imported.track.title,
                    to: copyDir
                )
            }
        } catch {
            if musicCopiedElsewhere {
                try? FileManager.default.removeItem(at: stagedURL)
            }
            throw error
        }

        if musicCopiedElsewhere {
            try? FileManager.default.removeItem(at: stagedURL)
            return AudioLinkImportResult(
                importedTrack: imported,
                savedCopyURL: savedCopyURL,
                keptInStaging: false,
                stagedFileURL: nil
            )
        }

        return AudioLinkImportResult(
            importedTrack: imported,
            savedCopyURL: savedCopyURL,
            keptInStaging: true,
            stagedFileURL: stagedURL
        )
    }

    private func saveCopy(
        stagedURL: URL,
        resolvedURL: URL?,
        preferredTitle: String,
        trackTitle: String,
        to directory: URL
    ) throws -> URL {
        guard directory.isFileURL else {
            throw AudioLinkImportError.saveCopyFailed(detail: "保存目录路径无效。")
        }
        let sourceForCopy: URL
        if FileManager.default.fileExists(atPath: stagedURL.path) {
            sourceForCopy = stagedURL
        } else if let resolvedURL, FileManager.default.fileExists(atPath: resolvedURL.path) {
            sourceForCopy = resolvedURL
        } else {
            throw AudioLinkImportError.saveCopyFailed(detail: "找不到可用于复制的 M4A 音频文件。")
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let baseName = Self.sanitizedFileBaseName(preferredTitle: preferredTitle, fallbackTitle: trackTitle)
            let destinationURL = Self.uniqueDestinationURL(in: directory, baseName: baseName)
            try FileManager.default.copyItem(at: sourceForCopy, to: destinationURL)
            return destinationURL.standardizedFileURL
        } catch let error as AudioLinkImportError {
            throw error
        } catch {
            throw AudioLinkImportError.saveCopyFailed(detail: error.localizedDescription)
        }
    }

    private func checkNotCancelled() throws {
        if Task.isCancelled {
            throw AudioLinkImportError.cancelled
        }
    }
}

// MARK: - 子进程取消辅助

private final class ProcessCancellationBox: @unchecked Sendable {
    private struct State {
        var process: Process?
        var cancelled = false
        var terminationHandled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isCancelled: Bool {
        state.withLock { $0.cancelled }
    }

    func attachAndRun(_ process: Process) throws -> Bool {
        try state.withLock { s in
            guard !s.cancelled else { return false }
            s.process = process
            try process.run()
            return true
        }
    }

    func cancel() {
        let runningProcess: Process? = state.withLock { s in
            s.cancelled = true
            return s.process
        }
        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
        }
    }

    func markTerminationHandled() -> Bool {
        state.withLock { s in
            guard !s.terminationHandled else { return false }
            s.terminationHandled = true
            return true
        }
    }
}
