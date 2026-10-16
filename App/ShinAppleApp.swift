import SwiftUI

/// ShinApple 入口。
/// 启动参数 `--mock` 时使用 MockPlaybackController（显著橙色横幅标识），
/// 其余情况使用真实 Music 脚本适配器。
@main
struct ShinAppleApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var terminationDelegate
    @StateObject private var model: AppModel
    @StateObject private var floatingLyricsWindow = FloatingLyricsWindowController()

    init() {
        let isMock = ProcessInfo.processInfo.arguments.contains("--mock")
        let appModel = isMock ? AppModel.makeMock() : AppModel.makeReal()
        _model = StateObject(wrappedValue: appModel)
        terminationDelegate.configure(
            prepare: { appModel.prepareForTermination() },
            shouldCleanup: { PlaybackCleanupSettings.shouldCleanup(isMock: appModel.isMock) },
            cleanup: { try await appModel.controller.cleanupManagedPlaylistsOnQuit() }
        )
    }

    var body: some Scene {
        WindowGroup(id: PlayerWindowController.mainWindowGroupID) {
            ContentView(floatingLyricsWindow: floatingLyricsWindow)
                .environmentObject(model)
                .disabled(model.isTerminating)
                .frame(minWidth: PlayerWindowController.minimumSize.width,
                       minHeight: PlayerWindowController.minimumSize.height)
                .task { await model.start() }
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("悬浮歌词") {
                Button(floatingLyricsWindow.isPresented ? "关闭悬浮歌词" : "显示悬浮歌词") {
                    floatingLyricsWindow.toggle(model: model)
                }
                Button(floatingLyricsWindow.isLocked ? "解锁悬浮歌词" : "锁定悬浮歌词") {
                    floatingLyricsWindow.toggleLock()
                }
                .disabled(!floatingLyricsWindow.isPresented)
            }
        }
    }
}
