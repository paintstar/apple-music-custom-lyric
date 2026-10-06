import Foundation

/// 可手动推进的假时钟。
/// Mock 播放器的时间只来自该时钟：相同输入产生确定输出，
/// 不使用任何真实定时器累加。
public final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _nowMs: Int64 = 0

    public init(nowMs: Int64 = 0) {
        self._nowMs = nowMs
    }

    /// 当前时钟读数（整数毫秒）。
    public var nowMs: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return _nowMs
    }

    /// 手动把时钟向前拨。负值会被忽略（假时钟不倒退）。
    public func advance(byMs ms: Int64) {
        guard ms > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        _nowMs += ms
    }

    /// 直接设置时钟读数（测试种子用）。
    public func set(toMs ms: Int64) {
        lock.lock()
        defer { lock.unlock() }
        _nowMs = ms
    }
}
