import Darwin
import Foundation
import GRDB

// 运行期保存位置切换：在线一致性备份。
// 从 GRDBLyricsStore.swift 拆出（文件长度约束）；仅操作源库的只读快照
// 与目标文件，不触碰源库数据内容。
extension GRDBLyricsStore {

    /// 把当前库一致性在线拷贝到目标路径（SQLite backup API；源库全程可用，
    /// 拷贝包含架构与学习资料，是源库某一一致时刻的快照）。
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
            try? fileManager.removeItem(atPath: tempPath + "-journal")
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
            // 缓存属于各自的歌词库，搬运学习资料时从新库的空缓存开始。
            try destination.write { db in
                try AIStudyCacheGeneration.clearCache(in: db)
            }
            try destination.writeWithoutTransaction { db in
                // 删除行后重建文件，清除空闲页中原先的缓存内容。
                try db.execute(sql: "VACUUM")
                try db.checkpoint(.truncate)
            }
            try destination.close()
        } catch {
            try? destination.close()
            throw ShinAppleDataError.storageUnavailable(
                "在线备份失败：\(targetPath)（\(Self.describe(error))）"
            )
        }
        // 同目录原子改名，同时拒绝拷贝期间出现的同名文件。
        guard renamex_np(tempPath, targetPath, UInt32(RENAME_EXCL)) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            throw ShinAppleDataError.storageUnavailable(
                "备份文件落盘失败：\(targetPath)（\(Self.describe(error))）"
            )
        }
    }

    /// 源库当前是否已有任何用户数据（文档、绑定或生词）。保存位置切换用它判断
    /// 是否需要搬运数据；空库直接在新位置重建即可。
    public func hasAnyContent() async -> Bool {
        let count = (try? await relocationSourcePool.read { db in
            let documentCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lyricDocument") ?? 0
            let bindingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM songBinding") ?? 0
            let vocabularyCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vocabularyEntry") ?? 0
            return documentCount + bindingCount + vocabularyCount
        }) ?? 0
        return count > 0
    }
}
