import AppKit
import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices

// 保存位置切换回归（ADR-0008）：经 makeLyricsDatabase 注入驱动真实 AppModel。
// 覆盖：切换立即生效且数据完整搬运 / 偏好持久化并影响下次启动 / 服务全家
// 重建后粘贴导入可用 / 失败原子性（目录不可写时旧库照常工作）/ 恢复默认。
// 全部使用临时目录与原创内容，不访问 Music.app。

private final class CheckSubscription: PlaybackSubscriptionHandle, @unchecked Sendable {
    let cancellation: @Sendable () -> Void
    init(_ cancellation: @escaping @Sendable () -> Void) { self.cancellation = cancellation }
    func cancel() { cancellation() }
}

private final class CheckController: PlaybackController, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PlaybackSnapshot
    private var handlers: [UUID: @Sendable (PlaybackSnapshot) -> Void] = [:]
    init(_ initial: PlaybackSnapshot) { current = initial }
    func snapshot() -> PlaybackSnapshot { lock.withLock { current } }
    func subscribe(_ handler: @escaping @Sendable (PlaybackSnapshot) -> Void) -> PlaybackSubscriptionHandle {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return CheckSubscription { [weak self] in
            _ = self?.lock.withLock { self?.handlers.removeValue(forKey: id) }
        }
    }
    func publish(_ snapshot: PlaybackSnapshot) {
        let callbacks = lock.withLock {
            current = snapshot
            return Array(handlers.values)
        }
        for callback in callbacks { callback(snapshot) }
    }
    func seek(positionMs: Int64) async throws {}
    func setQueue(_ items: [CatalogIdentity], startAt: CatalogIdentity?) async throws {}
    func play() async throws {}
    func pause() async throws {}
    func next() async throws {}
    func previous() async throws {}
    func dispose() {}
}

@main
private struct DataLocationCheck {

