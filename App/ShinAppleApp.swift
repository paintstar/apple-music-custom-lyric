import SwiftUI

/// ShinApple 入口。
/// 启动参数 `--mock` 时使用 MockPlaybackController（显著橙色横幅标识），
/// 其余情况使用真实 Music 脚本适配器。
@main
struct ShinAppleApp: App {
    @StateObject private var model: AppModel

    init() {
        let isMock = ProcessInfo.processInfo.arguments.contains("--mock")
        if isMock {
            _model = StateObject(wrappedValue: AppModel.makeMock())
        } else {
            _model = StateObject(wrappedValue: AppModel.makeReal())
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: PlayerWindowController.minimumSize.width,
                       minHeight: PlayerWindowController.minimumSize.height)
                .task { await model.start() }
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
    }
}
