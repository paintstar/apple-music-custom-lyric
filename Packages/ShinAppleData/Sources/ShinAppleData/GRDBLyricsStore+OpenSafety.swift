import Foundation
import GRDB

// MARK: - 打开安全路径：结构化失败消息 + 升级前安全备份
//
// 从 GRDBLyricsStore 主体拆出，保持存储主文件的单一职责；
// 行为与契约不变，仅文件组织调整（SwiftLint file/type length）。

extension GRDBLyricsStore {

    // MARK: - 结构化失败消息

    /// 打开失败的结构化消息：前缀 + 路径 + 「：」 + 细节
    /// （`ShinAppleDataError.dataFilePath` 依赖该格式提取路径，两处需同步）。
    static func openFailureMessage(path: String, detail: String) -> String {
        "无法打开数据库 \(path)：\(detail)"
    }

    /// 迁移失败的结构化消息（格式约束同上）。
    static func migrationFailureMessage(path: String, detail: String) -> String {
        "数据库迁移失败（原库保留在上一版本）：\(path)：\(detail)"
    }

    // MARK: - 升级前安全备份

    /// 升级前安全备份：打开入口处的**可选调用点**，复用 `exportBackup`
    ///
    /// - 数据库文件存在且可用当前迁移器打开时，把全部数据导出为完整 JSON
    ///   备份并**原子写入** `destination`（建议放在同一数据目录下，仅本机，
    ///   内容不含 token/音频/Apple 会话信息）；
    /// - 任何一步失败（文件不存在、库损坏、迁移失败、目标不可写）都返回
    ///   `false`：不抛错、不删除或重建库文件、不阻塞随后的正常打开——
    ///   正常打开会抛出自己的类型化错误；
    /// - v1 当前没有待执行迁移（本调用即「打开前快照」）；未来 schema 升级
    ///   落地时，App 打开入口应**先**以「上一版本迁移器」完成备份、**再**
    ///   正常打开触发升级。这样即使新迁移中途失败，用户手里仍有升级前的
    ///   完整快照可恢复（迁移本身事务回滚，旧数据也可读，双保险）。
    public static func exportPreOpenBackup(
        at path: String,
        to destination: URL,
        backupConfiguration: BackupConfiguration = .standard
    ) async -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            let pool = try DatabasePool(path: path, configuration: configuration)
            try Schema.migrator().migrate(pool)
            let store = GRDBLyricsStore(ownedPool: pool, backupConfiguration: backupConfiguration)
            let data = try await store.exportBackup()
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            // best-effort：备份失败不拦截打开流程。
            return false
        }
    }
}