    @MainActor static func runChecks() async throws {
        // 偏好隔离兜底：无论之前环境如何，本进程从零开始、结束不留痕。
        UserDefaults.standard.removeObject(forKey: LyricsDatabase.overrideDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: LyricsDatabase.overrideDefaultsKey)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shin-data-location-check-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 初始库 A：带一首歌的歌词。
        let dirA = root.appendingPathComponent("location-a", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        let storeA = try GRDBLyricsStore(path: dirA.appendingPathComponent("lyrics.sqlite").path)
        let documentA = LyricDocument(lines: [
            LyricLine(startMs: 0, text: "晨光落在窗沿"),
            LyricLine(startMs: 10_000, text: "纸船驶过浅湾")
        ])
        let bindingA = SongBinding(persistentID: "ABCDEF01", lyricDocumentId: documentA.id)
        try await storeA.save(document: documentA, binding: bindingA)

        let snapshot = PlaybackSnapshot(
            trackEpoch: 1, title: "原创位置测试", positionMs: 2_000, durationMs: 30_000,
            status: .paused, seq: 1, sessionEpoch: 1, trackRef: bindingA.trackKey
        )
        var makeDatabaseCount = 0
        let model = AppModel(
            isMock: false, controller: CheckController(snapshot), searchService: nil,
            makeLyricsDatabase: {
                makeDatabaseCount += 1
                return LyricsDatabase.Database(
                    store: storeA,
                    locationDescription: "初始数据目录：\(dirA.path)",
                    directory: dirA
                )
            }
        )
        await model.start()
        precondition(model.lyricsPanel != nil && makeDatabaseCount == 1, "启动应完成歌词库初始化")
        precondition(model.lyricsDatabaseDirectory?.path == dirA.path)

        // 1) 切换到空目录 B：数据搬运、立即生效、偏好持久化、服务全家重建。
        let dirB = root.appendingPathComponent("location-b", isDirectory: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        model.isImportPresented = true
        await model.switchLyricsStorage(to: dirB)
        precondition(model.storageSwitchMessage?.contains("已切换到") == true,
                     "切换应成功：\(model.storageSwitchMessage ?? "?")")
        precondition(model.isImportPresented == false, "切换应关闭进行中的导入窗口")
        precondition(model.lyricsDatabaseDirectory?.path == dirB.path, "应立即改用新目录")
        precondition(model.lyricsStore !== storeA, "应改用新的库连接")
        precondition(model.importFlow != nil && model.lyricsEditor != nil && model.library != nil,
                     "服务全家应重建")
        precondition(model.lyricsDatabaseNote.contains(dirB.path), "位置说明应更新")
        let storeB = try GRDBLyricsStore(path: dirB.appendingPathComponent("lyrics.sqlite").path)
        let restoredAtB = try await storeB.document(forTrackKey: bindingA.trackKey)
        precondition(restoredAtB == documentA, "切换后数据应完整出现在新位置")
        precondition(FileManager.default.fileExists(atPath: dirA.appendingPathComponent("lyrics.sqlite").path),
                     "旧位置文件应保留作安全副本")
        precondition(LyricsDatabase.storedOverrideDirectory()?.path == dirB.path, "偏好应持久化")

        // 2) 新库上继续可用：粘贴导入 → 确认 → 从新位置读回。
        let flowB = model.importFlow
        precondition(flowB != nil)
        let trackKeyB = "music-script:persistent:BEEF0002"
        await flowB?.openSession(target: ImportSessionTarget(
            trackKey: trackKeyB, titleHint: "切换后新导入", artistHint: "测试歌手", durationHintMs: 20_000
        ))
        flowB?.pastedText = "[00:00.00]第一行切换后\n[00:04.00]第二行切换后"
        await flowB?.ingestPastedText()
        guard case .ready = flowB?.phase else {
            preconditionFailure("切换后粘贴导入应可解析：\(flowB?.alertMessage ?? "?")")
        }
        await flowB?.confirm()
        guard case .succeeded = flowB?.phase else {
            preconditionFailure("切换后确认导入应成功：\(flowB?.alertMessage ?? "?")")
        }
        let bindingAtB = try await storeB.binding(forTrackKey: trackKeyB)
        precondition(bindingAtB != nil, "新导入应写入新位置")

        // 3) 下次启动尊重已保存的自定义目录（真实 makeStore 路径，含假 HOME 隔离）。
        let model2 = AppModel(
            isMock: false, controller: CheckController(snapshot), searchService: nil
        )
        await model2.start()
        precondition(model2.lyricsDatabaseDirectory?.path == dirB.path,
                     "启动应尊重已保存的自定义目录：\(model2.lyricsDatabaseNote)")
        let reopenedAtB = try await model2.lyricsStore?.document(forTrackKey: bindingA.trackKey)
        precondition(reopenedAtB == documentA, "重启路径打开的库应含原数据")

        // 4) 失败原子性：目标目录不可写时旧库照常工作、偏好不被改写。
        let dirC = root.appendingPathComponent("location-c", isDirectory: true)
        try FileManager.default.createDirectory(at: dirC, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dirC.path)
        await model.switchLyricsStorage(to: dirC)
        precondition(model.storageSwitchMessage?.contains("无法使用所选位置") == true,
                     "不可写目录应给出中文失败说明：\(model.storageSwitchMessage ?? "?")")
        precondition(model.lyricsDatabaseDirectory?.path == dirB.path, "失败后应保持原位置")
        precondition(LyricsDatabase.storedOverrideDirectory()?.path == dirB.path, "失败后偏好不变")
        let readableAfterFailure = try await model.lyricsStore?.document(forTrackKey: bindingA.trackKey)
        precondition(readableAfterFailure == documentA, "失败后原库照常可读")

        // 5) 恢复默认位置：数据搬回默认目录，偏好清除。
        //    保险断言：默认目录必须解析到脚本设定的假 HOME——否则立即失败，
        //    绝不允许检查脚本触碰真实用户目录。
        let expectedFakeHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "/非假HOME"
        let expectedDefaultDir = URL(fileURLWithPath: expectedFakeHome)
            .appendingPathComponent("Library/Application Support/ShinApple", isDirectory: true)
        let defaultDir = try LyricsDatabase.defaultRealDirectory()
        precondition(
            defaultDir.path == expectedDefaultDir.path,
            "默认目录未解析到假 HOME（实际 \(defaultDir.path)，期望 \(expectedDefaultDir.path)），为保护真实数据直接失败"
        )
        await model.switchLyricsStorage(to: nil)
        precondition(model.storageSwitchMessage?.contains("已切换到") == true,
                     "恢复默认应成功：\(model.storageSwitchMessage ?? "?")")
        precondition(model.lyricsDatabaseDirectory?.path == defaultDir.path, "应回到默认目录")
        precondition(LyricsDatabase.storedOverrideDirectory() == nil, "恢复默认后偏好应清除")
        let defaultStore = try GRDBLyricsStore(path: defaultDir.appendingPathComponent("lyrics.sqlite").path)
        let restoredAtDefault = try await defaultStore.document(forTrackKey: bindingA.trackKey)
        precondition(restoredAtDefault == documentA, "恢复默认后数据应完整")
        let lateImportAtDefault = try await defaultStore.binding(forTrackKey: trackKeyB)
        precondition(lateImportAtDefault != nil, "切换期间新增的数据也应搬到默认位置")

        // 6) 重复切换到当前位置：无操作成功路径。
        await model.switchLyricsStorage(to: nil)
        precondition(model.storageSwitchMessage?.contains("已在当前保存位置") == true,
                     "重复切换到当前位置应提示而非重复搬数据")

        print("PASS 保存位置切换：立即生效/数据完整/偏好持久化/重启尊重/失败原子性/恢复默认/粘贴导入可用")
    }

    static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            do {
                try await runChecks()
                fflush(nil)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }
}
