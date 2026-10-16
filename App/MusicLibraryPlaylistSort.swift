import Foundation
import ShinAppleKit

/// 当前批量脚本读序不保证等同官方界面显示顺序；记录用户在本应用选择的顺序。
struct MusicLibraryPlaylistSort: Codable, Equatable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable {
        case returnedOrder, title, artist, album, dateAdded, duration

        var title: String {
            switch self {
            case .returnedOrder: return "歌单返回顺序"
            case .title: return "歌曲名称"
            case .artist: return "艺人"
            case .album: return "专辑"
            case .dateAdded: return "添加时间"
            case .duration: return "时长"
            }
        }
    }

    var field: Field = .returnedOrder
    var ascending = true

    func applying(to tracks: [MusicLibraryTrack]) -> [MusicLibraryTrack] {
        if field == .returnedOrder { return ascending ? tracks : Array(tracks.reversed()) }
        return tracks.enumerated().sorted { left, right in
            let order = comparison(left.element, right.element)
            return order == .orderedSame ? left.offset < right.offset : order == .orderedAscending
        }.map(\.element)
    }

    private func comparison(_ left: MusicLibraryTrack, _ right: MusicLibraryTrack) -> ComparisonResult {
        switch field {
        case .returnedOrder: return .orderedSame
        case .title: return textOrder(left.title, right.title)
        case .artist: return textOrder(left.artist, right.artist)
        case .album: return textOrder(left.album, right.album)
        case .dateAdded: return optionalOrder(left.dateAdded, right.dateAdded) { $0.compare($1) }
        case .duration:
            return optionalOrder(left.durationMs, right.durationMs) { left, right in
                left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            }
        }
    }

    private func textOrder(_ left: String?, _ right: String?) -> ComparisonResult {
        func knownText(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        return optionalOrder(knownText(left), knownText(right)) { $0.localizedStandardCompare($1) }
    }

    private func optionalOrder<Value>(_ left: Value?, _ right: Value?,
                                      compare: (Value, Value) -> ComparisonResult) -> ComparisonResult {
        switch (left, right) {
        case (.none, .none): return .orderedSame
        case (.none, .some): return .orderedDescending
        case (.some, .none): return .orderedAscending
        case let (.some(left), .some(right)):
            let order = compare(left, right)
            guard !ascending, order != .orderedSame else { return order }
            return order == .orderedAscending ? .orderedDescending : .orderedAscending
        }
    }
}

@MainActor
final class MusicLibraryPlaylistSortPreferences {
    private static let key = "musicLibrary.playlistSort"
    private let defaults: UserDefaults
    private var values: [String: MusicLibraryPlaylistSort] {
        defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: MusicLibraryPlaylistSort].self, from: $0) } ?? [:]
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func value(for playlistID: String) -> MusicLibraryPlaylistSort { values[playlistID] ?? MusicLibraryPlaylistSort() }

    func save(_ sort: MusicLibraryPlaylistSort, for playlistID: String) {
        // 多窗口在主线程依次合并最新值，不用各自初始化时的整表快照覆盖其他歌单。
        var values = values
        values[playlistID] = sort == MusicLibraryPlaylistSort() ? nil : sort
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
