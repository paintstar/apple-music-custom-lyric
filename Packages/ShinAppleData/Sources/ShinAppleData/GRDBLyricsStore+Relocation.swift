import Foundation
import GRDB

// 运行期保存位置切换：在线一致性备份。
// 从 GRDBLyricsStore.swift 拆出（文件长度约束）；仅操作源库的只读快照
// 与目标文件，不触碰源库数据内容。
extension GRDBLyricsStore {

    /// 把当前库一致性在线拷贝到目标路径（SQLite backup API；源库全程可用，
    /// 拷贝包含架构与全部数据，是源库某一一致时刻的完整快照）。
    /// 约束与失败语义：
    /// - 目标路径已存在数据库文件时拒绝覆盖（导入不覆盖旧数据的同一红线）；
    /// - 先写同目录临时文件、成功后原子改名，中途失败不产生半成品目标文件；
    /// - 任何失败抛 storageUnavailable（内嵌路径与原因），源库不受影响。
    public func backupDatabase(toFileAt targetPath: String) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: targetPath) {
            throw ShinAppleDataError.storageUnavailable(
                "目标位置已存在数据库文件，已拒绝覆盖：\(targetPath)"
            )
        }
        let tempPath = targetPath + ".partial-\(UUID().uuidString)"
        defer {
            // 成功路径下临时文件已改名消失；失败路径清掉半成品（连同 WAL 残留）。
            try? fileManager.removeItem(atPath: tempPath)
            try? fileManager.removeItem(atPath: tempPath + "-wal")
            try? fileManager.removeItem(atPath: tempPath + "-shm")
        }
        let destination: DatabasePool
        do {
            destination = try DatabasePool(path: tempPath)
        } catch {
            throw ShinAppleDataError.storageUnavailable(
                "无法在目标位置创建数据库文件：\(targetPath)（\(Self.describe(error))）"
            )
        }
        do {
            try relocationSourcePool.backup(to: destination)
            // 关闭以合并 WAL 并释放句柄，之后改名才是完整的单文件。
            try destination.close()
        } catch {
            throw ShinAppleDataError.storageUnavailable(
                "在线备份失败：\(targetPath)（\(Self.describe(error))）"
            )
        }
        do {
            try fileManager.moveItem(atPath: tempPath, toPath: targetPath)
        } catch {
            throw ShinAppleDataError.storageUnavailable(
                "备份文件落盘失败：\(targetPath)（\(Self.describe(error))）"
            )
        }
    }

    /// 源库当前是否已有任何用户数据（文档或绑定）。保存位置切换用它判断
    /// 是否需要搬运数据；空库直接在新位置重建即可。
    public func hasAnyContent() async -> Bool {
        let documentCount = (try? await relocationSourcePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lyricDocument") ?? 0
        }) ?? 0
        let bindingCount = (try? await relocationSourcePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM songBinding") ?? 0
        }) ?? 0
        return documentCount + bindingCount > 0
    }
}
