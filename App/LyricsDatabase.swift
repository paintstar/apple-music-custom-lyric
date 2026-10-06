import Foundation
import ShinAppleData
import ShinAppleKit
import ShinAppServices

// 本地歌词库位置与构建，保存位置可配置。
// - 真实模式默认：Application Support/ShinApple/lyrics.sqlite；
//   用户可在设置页选择自定义目录（UserDefaults 记忆，仅本机界面偏好，
//   不进歌词库备份），切换由 AppModel 运行期完成（在线备份搬数据）；
// - 启动时尊重已保存的自定义目录；目录不可用不静默回退，抛类型化错误
//   在界面呈现，用户可在设置页改回或另选位置；
// - Mock 模式（--mock）：系统临时目录下新建一次性目录，仅供演示与开发，
//   与真实数据完全隔离，可能被系统随时清理；不提供保存位置设置。
enum LyricsDatabase {

    struct Database {
        let store: GRDBLyricsStore
        /// 面向用户的位置说明（界面展示）。
        let locationDescription: String
        /// 数据所在目录（保存位置切换的对照基准；Mock 为一次性临时目录）。
        let directory: URL
    }

    /// 自定义保存目录的偏好键（plain path；App 未启用沙盒，无需 bookmark）。
    static let overrideDefaultsKey = "lyrics.dataDirectoryOverride"

    /// 真实模式默认数据目录。
    static func defaultRealDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("ShinApple", isDirectory: true)
    }

    /// 已保存的自定义目录；未设置或为空返回 nil。
    static func storedOverrideDirectory() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: overrideDefaultsKey),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// 持久化（或清除）自定义目录。
    static func storeOverride(_ directory: URL?) {
        if let directory {
            UserDefaults.standard.set(directory.path, forKey: overrideDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: overrideDefaultsKey)
        }
    }

    /// 校验目录可用：存在（或可创建）且可写（探测临时文件后清理）。
    /// 不可用抛 storageUnavailable（附路径与原因），绝不静默换位置。
    static func ensureUsableDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let probe = directory.appendingPathComponent(".shin-write-probe-\(UUID().uuidString)")
            do {
                try "probe".write(to: probe, atomically: true, encoding: .utf8)
                try FileManager.default.removeItem(at: probe)
            } catch {
                throw ShinAppleDataError.storageUnavailable(
                    "目录不可写：\(directory.path)（\(error.localizedDescription)）"
                )
            }
        } catch let error as ShinAppleDataError {
            throw error
        } catch {
            throw ShinAppleDataError.storageUnavailable(
                "目录不可用：\(directory.path)（\(error.localizedDescription)）"
            )
        }
    }

    /// 目录的面向用户说明（不含打开前备份段；那段由 makeStore 追加）。
    static func locationNote(for directory: URL, isDefault: Bool) -> String {
        let prefix = isDefault
            ? "数据目录（仅保存在本机，不上传）"
            : "数据目录（自定义位置，仅保存在本机，不上传）"
        return "\(prefix)：\(directory.path)"
    }

    static func makeStore(isMock: Bool) async throws -> Database {
        let directory: URL
        var description: String
        if isMock {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShinAppleMock-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            description = "模拟模式数据目录（临时，仅本机，可能被系统清理）：\(directory.path)"
        } else {
            // 启动尊重已保存的自定义目录；不可用即抛类型化错误（不静默回退，
            // 用户可在设置页换位置或恢复默认后重试）。
            let override = storedOverrideDirectory()
            directory = try override ?? defaultRealDirectory()
            try ensureUsableDirectory(directory)
            description = locationNote(for: directory, isDefault: override == nil)
        }
        let databasePath = directory.appendingPathComponent("lyrics.sqlite").path

        // 升级前安全备份（可选调用点，best-effort）：库文件已存在时，
        // 先经 store 的 exportPreOpenBackup 导出一份完整 JSON 快照到同一数据
        // 目录（仅本机，不含任何凭据/音频）。任何失败都不阻塞打开流程——
        // 打开本身会抛类型化错误并在界面呈现；本调用点只为「迁移失败可回到
        // 旧数据/有备份可恢复」多留一条退路。
        let preopenBackupURL = directory.appendingPathComponent("lyrics.preopen.json")
        if await GRDBLyricsStore.exportPreOpenBackup(at: databasePath, to: preopenBackupURL) {
            description += "；打开前自动备份：lyrics.preopen.json（同目录，仅本机）"
        }

        let store = try GRDBLyricsStore(path: databasePath)
        return Database(store: store, locationDescription: description, directory: directory)
    }
}

// MARK: - 错误信息的中文呈现（UI 层统一出口）
//
// 错误处理规则（各视图/模型共同遵守，代码内无自动重试循环）：
// - 错误按失败来源区分呈现（存储不可用/备份损坏/revision 冲突/输入非法…），
//   由 ImportWorkflowError / LyricsEditingError / ErrorText 分类产生；
// - 存储不可用附「检查磁盘与权限、先备份、不要删除/重建数据文件」的指引；
// - 错误消息是一次性状态位：由下一次用户操作覆盖或清除，绝不使用
//   .alert(isPresented:) 循环弹窗；重试一律由用户显式触发。

enum ErrorText {

    static func describe(_ error: Error) -> String {
        switch error {
        case let workflowError as ImportWorkflowError:
            return workflowError.message
        case let editingError as LyricsEditingError:
            return editingError.message
        case let parseError as LyricParseError:
            return parseError.message
        case let dataError as ShinAppleDataError:
            return describe(dataError)
        default:
            return "\(String(describing: type(of: error)))：\(error.localizedDescription)"
        }
    }

    static func describe(_ error: ShinAppleDataError) -> String {
        switch error {
        case .revisionConflict:
            return "歌词刚被其他窗口修改过（版本冲突），为避免覆盖已取消本次保存。请重新打开后再试。"
        case let .storageUnavailable(detail):
            // 打开/迁移失败时 detail 内嵌数据文件路径（dataFilePath 亦可在
            // 程序内提取）；数据目录同时常驻展示于歌词区底部说明。
            return "本地歌词库不可用：\(detail)。请检查磁盘空间与文件权限；"
                + "排查前请先保留数据目录的备份副本，不要删除或重建数据文件。"
        case .invalidDocument:
            return "歌词数据未通过完整性校验，已拒绝写入（原数据不受影响）。"
        case .invalidRevision:
            return "歌词版本号非法，已拒绝写入。"
        case let .invalidBinding(detail):
            return "歌曲关联数据非法：\(detail)"
        case let .invalidSettingKey(detail):
            return "设置项非法：\(detail)"
        case .documentNotFound:
            return "目标歌词文档不存在（可能已被删除）。"
        case let .documentInUse(_, count):
            return "该歌词仍被 \(count) 首歌曲关联，请先处理关联后再删除。"
        case let .invalidBackup(rejection):
            // 保留备份 parse 的类型化拒绝原因，不丢失具体原因。
            return "备份文件未通过校验（\(ShinDataFaultPresentation.backupRejectionReason(rejection))），"
                + "原数据不受影响。"
        }
    }
}
