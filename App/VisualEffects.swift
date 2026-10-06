import AppKit
import SwiftUI

// 视觉基座（Apple Music macOS 风格）：
// - VisualEffectBackground：NSVisualEffectView 封装（侧边栏 sidebar 材质、
//   播放条 headerView 材质），明暗两模式由系统材质自适应；
// - ArtworkBackdrop：封面高斯模糊铺底 + 暗色遮罩（Apple Music 式）；
//   封面变化才重算、不参与任何动画（reduceMotion 天然满足——全是静态效果）；
// - CoverGradientPlaceholder：无封面时的「封面主色渐变占位」（曲目录键
//   决定色相，确定性输出；Mock 模式同样受益），不阻塞核心功能。

/// 播放控制的强调色，采用 Apple Music 风格的粉红色。
extension Color {
    static let appleMusicPink = Color(red: 0.980, green: 0.137, blue: 0.231)
}

/// NSVisualEffectView 的 SwiftUI 封装。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    /// 悬浮播放条等覆盖在内容上的元素用 .withinWindow（与窗口内容混合）。
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Now Playing 铺底：封面高斯模糊 + 暗色渐变遮罩；无封面时用渐变占位。
/// 静态效果（无动画修饰符）：封面变化才重建，明暗模式恒保证歌词对比度。
struct ArtworkBackdrop: View {
    /// 当前曲目封面（ArtworkStore 提供；nil = 走渐变占位）。
    let artwork: NSImage?
    /// 渐变占位种子（曲目录键；nil = 中性深色）。
    let trackKey: String?

    var body: some View {
        ZStack {
            if let artwork {
                GeometryReader { geo in
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .blur(radius: 70, opaque: true)
                .id(ObjectIdentifier(artwork))  // 封面对象变化才重建，不参与动画
            } else {
                CoverGradientPlaceholder(trackKey: trackKey)
            }
            LinearGradient(
                colors: [Color.black.opacity(0.24), Color.black.opacity(0.54)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        // scaledToFill 和模糊只裁视觉，背景图的命中范围可能跨出歌词栏。
        .allowsHitTesting(false)
    }
}

/// 正在播放与紧凑页共用封面，不把未知封面伪装成网络已加载图片。
struct PlayerArtwork: View {
    let artwork: NSImage?
    let trackKey: String?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                } else {
                    CoverGradientPlaceholder(trackKey: trackKey)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.largeTitle.weight(.light))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .contentShape(Rectangle())
        .accessibilityLabel("专辑封面")
    }
}

/// 「封面主色渐变占位」：由曲目键哈希决定的双色渐变（确定性、原创、
/// 不上传任何真实曲名），无封面/Mock/真实封面读取失败时统一走这里。
struct CoverGradientPlaceholder: View {
    let trackKey: String?

    var body: some View {
        let colors = Self.gradientColors(for: trackKey)
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// FNV-1a 派生两个稳定色相（深色系，饱和度收敛），保证同曲目稳定、
    /// 不同曲目有区分；trackKey 为 nil 时给中性深灰渐变。
    static func gradientColors(for trackKey: String?) -> [Color] {
        guard let trackKey else {
            return [
                Color(hue: 0.0, saturation: 0.0, brightness: 0.24),
                Color(hue: 0.0, saturation: 0.0, brightness: 0.38)
            ]
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in trackKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hue1 = Double(hash % 360) / 360
        let hue2 = (hue1 + 0.22 + Double((hash >> 16) % 40) / 200).truncatingRemainder(dividingBy: 1)
        return [
            Color(hue: hue1, saturation: 0.52, brightness: 0.46),
            Color(hue: hue2, saturation: 0.60, brightness: 0.30)
        ]
    }
}
