import SwiftUI

struct VocabularyPlaybackAlert: ViewModifier {
    @ObservedObject var book: VocabularyBookModel
    let source: VocabularyPlaybackSource

    func body(content: Content) -> some View {
        let confirmation = book.playbackConfirmation(for: source)
        return content.alert(
            "切换播放歌曲？",
            isPresented: Binding(
                get: { confirmation != nil && book.playbackConfirmation(for: source)?.id == confirmation?.id },
                set: { if !$0, let confirmation { book.dismissPlaybackConfirmation(confirmation) } }
            ),
            presenting: confirmation
        ) { confirmation in
            Button("切换并播放", role: .destructive) { book.confirmPlayback(confirmation) }
            Button("取消", role: .cancel) { book.dismissPlaybackConfirmation(confirmation) }
                .keyboardShortcut(.defaultAction)
        } message: { confirmation in
            if let title = confirmation.trackTitle {
                Text("将停止当前播放队列，并播放「\(title)」的原声例句。")
            } else {
                Text("将停止当前播放队列，并播放这条例句所在的歌曲。")
            }
        }
    }
}
