import Foundation

/// 退出清理偏好与等待上限集中定义；未设置时开启，不覆盖用户明确关闭的值。
enum PlaybackCleanupSettings {
    static let preferenceKey = "playback.cleanupManagedPlaylistsOnQuit"
    static let defaultEnabled = true
    /// 允许 Music 完成停止和删除，同时避免官方 App 无响应时阻塞退出。
    static let terminationTimeout: Duration = .seconds(10)

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: preferenceKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: preferenceKey)
    }

    static func shouldCleanup(isMock: Bool, defaults: UserDefaults = .standard) -> Bool {
        !isMock && isEnabled(defaults: defaults)
    }
}
