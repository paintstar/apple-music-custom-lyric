import ShinAppleKit

extension MusicPlaybackContextScripts {
    static var stopForCleanup: String {
        wrap("""
        stop
        \(stoppedReadback)
        """, stage: .cleanup)
    }

    static var confirmStoppedForCleanup: String { wrap(stoppedReadback, stage: .cleanup) }

    private static var stoppedReadback: String {
        """
        \(cleanupStoppedState)
        if not cleanupStopped then return "pending"
        return "stopped"
        """
    }

    /// Music 停止流媒体后可能报告 paused 且无任何当前目标；普通暂停仍不能清理。
    static var cleanupStoppedState: String {
        """
        set cleanupState to player state
        set cleanupStopped to false
        if cleanupState is stopped then set cleanupStopped to true
        if cleanupState is paused then
            if not (exists current track) then
                if not (exists current playlist) then set cleanupStopped to true
            end if
        end if
        """
    }

}
