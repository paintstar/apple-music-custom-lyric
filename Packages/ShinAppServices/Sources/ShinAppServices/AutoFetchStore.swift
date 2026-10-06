import Foundation
import ShinAppleKit
import ShinAppleData

// 歌单自动获取的状态存储。
// 全部经 GRDB settings 表的 JSON 键值，随库备份/恢复，不引入新表；
// 语义是「机器可读的状态」，UI 展示文案由 App 层生成。
//
// 键（key）总览（`lyrics.autoFetch.` 前缀）：
// - enabled           总开关（"1"/"0"）
// - playlists         勾选歌单 persistent ID 列表（JSON 数组）
// - snapshot.<id>     各歌单成员快照（上次看到的 trackKey 集合）
// - pending           待确认匹配队列（JSON 数组，容量受限）
// - ignored           用户标记「不再自动获取」的 trackKey（JSON 数组，容量受限）
// - audit             自动动作审计（JSON 数组，最近在前，容量受限）
// - work              尚未完成的成员增删工作，与观察快照原子保存

/// 自动获取设置。
public struct AutoFetchSettings: Equatable, Sendable {
    public var isEnabled: Bool
    /// 勾选监控的歌单 persistent ID 列表。
    public var playlistIDs: [String]

    public init(isEnabled: Bool = false, playlistIDs: [String] = []) {
        self.isEnabled = isEnabled
        self.playlistIDs = playlistIDs
    }
}

/// 歌单成员快照（diff 基准）。
public struct PlaylistMembershipSnapshot: Equatable, Codable, Sendable {
    public let playlistID: String
    /// 快照时的歌单名（歌单改名不影响身份判定，仅展示用）。
    public let playlistName: String?
    public let memberTrackKeys: [String]
    public let takenAt: String

    public init(
        playlistID: String,
        playlistName: String?,
        memberTrackKeys: [String],
        takenAt: String = LyricTimestamp.now()
    ) {
        self.playlistID = playlistID
        self.playlistName = playlistName
        self.memberTrackKeys = memberTrackKeys
        self.takenAt = takenAt
    }
}

/// 一次 diff 的结果。
public struct PlaylistMembershipDiff: Equatable, Sendable {
    public let added: [String]
    public let removed: [String]
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

/// 快照 diff（纯函数）。
public enum PlaylistMembershipDiffer {
    /// 无上次快照（首次监控）时：全部视为「已存在」，不触发获取/删除
    /// ——首次勾选只建立基准，行为可预期（老歌不自动抓一轮）。
    /// 如需补齐存量，用户可对单曲手动获取或将来提供「立即全部获取」。
    public static func diff(previous: [String]?, current: [String]) -> PlaylistMembershipDiff {
        guard let previous else {
            return PlaylistMembershipDiff(added: [], removed: [])
        }
        let previousSet = Set(previous)
        let currentSet = Set(current)
        return PlaylistMembershipDiff(
            added: current.filter { !previousSet.contains($0) },
            removed: previous.filter { !currentSet.contains($0) }
        )
    }
}

/// 待确认匹配记录（低置信候选进队列，用户逐个处理）。
public struct PendingAutoFetchItem: Equatable, Codable, Sendable, Identifiable {
    public let trackKey: String
    public let title: String
    public let artist: String?
    /// 最佳候选的摘要信息（展示用）。
    public let topCandidateTitle: String?
    public let topCandidateArtist: String?
    public let enqueuedAt: String

    public var id: String { trackKey }

    public init(
        trackKey: String,
        title: String,
        artist: String?,
        topCandidateTitle: String?,
        topCandidateArtist: String?,
        enqueuedAt: String = LyricTimestamp.now()
    ) {
        self.trackKey = trackKey
        self.title = title
        self.artist = artist
        self.topCandidateTitle = topCandidateTitle
        self.topCandidateArtist = topCandidateArtist
        self.enqueuedAt = enqueuedAt
    }
}

/// 自动动作审计条目（自动获取落位/跳过/删除均记录，用户可查）。
public struct AutoFetchAuditEntry: Equatable, Codable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable {
        case imported = "自动获取"
        case deleted = "自动删除"
        case skipped = "保留跳过"
        case pending = "待确认"
        case failed = "获取失败"
    }

    public var id: String { "\(happenedAt)#\(trackKey)#\(action.rawValue)" }
    public let action: Action
    public let trackKey: String
    public let title: String
    /// 中文说明（原因/结果摘要）。
    public let detail: String
    public let happenedAt: String

