import AppKit
import SwiftUI
import ShinAppleKit
import ShinAppleData
import ShinAppServices

private enum CheckError: Error { case failed(String) }
private final class SilentSubscription: PlaybackSubscriptionHandle, @unchecked Sendable { func cancel() {} }
private final class SilentController: PlaybackController, @unchecked Sendable {
    func snapshot() -> PlaybackSnapshot { PlaybackSnapshot() }
    func subscribe(_ handler: @escaping @Sendable (PlaybackSnapshot) -> Void) -> PlaybackSubscriptionHandle {
        SilentSubscription()
    }
    func setQueue(_ items: [CatalogIdentity], startAt: CatalogIdentity?) async throws {}
    func seek(positionMs: Int64) async throws {}
    func play() async throws {}
    func pause() async throws {}
    func next() async throws {}
    func previous() async throws {}
    func dispose() {}
}

@main
private struct LocalResourcesCheck {
    @MainActor static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckError.failed(message) }
    }

    @MainActor static func makeStore(_ root: URL, _ name: String) throws -> GRDBLyricsStore {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
    }

    @MainActor static func seed(_ store: GRDBLyricsStore, _ id: String, _ title: String) async throws -> (LyricDocument, SongBinding) {
        let document = LyricDocument(originalFilename: "\(title)-原创练习.lrc", metadata: ["ti": [title]], lines: [
            LyricLine(startMs: 0, text: "Paper boats greet the morning",
                      translations: ["zh-Hans": Translation(text: "原创纸船向晨光问好")]),
            LyricLine(startMs: 5_000, text: "晚风收起小小的帆")
        ])
        let binding = SongBinding(persistentID: id, lyricDocumentId: document.id, titleHint: title, artistHint: "原创歌手甲")
        try await store.save(document: document, binding: binding)
        return (document, binding)
    }

    @MainActor static func makeModel(_ store: GRDBLyricsStore) -> AppModel {
        let model = AppModel(isMock: true, controller: SilentController(), searchService: nil)
        model.lyricsStore = store
        model.installLyricsServiceGraph(store: store, note: "隔离测试歌词库")
        return model
    }

    @MainActor static func show(_ binding: SongBinding, on model: AppModel, epoch: Int) async throws {
        model.applySnapshot(PlaybackSnapshot(
            trackEpoch: epoch, title: binding.titleHint, artist: binding.artistHint,
            positionMs: 0, durationMs: 20_000, status: .paused, seq: epoch, sessionEpoch: 1, trackRef: binding.trackKey
        ))
        try await wait("快照触发的歌词刷新就绪") {
            model.lyricsPanel?.displayedTrackKey == binding.trackKey
                && model.lyricsPanel?.displayedTrackEpoch == epoch
                && model.lyricsPanel?.currentDocumentId == binding.lyricDocumentId
        }
    }

    @MainActor static func unlinkRequest(_ model: AppModel) throws -> LyricsUnlinkRequest {
        guard let request = LyricsUnlinkRequest(model: model) else {
            throw CheckError.failed("歌词面板尚未与当前曲目、生命周期和文档对齐，无法创建解绑确认")
        }
        return request
    }

    @MainActor static func wait(_ message: String, until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !condition() {
            if clock.now >= deadline { throw CheckError.failed("等待超时：\(message)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor static func countsAndDeletion(_ root: URL) async throws {
        let store = try makeStore(root, "counts")
        let (first, _) = try await seed(store, "DA000001", "晨光纸船")
        let (orphan, orphanBinding) = try await seed(store, "DA000002", "晚风浅湾")
        _ = try await seed(store, "DA000003", "Cloud Letter")
        try await store.deleteBinding(forTrackKey: orphanBinding.trackKey)
        let library = LyricsLibraryModel(store: store)
        await library.refresh()
        try require(library.items.count == 3, "列表包含所有实际文档")
        try require(library.associatedResourceCount == 2 && library.unassociatedResourceCount == 1, "关联与未关联计数准确")
        try require(library.resources(matching: " cloud ").count == 1, "搜索忽略大小写及两端空格")
        try require(library.resources(matching: "晨光纸船-原创练习").count == 1, "可搜索文件名")
        let selected = library.items.filter { $0.documentId == first.id }
        library.requestResourceDeletion(selected)
        try require(library.resourceDeletionPreview?.documentCount == 1, "所选删除只预览选中的文档")
        try require(library.resourceDeletionPreview?.bindingCount == 1, "删除预览列出受影响关联数")
        try require(LocalResourceManagementView.deletionMessage(library.resourceDeletionPreview!).contains("人工译文"), "删除确认包含人工译文提醒")
        library.cancelResourceDeletion()
        await library.confirmResourceDeletion()
        try require(try await store.document(id: first.id) != nil, "取消删除不写库")
        try require(library.beginAssociationDeletion(), "当前歌曲解绑可取得统一删除锁")
        library.requestResourceDeletion(library.items)
        try require(library.resourceDeletionPreview == nil, "解绑进行中不能启动资源删除预览")
        library.finishAssociationDeletion()
        var invalidations = 0
        library.onWillDeleteResources = { _ in invalidations += 1; return nil }
        library.requestResourceDeletion(library.items.filter { $0.bindingCount == 0 })
        let deletion = library.beginResourceDeletion()
        try require(library.beginResourceDeletion() == nil, "提交中禁止重复删除")
        await deletion?.value
        try require(invalidations == 1, "确认提交前只失效一次在途自动获取")
        try require(try await store.document(id: orphan.id) == nil, "清理未关联删除目标文档及其行内译文")
        try require(library.items.count == 2 && library.unassociatedResourceCount == 0, "删除后资源概览及时刷新")
        library.requestResourceDeletion(library.items)
        await library.confirmResourceDeletion()
        try require(library.items.isEmpty, "删除全部清空资源列表")
        try require(try await store.allBindings().isEmpty, "删除全部一并解除对应歌曲关联")
        print("PASS 资源统计、搜索、所选与取消、未关联与全部删除、重复提交保护")
    }

    @MainActor static func resourceNames(_ root: URL) async throws {
        let store = try makeStore(root, "names")
        let cases: [(String?, String?, [String?], String)] = [
            ("  原创标题  ", "原创文件.lrc", ["关联歌名"], "原创标题"),
            (" \n ", "  原创文件.lrc  ", ["关联歌名"], "原创文件.lrc"),
            (nil, nil, [" 晨光纸船 ", "晚风浅湾", "晨光纸船", " \n ", nil], "晨光纸船、晚风浅湾"),
            (" \n ", " \t ", [" \n "], "未命名歌词"),
            (nil, nil, [nil], "未命名歌词")
        ]
        var expected: [UUID: String] = [:]
        for (index, item) in cases.enumerated() {
            var document = LyricDocument(originalFilename: item.1,
                                         metadata: item.0.map { ["ti": [$0]] } ?? [:],
                                         lines: [LyricLine(startMs: 0, text: "原创纸船驶向晨光")])
            for (bindingIndex, title) in item.2.enumerated() {
                let binding = SongBinding(persistentID: "DF0000\(index)\(bindingIndex)",
                                          lyricDocumentId: document.id, titleHint: title)
                try await store.save(document: document, binding: binding)
                if index == cases.count - 1 { try await store.deleteBinding(forTrackKey: binding.trackKey) }
                document.revision += 1
            }
            expected[document.id] = item.3
        }
        let documentsBefore = try await store.allDocuments()
        let bindingsBefore = try await store.allBindings()
        let library = LyricsLibraryModel(store: store)
        await library.refresh()
        for item in library.items {
            try require(LyricsLibraryModel.displayName(for: item) == expected[item.documentId],
                        "显示名称遵循歌词标题、文件名、去重关联歌名的优先级，空值才回退未命名")
        }
        await library.refresh()
        try require(try await store.allDocuments() == documentsBefore, "展示名称不修改歌词内容或 revision")
        try require(try await store.allBindings() == bindingsBefore, "展示名称不修改歌曲关联")
        print("PASS 资源名称回退、空白过滤、共享歌名稳定去重与只读展示")
    }

    @MainActor static func stalePreviews(_ root: URL) async throws {
        let store = try makeStore(root, "stale")
        let (document, binding) = try await seed(store, "DB000001", "原创新芽")
        let library = LyricsLibraryModel(store: store)
        await library.refresh()
        library.requestResourceDeletion(library.items)
        var edited = document
        edited.revision += 1
        edited.lines[0].text = "人工编辑后的原创句子"
        try await store.save(document: edited, binding: binding)
        await library.confirmResourceDeletion()
        try require(try await store.document(id: document.id)?.revision == edited.revision, "资源旧版本预览不能删除新编辑")
        try require(library.alertMessage?.contains("未删除") == true, "过期删除明确反馈失败")
        await library.requestDeletion(library.items[0])
        try await LyricsLibraryService(store: store).reassociate(
            trackKey: SongBinding.trackKey(persistentID: "DB000002"), toDocumentId: document.id
        )
        await library.confirmDeletion()
        try require(try await store.allBindings().count == 2, "学习歌曲页旧确认遇新增关联整批拒绝")
        await library.refresh()
        await library.requestDeletion(library.items[0])
        edited.revision += 1
        edited.lines[1].text = "另一句人工修改"
        try await store.save(document: edited, binding: binding)
        await library.confirmDeletion()
        try require(try await store.document(id: document.id)?.revision == edited.revision, "学习歌曲页旧确认不能删除新版本")
        await library.refresh()
        library.requestResourceDeletion(library.items)
        library.deactivateResources()
        await library.confirmResourceDeletion()
        try require(try await store.document(id: document.id) != nil, "换库后旧模型不能提交资源预览")
        print("PASS 资源及旧单项删除的 revision、关联变化与模型失效保护")
    }

    @MainActor static func interleavedPreviews(_ root: URL) async throws {
        let store = try makeStore(root, "interleaved")
        let (first, _) = try await seed(store, "DF000001", "原创确认甲")
        let (second, _) = try await seed(store, "DF000002", "原创确认乙")
        let library = LyricsLibraryModel(store: store)
        await library.refresh()
        let firstItem = library.items.first { $0.documentId == first.id }!
        let secondItem = library.items.first { $0.documentId == second.id }!
        let resourceA = library.requestResourceDeletion([firstItem])!
        let resourceB = library.requestResourceDeletion([secondItem])!
        library.cancelResourceDeletion(resourceA)
        try require(library.resourceDeletionPreview?.id == resourceB.id, "A 窗取消不能清除 B 窗资源预览")
        await library.confirmResourceDeletion(resourceA)
        try require(try await store.document(id: second.id) != nil, "A 窗确认不能读取 B 窗目标")
        await library.confirmResourceDeletion(resourceB)
        try require(try await store.document(id: first.id) != nil, "B 窗确认只删除自己的目标")
        try require(try await store.document(id: second.id) == nil, "B 窗资源确认正常生效")
        let (third, _) = try await seed(store, "DF000003", "原创确认丙")
        await library.refresh()
        let singleA = await library.requestDeletion(library.items.first { $0.documentId == first.id }!)!
        let singleB = await library.requestDeletion(library.items.first { $0.documentId == third.id }!)!
        library.cancelDeletion(singleA)
        try require(library.deletionPreview?.id == singleB.id, "A 窗取消不能清除 B 窗单项预览")
        await library.confirmDeletion(singleA)
        try require(try await store.document(id: third.id) != nil, "A 窗单项确认不能删除 B 窗目标")
        await library.confirmDeletion(singleB)
        try require(try await store.document(id: third.id) == nil, "B 窗单项确认删除固定目标")
        try require(try await store.document(id: first.id) != nil, "交错确认保护未选文档")
        print("PASS 多窗口资源及单项 A/B 预览交错确认与取消保护")
    }

    @MainActor static func unlinkAndCurrentRefresh(_ root: URL) async throws {
        let store = try makeStore(root, "unlink")
        let (document, binding) = try await seed(store, "DC000001", "原创潮声")
        let sharedKey = SongBinding.trackKey(persistentID: "DC000002")
        try await LyricsLibraryService(store: store).reassociate(trackKey: sharedKey, toDocumentId: document.id)
        let model = makeModel(store)
        try await show(binding, on: model, epoch: 1)
        let request = try unlinkRequest(model)
        model.unlinkCurrentLyrics(request)
        try await wait("共享解绑后面板为空") { model.lyricsPanel?.state == .unbound && model.library?.isDeletingResources == false }
        try require(try await store.document(id: document.id) != nil, "共享文档保留供另一歌曲使用")
        let sharedBinding = try await store.binding(forTrackKey: sharedKey)!
        try await show(sharedBinding, on: model, epoch: 2)
        model.unlinkCurrentLyrics(try unlinkRequest(model))
        try await wait("最后关联解除后面板为空") { model.lyricsPanel?.state == .unbound && model.library?.isDeletingResources == false }
        try require(try await store.document(id: document.id) == nil, "最后关联解除删除歌词和人工译文")
        let (current, currentBinding) = try await seed(store, "DC000003", "原创星岸")
        try await show(currentBinding, on: model, epoch: 3)
        await model.library?.refresh()
        model.library?.requestResourceDeletion(model.library!.items.filter { $0.documentId == current.id })
        await model.library?.confirmResourceDeletion()
        try await wait("资源删除刷新当前面板") { model.lyricsPanel?.state == .unbound && model.library?.isDeletingResources == false }
        try require(model.library?.items.isEmpty == true, "资源列表与当前歌词面板一致")
        print("PASS 共享解除保留、最后解除删除歌词和译文、资源删除刷新当前面板")
    }

    @MainActor static func lifecycleGuards(_ root: URL) async throws {
        let store = try makeStore(root, "lifecycle")
        let (document, binding) = try await seed(store, "DD000001", "原创云径")
        let (_, nextBinding) = try await seed(store, "DD000002", "原创竹影")
        let model = makeModel(store)
        try await show(binding, on: model, epoch: 1)
        let trackRequest = try unlinkRequest(model)
        try await show(nextBinding, on: model, epoch: 2)
        try require(!trackRequest.matches(model), "切歌后旧解绑确认失效")
        model.unlinkCurrentLyrics(trackRequest)
        try require(try await store.document(id: document.id) != nil, "旧确认不能删除切走歌曲")
        try await show(binding, on: model, epoch: 3)
        let revisionRequest = try unlinkRequest(model)
        var edited = document
        edited.revision += 1
        try await store.save(document: edited, binding: binding)
        await model.lyricsPanel?.refresh(trackKey: binding.trackKey, trackEpoch: 3)
        try require(!revisionRequest.matches(model), "编辑后旧解绑确认失效")
        let oldLibrary = model.library!
        await oldLibrary.refresh()
        oldLibrary.requestResourceDeletion(oldLibrary.items)
        let oldPanelRequest = try unlinkRequest(model)
        let replacement = try makeStore(root, "replacement")
        model.lyricsStore = replacement
        model.installLyricsServiceGraph(store: replacement, note: "新隔离歌词库")
        try require(!oldPanelRequest.matches(model), "换库后旧解绑确认失效")
        await oldLibrary.confirmResourceDeletion()
        try require(try await store.allBindings().count == 2, "换库后旧资源确认不删除原库")
        try require(try await replacement.allBindings().isEmpty, "旧确认不会写新库")
        print("PASS 切歌、编辑、换库的解绑确认与旧资源预览保护")
    }

    @MainActor static func changesFromAnotherConnection(_ root: URL) async throws {
        let directory = root.appendingPathComponent("external-writes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("lyrics.sqlite").path
        let reader = try GRDBLyricsStore(path: path)
        let writer = try GRDBLyricsStore(path: path)
        let model = makeModel(reader)
        let key = "music-script:persistent:DC000071"
        model.applySnapshot(PlaybackSnapshot(trackEpoch: 1, positionMs: 1_000, durationMs: 20_000,
                                             status: .paused, seq: 1, sessionEpoch: 1, trackRef: key))
        try await wait("外部保存前当前歌曲无歌词") { model.lyricsPanel?.state == .unbound }
        let (document, binding) = try await seed(writer, "DC000071", "原创跨窗口晨光")
        await model.library?.refresh()
        try require(model.library?.items.contains { $0.documentId == document.id && $0.bindingCount == 1 } == true,
                    "另一连接已保存的歌词在缓存中可见")
        try await wait("另一连接保存后当前歌词自动出现") { model.lyricsPanel?.currentDocumentId == document.id }
        var edited = document
        edited.revision += 1
        edited.lines[0].text = "原创纸船沿着晴窗继续出发"
        try await writer.save(document: edited, binding: binding)
        try await wait("另一连接编辑当前歌词自动更新") { model.lyricsPanel?.currentDocument?.revision == edited.revision }
        _ = try await writer.deleteAssociation(forTrackKey: binding.trackKey, expectedDocumentId: edited.id,
                                              expectedRevision: edited.revision)
        try await wait("另一连接删除当前关联自动清空") { model.lyricsPanel?.state == .unbound }
        // 已切换数据库后，旧位置的写入不能把旧文档重新带回当前面板。
        let replacement = try makeStore(root, "external-writes-replacement")
        model.lyricsStore = replacement
        model.installLyricsServiceGraph(store: replacement, note: "新的隔离歌词库")
        model.refreshLyricsPanel()
        try await wait("新歌词库当前曲目无关联") { model.lyricsPanel?.state == .unbound }
        _ = try await seed(writer, "DC000071", "原创旧位置晚风")
        try await Task.sleep(for: .milliseconds(250))
        try require(model.lyricsPanel?.state == .unbound, "旧歌词库事件不能重新装载旧位置的文档")
        model.prepareForTermination()
        print("PASS 同曲暂停时跨连接保存、编辑、删除即时同步；换库与退出清理监听")
    }

    @MainActor static func capture(_ root: URL) async throws {
        guard let path = ProcessInfo.processInfo.environment["SHIN_LOCAL_RESOURCES_CAPTURE_DIR"], !path.isEmpty else { return }
        let store = try makeStore(root, "layout")
        for index in 0..<6 {
            var (document, binding) = try await seed(store, "DE00000\(index)", "原创资源 \(index + 1)：晨光纸船与晚风浅湾")
            if index == 0 {
                document.originalFilename = nil
                document.metadata = [:]
                document.revision += 1
                try await store.save(document: document, binding: binding)
            }
            if index == 2 { try await store.deleteBinding(forTrackKey: binding.trackKey) }
        }
        let library = LyricsLibraryModel(store: store)
        await library.refresh()
        let host = NSHostingView(rootView: LocalResourceManagementView(library: library)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 720, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        host.appearance = window.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CheckError.failed("无法渲染资源管理界面") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CheckError.failed("无法编码布局截图") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("local-resources.png"))
        window.close()
        print("PASS 资源管理默认尺寸离屏渲染（原创隔离数据）")
    }

    @MainActor static func main() async throws {
        guard let isolatedHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw CheckError.failed("缺少临时 HOME 隔离配置")
        }
        try require(NSHomeDirectory() == isolatedHome, "HOME 隔离未生效，拒绝运行")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shin-local-resources-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await countsAndDeletion(root)
        try await resourceNames(root)
        try await stalePreviews(root)
        try await interleavedPreviews(root)
        try await unlinkAndCurrentRefresh(root)
        try await lifecycleGuards(root)
        try await changesFromAnotherConnection(root)
        try await capture(root)
    }
}
