import AppKit
import Foundation
import ShinAppleKit
import ShinAppServices

/// 链接导入音频界面状态机：探测本机工具、规范化输入链接、管理阶段进度与取消，并串联入库后的歌词流程。
@MainActor
final class AudioLinkImportModel: ObservableObject {

    enum CookieMode: Equatable {
        case none
        case browser(AudioCookieBrowser)
        case file(URL?)
    }

    enum Phase: Equatable {
        case idle
        case running(AudioLinkImportStage, logTail: String?)
        case succeeded(AudioLinkImportResult)
        case failed(String)
    }

    @Published var urlString: String = "" {
        didSet {
            guard !isApplyingNormalizedURL, urlString != oldValue else { return }
            processURLInputChange(urlString)
        }
    }
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var genre: String = ""
    @Published var embedThumbnail: Bool = true
    @Published var cookieMode: CookieMode = .none
    @Published var keepLocalCopy: Bool = false
    @Published var localCopyDirectory: URL?

    @Published private(set) var toolAvailability: AudioToolAvailability?
    @Published private(set) var isCheckingTools = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var importedResult: AudioLinkImportResult?
    @Published private(set) var urlInspection: AudioLinkNormalization?
    @Published private(set) var autoCleanedNotice: String?
    @Published private(set) var copiedInstallCommand = false

    var onImportSucceeded: ((AudioLinkImportResult) -> Void)?
    var onFetchOnlineLyrics: ((MusicLibraryTrack) -> Void)?
    var onImportManualLyrics: ((MusicLibraryTrack) -> Void)?
    var onPlayImportedTrack: ((MusicLibraryTrack) -> Void)?

    private let service: any AudioLinkImporting
    private var importTask: Task<Void, Never>?
    private var toolCheckTask: Task<Void, Never>?
    private var copyResetTask: Task<Void, Never>?
    private var generation = 0
    private var toolCheckGeneration = 0
    private var isApplyingNormalizedURL = false

    init(service: any AudioLinkImporting) {
        self.service = service
        self.localCopyDirectory = Self.defaultLocalCopyDirectory()
    }

    deinit {
        importTask?.cancel()
        toolCheckTask?.cancel()
        copyResetTask?.cancel()
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var canStart: Bool {
        !isRunning
            && !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (urlInspection?.formatWarning == nil)
            && (toolAvailability?.isReady ?? true)
    }

    var installCommand: String? {
        guard let tools = toolAvailability, !tools.isReady else { return nil }
        switch (tools.ytdlpURL == nil, tools.ffmpegURL == nil) {
        case (true, true): return "brew install yt-dlp ffmpeg"
        case (true, false): return "brew install yt-dlp"
        case (false, true): return "brew install ffmpeg"
        case (false, false): return nil
        }
    }

    static func defaultLocalCopyDirectory() -> URL? {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    // MARK: - 工具探测与安装引导

    func checkTools() async {
        toolCheckGeneration += 1
        let currentGeneration = toolCheckGeneration
        isCheckingTools = true
        let availability = await service.detectTools()
        guard currentGeneration == toolCheckGeneration, !Task.isCancelled else { return }
        toolAvailability = availability
        isCheckingTools = false
    }

    func startToolCheck() {
        toolCheckTask?.cancel()
        toolCheckTask = Task { [weak self] in
            await self?.checkTools()
        }
    }

    func copyInstallCommand() {
        guard let command = installCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedInstallCommand = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copiedInstallCommand = false
        }
    }

    func openTerminalApp() {
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: terminalURL, configuration: configuration, completionHandler: nil)
    }

    // MARK: - 链接检查与规范化

    func processURLInputChange(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            urlInspection = nil
            autoCleanedNotice = nil
            return
        }

        let inspection = AudioLinkURLNormalizer.inspect(trimmed)
        urlInspection = inspection

