import AppKit
import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices

// 粘贴导入回归（2026-09-24）：直接驱动 ImportFlowModel，覆盖
// 空白拒绝 / 单语 LRC 与纯文本解析 / 双语成对模式 / 重新输入保留文本 /
// 超限拒绝回输入态 / 确认落库与绑定读回 / 取消与新会话清理。
// 全部使用临时数据库与原创歌词，不访问 Music.app，不实例化真实适配器。

@main
private struct ImportPasteCheck {

    @MainActor private static func runChecks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shin-import-paste-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)

        let flow = ImportFlowModel(store: store)
        let trackKey = "music-script:persistent:FACE0A0B"
        await flow.openSession(target: ImportSessionTarget(
            trackKey: trackKey, titleHint: "原创粘贴测试", artistHint: "测试歌手", durationHintMs: 30_000
        ))
        precondition(flow.phase == .idle, "会话打开后应处于输入阶段")

        // 1) 空白拒绝：不进入解析，停留输入态并给出中文提示。
        flow.pastedText = ""
        await flow.ingestPastedText()
        precondition(flow.phase == .idle, "空文本不得进入解析")
        precondition(flow.alertMessage?.contains("粘贴内容为空") == true, "空文本应给出中文提示")
        flow.pastedText = "  \n\t \n"
        await flow.ingestPastedText()
        precondition(flow.phase == .idle && flow.alertMessage != nil, "纯空白同样拒绝")

        // 2) 单语 LRC 粘贴 → 预览统计正确、filename 为 nil、可导入。
        flow.pastedText = "[ti:原创粘贴测试]\n[ar:测试歌手]\n[00:00.00]晨光落在窗沿\n[00:05.00]纸船驶过浅湾\n"
        await flow.ingestPastedText()
        guard case let .ready(preview, existing) = flow.phase else {
            preconditionFailure("LRC 粘贴后应进入预览：\(flow.alertMessage ?? "?")")
        }
        precondition(preview.filename == nil, "粘贴导入 filename 应为 nil")
        precondition(preview.sourceFormat == .lrc && preview.isImportable, "LRC 粘贴应可导入")
        precondition(
            preview.totalLineCount == 2 && preview.timedLineCount == 2 && preview.untimedLineCount == 0,
            "LRC 行数统计应正确"
        )
        precondition(existing == nil, "首次导入无既有绑定")
        precondition(!flow.pairedModeAvailable, "无同时间戳行组时成对模式不可选")

        // 3) 双语成对粘贴 → 成对模式可用，切换后译文计数正确。
        flow.pastedText = "[00:01.00]晨光落在窗沿\n[00:01.00]晨光落在窗沿（译）\n"
            + "[00:09.00]纸船驶过浅湾\n[00:09.00]纸船驶过浅湾（译）\n"
        await flow.ingestPastedText()
        guard case let .ready(pairedPreview, _) = flow.phase else {
            preconditionFailure("成对 LRC 粘贴后应进入预览")
        }
        precondition(pairedPreview.pairedTimestampsAvailable, "同时间戳行组应开启成对模式")
        await flow.setTranslationIncluded(true)
        guard case let .ready(bilingualPreview, _) = flow.phase else {
            preconditionFailure("双语重算后应仍在预览")
        }
        precondition(bilingualPreview.bilingual != nil, "成对模式应产出双语映射")
        precondition(bilingualPreview.bilingual?.translatedLineCount == 2, "两行原文应配到译文")

        // 4) 重新输入：回到输入态、保留已粘贴文本。
        flow.resetToIdle()
        precondition(flow.phase == .idle, "重新输入应回到输入阶段")
        precondition(flow.pastedText.contains("纸船驶过浅湾"), "重新输入应保留已粘贴文本")

        // 5) 超限拒绝：超过行数上限的粘贴抛错回输入态并给出说明。
        flow.pastedText = (1...10_050).map { "填充行 \($0)" }.joined(separator: "\n")
        await flow.ingestPastedText()
        precondition(flow.phase == .idle, "超限粘贴应回输入阶段")
        precondition(flow.alertMessage != nil, "超限粘贴应给出错误说明")

        // 6) 纯文本粘贴 → 未打轴统计正确，随后确认落库并读回绑定。
        flow.pastedText = "第一行\n第二行\n第三行"
        await flow.ingestPastedText()
        guard case let .ready(plainPreview, _) = flow.phase else {
            preconditionFailure("纯文本粘贴后应进入预览")
        }
        precondition(plainPreview.sourceFormat == .text, "应为纯文本格式")
        precondition(plainPreview.timedLineCount == 0 && plainPreview.untimedLineCount == 3)
        await flow.confirm()
        guard case let .succeeded(confirmation) = flow.phase else {
            preconditionFailure("确认后应成功：\(flow.alertMessage ?? "?")")
        }
        let saved = try await store.document(id: confirmation.document.id)
        precondition(saved?.lines.count == 3, "落库文档应有三行")
        let binding = try await store.binding(forTrackKey: trackKey)
        precondition(binding?.lyricDocumentId == confirmation.document.id, "目标歌曲应绑定到新文档")

        // 7) 取消清理：粘贴文本与会话状态复位；重开会话后输入框为空。
        flow.pastedText = "残留文本"
        await flow.cancel()
        precondition(flow.phase == .idle && flow.pastedText.isEmpty, "取消应清空粘贴文本")
        await flow.openSession(target: ImportSessionTarget(trackKey: trackKey))
        precondition(flow.pastedText.isEmpty && flow.phase == .idle, "新会话应从空输入开始")

        print("PASS 粘贴导入：空白拒绝/LRC 与纯文本解析/双语成对/重新输入保留/超限拒绝/确认落库/取消与会话清理")
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