    public init(
        action: Action,
        trackKey: String,
        title: String,
        detail: String,
        happenedAt: String = LyricTimestamp.now()
    ) {
        self.action = action
        self.trackKey = trackKey
        self.title = title
        self.detail = detail
        self.happenedAt = happenedAt
    }
}

/// 尚未完成的自动工作；来源歌单用于取消监控时清理待办，不删除歌词。
public struct AutoFetchWorkItem: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case fetch, remove }
    public let kind: Kind
    public let trackKey: String
    public var playlistIDs: [String]
    public var id: String { "\(kind.rawValue)#\(trackKey)" }

    public init(kind: Kind, trackKey: String, playlistIDs: [String]) {
        self.kind = kind
        self.trackKey = trackKey
        self.playlistIDs = playlistIDs
    }
}

/// 自动获取状态仓库：settings 表之上的类型化读写。
/// 写失败抛类型化错误（调用方呈现）；读失败按「未配置」处理不抛。
/// Sendable 值类型：仅持有 Sendable 的 store，可跨 actor 安全传递。
public struct AutoFetchStore: Sendable {
    private let store: GRDBLyricsStore

    public init(store: GRDBLyricsStore) {
        self.store = store
    }

    // MARK: - 键常量（公开供审计与测试核对）

    public static let enabledKey = "lyrics.autoFetch.enabled"
    public static let playlistsKey = "lyrics.autoFetch.playlists"
    public static let snapshotKeyPrefix = "lyrics.autoFetch.snapshot."
    public static let pendingKey = "lyrics.autoFetch.pending"
    public static let ignoredKey = "lyrics.autoFetch.ignored"
    public static let auditKey = "lyrics.autoFetch.audit"
    public static let workKey = "lyrics.autoFetch.work"

    static let pendingCapacity = 200
    static let ignoredCapacity = 500
    static let auditCapacity = 100

    // MARK: - 设置

    public func loadSettings() async -> AutoFetchSettings {
        let enabled = (try? await store.settingValue(forKey: Self.enabledKey)) == "1"
        let playlistIDs = await loadJSONList([String].self, forKey: Self.playlistsKey) ?? []
        return AutoFetchSettings(isEnabled: enabled, playlistIDs: playlistIDs)
    }

    public func saveSettings(_ settings: AutoFetchSettings) async throws {
        try await store.setSettingValues([
            Self.enabledKey: settings.isEnabled ? "1" : "0",
            Self.playlistsKey: Self.encodeList(settings.playlistIDs)
        ])
    }

    // MARK: - 快照

    public func snapshot(playlistID: String) async -> PlaylistMembershipSnapshot? {
        await loadJSON(PlaylistMembershipSnapshot.self, forKey: Self.snapshotKeyPrefix + playlistID)
    }

    public func saveSnapshot(_ snapshot: PlaylistMembershipSnapshot) async throws {
        try await store.setSettingValue(
            Self.encodeJSON(snapshot),
            forKey: Self.snapshotKeyPrefix + snapshot.playlistID
        )
    }