        guard let inspection, inspection.wasModified else {
            autoCleanedNotice = nil
            return
        }
        guard shouldAutoNormalizeOnEdit(trimmed: trimmed, inspection: inspection) else { return }
        commitNormalizedURL(inspection)
    }

    func applyNormalizedURLIfNeeded() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            urlInspection = nil
            autoCleanedNotice = nil
            return
        }
        let inspection = AudioLinkURLNormalizer.inspect(trimmed)
        urlInspection = inspection
        guard let inspection, inspection.wasModified else { return }
        commitNormalizedURL(inspection)
    }

    func pasteAndNormalizeFromClipboard() {
        guard !isRunning,
              let pasted = NSPasteboard.general.string(forType: .string) else {
            return
        }
        urlString = pasted
        applyNormalizedURLIfNeeded()
    }

    func clearURLInput() {
        guard !isRunning else { return }
        urlString = ""
        urlInspection = nil
        autoCleanedNotice = nil
    }

    private func shouldAutoNormalizeOnEdit(trimmed: String, inspection: AudioLinkNormalization) -> Bool {
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("&") || trimmed.hasSuffix("=") || trimmed.hasSuffix("?p") {
            return false
        }
        return inspection.normalizedURLString != trimmed
            && (trimmed.contains("?") || trimmed.contains(" ") || trimmed.contains("\n")
                || trimmed != inspection.normalizedURLString && !trimmed.hasSuffix("/"))
    }

    private func commitNormalizedURL(_ inspection: AudioLinkNormalization) {
        if urlString != inspection.normalizedURLString {
            isApplyingNormalizedURL = true
            urlString = inspection.normalizedURLString
            isApplyingNormalizedURL = false
        }
        urlInspection = AudioLinkURLNormalizer.inspect(inspection.normalizedURLString)
        autoCleanedNotice = inspection.notice ?? "已自动裁剪多余追踪参数"
    }

    // MARK: - 下载与导入流程

    func startImport() {
        guard !isRunning else { return }
        applyNormalizedURLIfNeeded()
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            phase = .failed("请输入需要导入的音频或视频链接。")
            return
        }
        guard let request = buildImportRequest(trimmedURL: trimmedURL) else { return }

        generation += 1
        let currentGeneration = generation
        importTask?.cancel()
        importedResult = nil
        phase = .running(.validating, logTail: nil)

        let service = self.service
        let onStage: @Sendable (AudioLinkImportStage) -> Void = { [weak self] stage in
            Task { @MainActor in
                self?.handleStageUpdate(stage, generation: currentGeneration)
            }
        }
        importTask = Task { [weak self] in
            do {
                let result = try await service.importFromLink(request, onStage: onStage)
                self?.finishImportSuccess(result, generation: currentGeneration)
            } catch {
                self?.handleImportError(error, generation: currentGeneration)
            }
        }
    }

    private func buildImportRequest(trimmedURL: String) -> AudioLinkImportRequest? {
        let cookieSource: AudioCookieSource
        switch cookieMode {
        case .none:
            cookieSource = .none
        case .browser(let browser):
            cookieSource = .browser(browser)
        case .file(let url):
            guard let url else {
                phase = .failed("请选择 Cookies 文件，或切换为其他 Cookies 来源。")
                return nil
            }
            cookieSource = .cookiesFile(url)
        }

        let copyDirectory = keepLocalCopy ? (localCopyDirectory ?? Self.defaultLocalCopyDirectory()) : nil
        return AudioLinkImportRequest(
            urlString: trimmedURL,
            metadata: AudioLinkMetadata(title: title, artist: artist, album: album, genre: genre),
            embedThumbnail: embedThumbnail,
            cookieSource: cookieSource,
            keepCopyDirectory: copyDirectory
        )
    }

    private func finishImportSuccess(_ result: AudioLinkImportResult, generation currentGeneration: Int) {
        guard generation == currentGeneration, !Task.isCancelled else { return }
        importTask = nil
        importedResult = result
        phase = .succeeded(result)
        onImportSucceeded?(result)
    }

    private func handleImportError(_ error: Error, generation currentGeneration: Int) {
        guard generation == currentGeneration else { return }
        importTask = nil
        if error is CancellationError || (error as? AudioLinkImportError) == .cancelled {
            phase = .idle
        } else {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(message)
        }
    }

    private func handleStageUpdate(_ stage: AudioLinkImportStage, generation currentGeneration: Int) {
        guard generation == currentGeneration, isRunning else { return }
        let previousTail: String?
        if case let .running(_, tail) = phase {
            previousTail = tail
        } else {
            previousTail = nil
        }
        let nextTail: String?
        if case let .downloading(_, detail) = stage, let detail, !detail.isEmpty {
            nextTail = detail
        } else if case .downloading = stage {
            nextTail = previousTail
        } else {
            nextTail = nil
        }
        phase = .running(stage, logTail: nextTail)
    }

    func cancelImport() {
        generation += 1
        toolCheckGeneration += 1
        importTask?.cancel()
        importTask = nil
        toolCheckTask?.cancel()
        toolCheckTask = nil
        copyResetTask?.cancel()
        copyResetTask = nil
        isCheckingTools = false
        if isRunning {
            phase = .idle
        }
    }

    func prepareForReopen() {
        guard !isRunning else { return }
        if case .succeeded = phase {
            resetForAnotherImport()
        } else if case .failed = phase {
            phase = .idle
        }
    }

    func resetForAnotherImport() {
        guard !isRunning else { return }
        urlString = ""
        title = ""
        artist = ""
        album = ""
        genre = ""
        importedResult = nil
        urlInspection = nil
        autoCleanedNotice = nil
        phase = .idle
    }

    func fetchOnlineLyrics() {
        guard let track = importedResult?.importedTrack.track else { return }
        onFetchOnlineLyrics?(track)
    }

    func importManualLyrics() {
        guard let track = importedResult?.importedTrack.track else { return }
        onImportManualLyrics?(track)
    }

    func playImportedTrack() {
        guard let track = importedResult?.importedTrack.track else { return }
        onPlayImportedTrack?(track)
    }

    func waitForImportCompletion() async {
        await importTask?.value
    }
}

