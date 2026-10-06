import AppKit
import SwiftUI

/// 只为可见条目读取本机封面；不可用时保留明确的图标占位。
struct MusicLibraryArtworkView: View {
    let browser: MusicLibraryBrowserModel
    let trackRef: String?
    var symbol = "music.note"
    @State private var artwork: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.055)
                if let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol)
                        .resizable().scaledToFit()
                        .frame(width: geometry.size.width * 0.40, height: geometry.size.height * 0.40)
                        .foregroundStyle(Color.appleMusicPink.opacity(0.85))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .contentShape(Rectangle())
        .task(id: trackRef) {
            artwork = nil
            guard let trackRef else { return }
            let data = await browser.artworkData(for: trackRef)
            guard !Task.isCancelled, let data else { return }
            artwork = NSImage(data: data)
        }
        .onDisappear { artwork = nil }
        .accessibilityHidden(true)
    }
}
