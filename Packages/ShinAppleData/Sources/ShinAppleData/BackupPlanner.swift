import Foundation
import ShinAppleKit

// 纯函数冲突预览：给定解析后的备份与当前库快照，计算"确认后将新增/
// 替换什么"。不做任何 I/O，UI 可在任意时点安全调用；
// 确认写入时仍须按库中的最新 revision 检查冲突。

public enum BackupPlanner {

    /// 计算冲突预览。与当前库完全一致的条目是 no-op，不出现。
    public static func conflictPreview(
        parsed: BackupParseResult,
        currentState: BackupStoreSnapshot
    ) -> BackupConflictPreview {
        var preview = BackupConflictPreview(
            documentsToAdd: [],
            documentReplacements: [],
            bindingsToAdd: [],
            bindingReplacements: [],
            settingsToWrite: [:],
            settingsToReplace: [:]
        )
        previewDocumentChanges(parsed, currentState, into: &preview)
        previewBindingChanges(parsed, currentState, into: &preview)
        previewSettingChanges(parsed, currentState, into: &preview)
        return preview
    }

    private static func previewDocumentChanges(
        _ parsed: BackupParseResult,
        _ currentState: BackupStoreSnapshot,
        into preview: inout BackupConflictPreview
    ) {
        for document in parsed.file.documents {
            switch currentState.documents[document.id] {
            case .none:
                preview.documentsToAdd.append(document)
            case .some(let existing) where existing != document:
                preview.documentReplacements.append(
                    BackupDocumentReplacement(existing: existing, incoming: document)
                )
            case .some:
                break // 完全一致：no-op
            }
        }
    }

    private static func previewBindingChanges(
        _ parsed: BackupParseResult,
        _ currentState: BackupStoreSnapshot,
        into preview: inout BackupConflictPreview
    ) {
        for backupBinding in parsed.file.bindings {
            let binding = backupBinding.songBinding
            switch currentState.bindings[binding.trackKey] {
            case .none:
                preview.bindingsToAdd.append(binding)
            case .some(let existing) where existing != binding:
                preview.bindingReplacements.append(
                    BackupBindingReplacement(existing: existing, incoming: backupBinding)
                )
            case .some:
                break
            }
        }
    }

    private static func previewSettingChanges(
        _ parsed: BackupParseResult,
        _ currentState: BackupStoreSnapshot,
        into preview: inout BackupConflictPreview
    ) {
        for (key, incoming) in parsed.file.settings.sorted(by: { $0.key < $1.key }) {
            switch currentState.settings[key] {
            case .none:
                preview.settingsToWrite[key] = incoming
            case .some(let existing) where existing != incoming:
                preview.settingsToReplace[key] = BackupSettingReplacement(
                    existing: existing, incoming: incoming
                )
            case .some:
                break
            }
        }
    }

    /// 重新导入同一首歌的纯函数预览（确认界面数据源）。
    /// `currentBinding` 为该曲目当前绑定（nil = 全新关联）；
    /// `replacedDocument` 是该绑定指向的旧文档；
    /// `otherBindingsForReplacedDocument` 是旧文档上除当前曲目外的其他绑定。
    public static func reimportPreview(
        incomingDocument: LyricDocument,
        incomingBinding: SongBinding,
        currentBinding: SongBinding?,
        replacedDocument: LyricDocument?,
        otherBindingsForReplacedDocument: [SongBinding]
    ) -> ReimportPreview {
        var losingLastBinding: [LyricDocument] = []
        if let current = currentBinding,
           let oldDocument = replacedDocument,
           current.lyricDocumentId == oldDocument.id,
           current.lyricDocumentId != incomingDocument.id,
           otherBindingsForReplacedDocument.isEmpty {
            losingLastBinding.append(oldDocument)
        }
        return ReimportPreview(
            trackKey: incomingBinding.trackKey,
            replacedBinding: currentBinding,
            incomingDocumentId: incomingDocument.id,
            documentsLosingLastBinding: losingLastBinding
        )
    }
}