/// Mock 模式使用的离线链接导入服务，避免测试或演示时启动真实下载器或访问网络。
struct MockAudioLinkImportService: AudioLinkImporting {
    private let importer: @Sendable (URL) async throws -> MusicLibraryImportedTrack

    init(importer: @escaping @Sendable (URL) async throws -> MusicLibraryImportedTrack) {
        self.importer = importer
    }

    func detectTools() async -> AudioToolAvailability {
        AudioToolAvailability(
            ytdlpURL: URL(fileURLWithPath: "/mock/bin/yt-dlp"),
            ffmpegURL: URL(fileURLWithPath: "/mock/bin/ffmpeg"),
            searchedPaths: ["/mock/bin"]
        )
    }

    func importFromLink(
        _ request: AudioLinkImportRequest,
        onStage: @escaping @Sendable (AudioLinkImportStage) -> Void
    ) async throws -> AudioLinkImportResult {
        try checkNotCancelled()
        onStage(.validating)

        let trimmed = request.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              let inspection = AudioLinkURLNormalizer.inspect(trimmed) else {
            throw AudioLinkImportError.invalidURL
        }
        if let warning = inspection.formatWarning {
            throw AudioLinkImportError.unsupportedPlatformURL(detail: warning)
        }

        if case let .cookiesFile(cookieURL) = request.cookieSource {
            guard cookieURL.isFileURL, FileManager.default.fileExists(atPath: cookieURL.path) else {
                throw AudioLinkImportError.invalidCookiesFile
            }
        }

        onStage(.downloading(progress: 0.45, detail: "[download]  45.0% (模拟模式)"))
        try await Task.sleep(for: .milliseconds(30))
        try checkNotCancelled()

        onStage(.tagging)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shin-mock-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let stagedURL = tempDir.appendingPathComponent("shin-import-\(UUID().uuidString).m4a")
        try Data("mock-m4a-audio".utf8).write(to: stagedURL)

        onStage(.importingToMusic)
        var imported: MusicLibraryImportedTrack
        do {
            imported = try await importer(stagedURL)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw AudioLinkImportError.musicImportFailed(
                detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        let trimmedTitle = request.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = request.metadata.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = request.metadata.album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { imported.track.title = trimmedTitle }
        if !trimmedArtist.isEmpty { imported.track.artist = trimmedArtist }
        if !trimmedAlbum.isEmpty { imported.track.album = trimmedAlbum }

        var savedCopyURL: URL?
        if let copyDir = request.keepCopyDirectory {
            onStage(.savingCopy)
            try FileManager.default.createDirectory(at: copyDir, withIntermediateDirectories: true)
            let base = trimmedTitle.isEmpty ? imported.track.title : trimmedTitle
            let cleaned = String(base.unicodeScalars.filter {
                $0 != "/" && $0 != ":" && !CharacterSet.controlCharacters.contains($0)
            }).trimmingCharacters(in: .whitespacesAndNewlines)
            let safeName = cleaned.isEmpty ? "导入音频" : cleaned
            let target = copyDir.appendingPathComponent("\(safeName).m4a")
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: stagedURL, to: target)
            }
            savedCopyURL = target.standardizedFileURL
        }

        return AudioLinkImportResult(
            importedTrack: imported,
            savedCopyURL: savedCopyURL,
            keptInStaging: true,
            stagedFileURL: stagedURL
        )
    }

    private func checkNotCancelled() throws {
        if Task.isCancelled {
            throw AudioLinkImportError.cancelled
        }
    }
}