    /// 观察结果与新待办一起持久化。已成功工作逐项确认，失败不阻止观察新移出。
    public func recordObservations(
        _ snapshots: [PlaylistMembershipSnapshot], work: [AutoFetchWorkItem],
        activePlaylistIDs: [String], isValid: @escaping @Sendable () -> Bool
    ) async throws {
        try await store.updateSettings(isValid: isValid) { values in
            let active = Set(activePlaylistIDs)
            var items = try Self.decodeWork(values[Self.workKey]).compactMap { item -> AutoFetchWorkItem? in
                var retained = item
                retained.playlistIDs = item.playlistIDs.filter { active.contains($0) }
                return retained.playlistIDs.isEmpty ? nil : retained
            }
            for item in work {
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index].playlistIDs = Array(Set(items[index].playlistIDs + item.playlistIDs)).sorted()
                } else {
                    items.append(item)
                }
            }
            var updates: [String: String?] = [Self.workKey: Self.encodeJSON(items)]
            for snapshot in snapshots {
                updates[Self.snapshotKeyPrefix + snapshot.playlistID] = Self.encodeJSON(snapshot)
            }
            return updates
        }
    }

    /// 持久待办读取失败须停止处理，不能当成没有工作并消费观察结果。
    public func workItems() async throws -> [AutoFetchWorkItem] {
        try Self.decodeWork(try await store.settingValue(forKey: Self.workKey))
    }

    public func completeWork(_ item: AutoFetchWorkItem, isValid: @escaping @Sendable () -> Bool) async throws {
        try await store.updateSettings(isValid: isValid) { values in
            let remaining = try Self.decodeWork(values[Self.workKey]).filter { $0.id != item.id }
            return [Self.workKey: Self.encodeJSON(remaining)]
        }
    }

    /// 取消监控时同时清该歌单的基准与未完成工作；已获取歌词保持原状。
    public func removeSnapshot(playlistID: String) async {
        try? await store.updateSettings { values in
            // 快速重新勾选已先写入设置时，旧取消动作不能清掉新的基准。
            let selected = values[Self.playlistsKey].flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            guard !selected.contains(playlistID) else { return [:] }
            let remaining = try Self.decodeWork(values[Self.workKey]).compactMap { item -> AutoFetchWorkItem? in
                var retained = item
                retained.playlistIDs.removeAll { $0 == playlistID }
                return retained.playlistIDs.isEmpty ? nil : retained
            }
            return [Self.snapshotKeyPrefix + playlistID: nil, Self.workKey: Self.encodeJSON(remaining)]
        }
    }

    private static func decodeWork(_ raw: String?) throws -> [AutoFetchWorkItem] {
        guard let raw else { return [] }
        return try JSONDecoder().decode([AutoFetchWorkItem].self, from: Data(raw.utf8))
    }

    // MARK: - 待确认队列

    public func pendingItems() async -> [PendingAutoFetchItem] {
        await loadJSONList([PendingAutoFetchItem].self, forKey: Self.pendingKey) ?? []
    }

    /// 加入待确认队列（同 trackKey 去重；超容量淘汰最旧）。
    public func enqueuePending(
        _ item: PendingAutoFetchItem, isValid: @escaping @Sendable () -> Bool = { true }
    ) async throws {
        var items = await pendingItems()
        items.removeAll { $0.trackKey == item.trackKey }
        items.append(item)
        if items.count > Self.pendingCapacity {
            items = Array(items.suffix(Self.pendingCapacity))
        }
        try await store.setSettingValues([Self.pendingKey: Self.encodeJSON(items)], isValid: isValid)
    }

    public func removePending(trackKey: String) async throws {
        var items = await pendingItems()
        items.removeAll { $0.trackKey == trackKey }
        try await store.setSettingValue(Self.encodeJSON(items), forKey: Self.pendingKey)
    }

    // MARK: - 忽略清单

    public func ignoredTrackKeys() async -> Set<String> {
        Set(await loadJSONList([String].self, forKey: Self.ignoredKey) ?? [])
    }

    public func ignore(trackKey: String) async throws {
        var keys = Array(await ignoredTrackKeys())
        guard !keys.contains(trackKey) else { return }
        keys.append(trackKey)
        if keys.count > Self.ignoredCapacity {
            keys = Array(keys.suffix(Self.ignoredCapacity))
        }
        try await store.setSettingValue(Self.encodeList(keys), forKey: Self.ignoredKey)
    }

    // MARK: - 审计

    public func auditEntries() async -> [AutoFetchAuditEntry] {
        await loadJSONList([AutoFetchAuditEntry].self, forKey: Self.auditKey) ?? []
    }

    /// 追加审计条目（最近在前；超容量淘汰最旧）。
    public func appendAudit(
        _ entry: AutoFetchAuditEntry, isValid: @escaping @Sendable () -> Bool = { true }
    ) async {
        var entries = await auditEntries()
        entries.insert(entry, at: 0)
        if entries.count > Self.auditCapacity {
            entries = Array(entries.prefix(Self.auditCapacity))
        }
        try? await store.setSettingValues([Self.auditKey: Self.encodeJSON(entries)], isValid: isValid)
    }

    // MARK: - JSON 编解码（失败不抛：读侧降级，写侧由调用方决定）

    private func loadJSON<T: Decodable>(_ type: T.Type, forKey key: String) async -> T? {
        guard let raw = try? await store.settingValue(forKey: key),
              let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func loadJSONList<T: Decodable>(_ type: [T].Type, forKey key: String) async -> [T]? {
        guard let raw = try? await store.settingValue(forKey: key),
              let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode([T].self, from: data)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }

    private static func encodeList(_ values: [String]) -> String {
        encodeJSON(values)
    }
}
