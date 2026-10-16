import Darwin
import Dispatch
import Foundation
import GRDB

public extension GRDBLyricsStore {
    /// 歌词或关联可能变化时通知读取方重新查询，包含一次初始通知。
    /// 同步安装后返回，缓冲只保留最新通知；取消消费任务会释放监听和文件描述符。
    /// GRDB 事务通知覆盖本连接，DB/WAL 文件事件覆盖其他连接与进程。
    /// 文件不可监控时仍接收本连接的提交；通知仅表示需要重查，不代表写入成功。
    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observer = LyricsStoreChangeObserver(
                path: relocationSourcePool.path, continuation: continuation
            )
            continuation.onTermination = { @Sendable _ in observer.cancel() }
            observer.start(in: relocationSourcePool)
        }
    }
}

/// 所有可变状态限定在 queue；GRDB/stream 的回调只向该队列投递。
private final class LyricsStoreChangeObserver: @unchecked Sendable {
    private struct WatchedFile {
        let source: any DispatchSourceFileSystemObject
        let device: dev_t
        let inode: ino_t
        let token: UUID
    }

    // SQLite 的 WAL 文件名后缀是平台协议；不监视 shm，避免读锁更新引起自循环。
    private let databasePath: String
    private let directoryPath: String
    private let queue = DispatchQueue(label: "ShinAppleData.database-changes")
    private var continuation: AsyncStream<Void>.Continuation?
    private var transactionObservation: AnyDatabaseCancellable?
    private var watchedFiles: [String: WatchedFile] = [:]
    private var stopped = false
    private var notificationScheduled = false

    init(path: String, continuation: AsyncStream<Void>.Continuation) {
        databasePath = path
        directoryPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        self.continuation = continuation
    }

    func start(in pool: DatabasePool) {
        // 安装不依赖异步 Task 的执行时机，之后首个读取不会错过安装间隙里的提交。
        let observation = DatabaseRegionObservation(
            tracking: LyricDocumentRow.all(), SongBindingRow.all()
        ).start(in: pool, onError: { [weak self] _ in
            self?.requestNotification()
        }, onChange: { [weak self] _ in
            self?.requestNotification()
        })
        queue.sync {
            guard !stopped else { observation.cancel(); return }
            transactionObservation = observation
            _ = watchFile(at: directoryPath)
            _ = refreshDatabaseFiles()
            continuation?.yield(())
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            transactionObservation?.cancel()
            transactionObservation = nil
            for entry in watchedFiles.values { entry.source.cancel() }
            watchedFiles.removeAll()
            continuation = nil
        }
    }

    private func requestNotification() {
        queue.async { [weak self] in self?.scheduleNotification() }
    }

    private func scheduleNotification() {
        guard !stopped, !notificationScheduled else { return }
        notificationScheduled = true
        // 合并 SQLite 一个提交的多次文件写入；不重置期限，连续写入也不会饿死读取方。
        queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            guard let self, !stopped else { return }
            notificationScheduled = false
            continuation?.yield(())
        }
    }

    private func refreshDatabaseFiles() -> Bool {
        let databaseChanged = watchFile(at: databasePath)
        let walChanged = watchFile(at: databasePath + "-wal")
        return databaseChanged || walChanged
    }

    /// 返回文件身份是否变化。目录事件只用于重装 WAL/DB 监听，不因无关文件触发重查。
    private func watchFile(at path: String) -> Bool {
        var fileInfo = stat()
        let exists = Darwin.fstatat(AT_FDCWD, path, &fileInfo, 0) == 0
        if let current = watchedFiles[path] {
            if exists, current.device == fileInfo.st_dev, current.inode == fileInfo.st_ino { return false }
            current.source.cancel()
            watchedFiles.removeValue(forKey: path)
        } else if !exists {
            return false
        }
        guard exists else { return true }
        let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        // fstat 使用已打开的 inode；路径在 stat/open 之间变化时，下个目录事件会重新安装。
        guard Darwin.fstat(descriptor, &fileInfo) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: queue
        )
        let token = UUID()
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in self?.fileChanged(at: path, token: token) }
        watchedFiles[path] = WatchedFile(
            source: source, device: fileInfo.st_dev, inode: fileInfo.st_ino, token: token
        )
        source.resume()
        return true
    }

    private func fileChanged(at path: String, token: UUID) {
        guard !stopped, watchedFiles[path]?.token == token else { return }
        if path == directoryPath {
            if refreshDatabaseFiles() { scheduleNotification() }
        } else {
            _ = refreshDatabaseFiles()
            scheduleNotification()
        }
    }
}
