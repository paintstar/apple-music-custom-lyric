import AppKit
import SwiftUI

/// 设置页「本地数据」分类内容：保存位置切换、本地歌词资源管理入口与备份导出引导。
struct SettingsDataSectionView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isResourceManagementPresented: Bool
    /// 待确认切换的目标目录（NSOpenPanel 结果；nil = 无待确认操作）。
    @State private var pendingSwitchDirectory: URL?
    @State private var isRestoreDefaultConfirmVisible = false

    private static let storageSwitchExplanation =
        "目标位置没有歌词库时会复制当前资料。已有歌词库时会直接打开该库，两个库各自保留。"
        + "切换立即生效，原位置的数据保留。打开的导入和编辑窗口会关闭，未保存的内容将丢失。"

    var body: some View {
        let usesCustomLocation = !model.isMock && LyricsDatabase.storedOverrideDirectory() != nil
        SettingsSectionCard(title: "本地数据") {
            VStack(alignment: .leading, spacing: 12) {
                dataRow("保存位置", symbol: "folder") {
                    storageLocationDetails(usesCustomLocation: usesCustomLocation)
                } actions: {
                    if !model.isMock {
                        storageLocationControls(usesCustomLocation: usesCustomLocation)
                    }
                }
                Divider()
                dataRow("本地歌词资源", symbol: "tray.full") {
                    Text("查看或清理本机保存的歌词与译文。")
                } actions: {
                    Button("管理资源…") { isResourceManagementPresented = true }
                        .disabled(model.library == nil || model.isSwitchingStorage)
                }
                Divider()
                dataRow("备份与导出", symbol: "archivebox") {
                    Text("导入或导出完整 JSON 备份，也可导出 LRC 歌词。")
                } actions: {
                    Button("打开学习歌曲") {
                        NotificationCenter.default.post(name: .shinSelectLibraryPage, object: nil)
                    }
                }
            }
            Text("学习资料与备份都保存在本机。卸载 App 后，数据文件仍保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .alert("切换保存位置", isPresented: Binding(
            get: { pendingSwitchDirectory != nil },
            set: { if !$0 { pendingSwitchDirectory = nil } }
        )) {
            Button("切换", role: .destructive) {
                let target = pendingSwitchDirectory
                pendingSwitchDirectory = nil
                guard let target else { return }
                Task { await model.switchLyricsStorage(to: target) }
            }
            Button("取消", role: .cancel) {
                pendingSwitchDirectory = nil
            }
        } message: {
            Text(Self.storageSwitchExplanation)
        }
        .alert("恢复默认位置", isPresented: $isRestoreDefaultConfirmVisible) {
            Button("恢复", role: .destructive) {
                Task { await model.switchLyricsStorage(to: nil) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(Self.storageSwitchExplanation)
        }
    }

    private func dataRow<Details: View, Actions: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder details: () -> Details,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let heading = Text(title).font(.callout.weight(.semibold))
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        heading
                        Spacer(minLength: 0)
                        actions().fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        heading
                        actions()
                    }
                }
                details()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func storageLocationControls(usesCustomLocation: Bool) -> some View {
        HStack(spacing: 8) {
            Button("更改位置…", action: chooseStorageDirectory)
                .help("选择要使用的歌词库文件夹")
            if usesCustomLocation {
                Button("恢复默认位置") { isRestoreDefaultConfirmVisible = true }
            }
        }
        .disabled(model.isSwitchingStorage || model.library?.isDeletingResources == true)
    }

    @ViewBuilder
    private func storageLocationDetails(usesCustomLocation: Bool) -> some View {
        if let directory = model.lyricsDatabaseDirectory {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isMock ? "模拟模式 · 临时目录" : usesCustomLocation ? "自定义位置" : "默认位置")
                Text((directory.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .help(directory.path)
                    .contextMenu {
                        Button("复制完整路径") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(directory.path, forType: .string)
                        }
                    }
            }
        } else {
            Text(model.lyricsDatabaseNote)
                .textSelection(.enabled)
        }
        if !model.isMock {
            if model.isSwitchingStorage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在切换保存位置……")
                }
            }
            if let message = model.storageSwitchMessage {
                Text(message)
                    .textSelection(.enabled)
            }
        }
    }

    /// 打开系统目录选择面板（AppKit NSOpenPanel；项目允许局部增强）。
    private func chooseStorageDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择歌词数据库的保存文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingSwitchDirectory = url
    }
}
