import SwiftUI

/// 设置页分类，用于快速定位播放、获取、AI 学习、显示与本地数据设置。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case playback
    case autoFetch
    case aiStudy
    case display
    case data

    static let preferenceKey = "settings.selectedCategory"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playback: return "播放与来源"
        case .autoFetch: return "歌词获取"
        case .aiStudy: return "AI 与学习"
        case .display: return "歌词显示"
        case .data: return "本地数据"
        }
    }

    var symbol: String {
        switch self {
        case .playback: return "play.fill"
        case .autoFetch: return "arrow.down.doc.fill"
        case .aiStudy: return "sparkles"
        case .display: return "textformat.size"
        case .data: return "externaldrive.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .playback: return Color.appleMusicPink
        case .autoFetch: return .blue
        case .aiStudy: return .purple
        case .display: return .teal
        case .data: return .orange
        }
    }

    var subtitle: String {
        switch self {
        case .playback: return "「音乐」App 连接、临时清单清理与播放诊断"
        case .autoFetch: return "网易云音乐自动获取开关、列表勾选与记录"
        case .aiStudy: return "AI 服务商、钥匙串密钥、注音偏好与划词窗口"
        case .display: return "中文译文、注音字号、回到当前歌词与悬浮歌词排版"
        case .data: return "保存位置、本地歌词资源与备份导出"
        }
    }
}

/// 仿 macOS 系统设置风格的彩色圆角图标徽章。
struct SettingsCategoryIconBadge: View {
    let category: SettingsCategory
    var size: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            shape
                .fill(category.accentColor.gradient)
            Image(systemName: category.symbol)
                .font(.system(size: size * 0.50, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay {
            shape
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: category.accentColor.opacity(0.22), radius: 2, y: 1)
    }
}

/// 设置页左侧竖向分栏导航（标准宽度 >= 580pt 使用）。
struct SettingsNavigationSidebar: View {
    let selectedCategory: SettingsCategory
    var bottomContentInset: CGFloat = 0
    let onSelect: (SettingsCategory) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("设置")
                    .font(.system(size: 20, weight: .bold))
                Text("播放、学习与本地数据偏好")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 22)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SettingsCategory.allCases) { category in
                        SettingsSidebarItemButton(
                            category: category,
                            isSelected: selectedCategory == category,
                            action: { onSelect(category) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, max(16, bottomContentInset))
            }
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.025))
    }
}

private struct SettingsSidebarItemButton: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsCategoryIconBadge(category: category, size: 24)
                Text(category.title)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(foregroundColor)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(backgroundColor, in: shape)
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(category.accentColor)
                        .frame(width: 3, height: 16)
                        .padding(.leading, 3)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isSelected {
                    shape
                        .strokeBorder(category.accentColor.opacity(0.28), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(category.subtitle)
    }

    private var foregroundColor: Color {
        if isSelected || isHovered { return .primary }
        return .primary.opacity(0.82)
    }

    private var backgroundColor: Color {
        if isSelected { return category.accentColor.opacity(0.15) }
        return isHovered ? Color.primary.opacity(0.06) : .clear
    }
}

/// 右侧设置内容顶部主题头：彩色图标徽章、分类标题、说明与细分割线。
struct SettingsCategoryDetailHeader: View {
    let category: SettingsCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SettingsCategoryIconBadge(category: category, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.title)
                        .font(.title3.weight(.bold))
                    Text(category.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Divider()
                .opacity(0.6)
        }
    }
}

/// 窄窗回退导航栏（可用宽度 < 580pt 时优雅降级为顶部横向标签）。
struct SettingsCompactNavigationBar: View {
    let selectedCategory: SettingsCategory
    let onSelect: (SettingsCategory) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("设置")
                    .font(.system(size: 20, weight: .bold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(SettingsCategory.allCases) { category in
                            SettingsCompactTabButton(
                                category: category,
                                isSelected: selectedCategory == category,
                                action: { onSelect(category) }
                            )
                        }
                    }
                    .padding(.vertical, 1)
                }
                Text(selectedCategory.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
    }
}

private struct SettingsCompactTabButton: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                SettingsCategoryIconBadge(category: category, size: 18)
                Text(category.title)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(backgroundColor, in: shape)
            .overlay {
                shape
                    .strokeBorder(borderColor, lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(category.subtitle)
    }

    private var foregroundColor: Color {
        isSelected || isHovered ? .primary : .primary.opacity(0.82)
    }

    private var backgroundColor: Color {
        if isSelected { return category.accentColor.opacity(0.15) }
        return isHovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03)
    }

    private var borderColor: Color {
        if isSelected { return category.accentColor.opacity(0.28) }
        return Color.primary.opacity(isHovered ? 0.14 : 0.08)
    }
}

/// 设置页分区容器（分组头 + 圆角内容卡片）。
struct SettingsSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.primary.opacity(0.045), in: cardShape)
            .overlay {
                cardShape
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
        }
    }
}
