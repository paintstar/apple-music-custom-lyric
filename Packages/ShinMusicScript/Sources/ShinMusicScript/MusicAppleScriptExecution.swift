import Foundation

/// OSA 运行时在进程内串行使用；正式 App 并发首次执行曾返回 errOSAInvalidID。
/// 闭包只做同步脚本工作，不等待主线程、不获取播放执行锁，也不跨 await。
enum MusicAppleScriptExecution {
    private static let lock = NSLock()

    static func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        try lock.withLock {
            // NSAppleScript 及其自动释放对象必须在解锁前释放，不能跨调用保留脚本实例。
            try autoreleasepool(invoking: operation)
        }
    }
}
