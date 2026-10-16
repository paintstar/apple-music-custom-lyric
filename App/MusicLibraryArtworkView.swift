import AppKit
import SwiftUI
import ShinAppleKit

/// 只为可见条目读取本机封面；不可用时保留明确的图标占位。
struct MusicLibraryArtworkView: View {
    @ObservedObject var browser: MusicLibraryBrowserModel
    let trackRef: String?
    var source: MusicLibrarySource?
    var symbol = "music.note"
    @State private var artwork: NSImage?

    private struct RequestIdentity: Hashable {
        let trackRef: String?
        let source: MusicLibrarySource
        let refreshVersion: Int
    }

    private var requestIdentity: RequestIdentity {
        RequestIdentity(trackRef: trackRef, source: source ?? browser.destination.source,
                        refreshVersion: browser.artworkRequestVersion)
    }

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
        .task(id: requestIdentity) {
            artwork = nil
            guard let trackRef else { return }
            let source = requestIdentity.source
            for attempt in 0...ArtworkLoadingPolicy.retryDelays.count {
                if attempt > 0 {
                    do { try await Task.sleep(for: ArtworkLoadingPolicy.retryDelays[attempt - 1]) } catch { return }
                }
                guard !Task.isCancelled else { return }
                let data = await browser.artworkData(for: trackRef, in: source)
                guard !Task.isCancelled else { return }
                if let data, let image = NSImage(data: data), image.isValid {
                    artwork = image
                    return
                }
            }
        }
        .onDisappear { artwork = nil }
        .accessibilityHidden(true)
    }
}
