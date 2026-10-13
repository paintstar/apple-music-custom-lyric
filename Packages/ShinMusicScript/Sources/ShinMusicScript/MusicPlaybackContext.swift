import Foundation
import ShinAppleKit

/// 仅记录本 App 创建的歌单。随机标记和成员共同防止认领同名或被用户改动的歌单。
struct MusicPlaybackContextOwnership: Codable, Equatable, Sendable {
    var playlistID: String
    var token: UUID
    var trackIDs: [String]
    /// play 已发送但尚未确认时保留，包含取消/超时以及下一次重试前的清理。
    var playbackRequested: Bool?
    /// 旧记录只认可原固定名；新记录只认可 token 推导的唯一名，不存可执行用户文本。
    var usesUniqueName: Bool?
}

protocol MusicPlaybackContextExecuting: Sendable {
    func create(token: UUID, checkCancellation: () throws -> Void) throws -> String
    func append(_ ids: [String], to ownership: MusicPlaybackContextOwnership, from source: MusicLibrarySource,
                checkCancellation: () throws -> Void) throws -> [String]
    func start(_ ownership: MusicPlaybackContextOwnership, at persistentID: String, shuffleEnabled: Bool?,
               checkCancellation: () throws -> Void) throws
    /// false 只表示发送 play 前已确认不是完整原歌单或可复用的管理歌单。
    func shuffleSource(_ ids: [String], in source: MusicLibrarySource, checkCancellation: () throws -> Void) throws -> Bool
    func shuffleManaged(_ ownership: MusicPlaybackContextOwnership, checkCancellation: () throws -> Void) throws -> Bool
    /// 返回 true 表示已删除、已不存在或用户改动后已释放所有权；false 表示仍在播放，保留以便后续清理。
    func remove(_ ownership: MusicPlaybackContextOwnership) throws -> Bool
}

/// 只在控制器的播放命令串行队列访问；重启后的清理也必须重新验证所有权及成员。
final class MusicPlaybackContext {
    private let executor: any MusicPlaybackContextExecuting
    private let defaults: UserDefaults
    private var owned: [MusicPlaybackContextOwnership]
    private static let storageKey = "ShinApple.musicPlaybackContexts"
    /// 每批只复制少量 Music 对象引用，批次之间检查取消并让采样继续。
    private static let copyBatchSize = 24

    init(executor: any MusicPlaybackContextExecuting = AppleScriptMusicPlaybackContextExecutor(),
         defaults: UserDefaults = .standard) {
        self.executor = executor
        self.defaults = defaults
        owned = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([MusicPlaybackContextOwnership].self, from: $0) } ?? []
    }

    /// 显示层只收起本机所有权记录对应的准确名称；Music 内保留唯一名，用户同名歌单不变。
    static func ownedPlaylistNames(defaults: UserDefaults = .standard) -> [String: String] {
        let records = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([MusicPlaybackContextOwnership].self, from: $0) } ?? []
        return records.reduce(into: [:]) { names, ownership in
            names[ownership.playlistID] = MusicPlaybackContextScripts.expectedName(for: ownership)
        }
    }

    func shuffle(_ ids: [String], in source: MusicLibrarySource, checkCancellation: () throws -> Void) throws {
        guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy(SongBinding.isValidPersistentID) else {
            throw MusicLibraryError.invalidRequest
        }
        if case let .playlist(id) = source, !SongBinding.isValidPersistentID(id) { throw MusicLibraryError.invalidRequest }
        try checkCancellation()
        // 不提前清理旧请求：直接启动同样可能异步确认，失败时旧 pending 上下文必须保留。
        let isOwnedSource = owned.contains { source == .playlist(id: $0.playlistID) }
        if !isOwnedSource, try executor.shuffleSource(ids, in: source, checkCancellation: checkCancellation) {
            finishConfirmedPlayback(excluding: source)
            try checkCancellation()
            return
        }
        if let index = owned.lastIndex(where: {
            $0.playbackRequested != true && $0.trackIDs.count == ids.count && Set($0.trackIDs) == Set(ids)
        }) {
            owned[index].playbackRequested = true
            save()
            if try executor.shuffleManaged(owned[index], checkCancellation: checkCancellation) {
                finishConfirmedPlayback(excluding: source)
                try checkCancellation()
                return
            }
            // 校验在发送 play 前失败，释放本次保护；用户修改的歌单仍由精确清理规则保留。
            owned[index].playbackRequested = false
            save()
        }
        try checkCancellation()
        cleanUp(excluding: source)
        do {
            let ownership = try build(ids, in: source, checkCancellation: checkCancellation)
            try checkCancellation()
            markPlaybackRequested(ownership)
            guard try executor.shuffleManaged(ownership, checkCancellation: checkCancellation) else {
                throw MusicPlaybackContextError(stage: .readback)
            }
            finishConfirmedPlayback(excluding: source)
            try checkCancellation()
        } catch {
            cleanUp(excluding: source)
            throw error
        }
    }

    func play(_ ids: [String], startingAt id: String, in source: MusicLibrarySource,
              shuffleEnabled: Bool?, checkCancellation: () throws -> Void) throws {
        guard !ids.isEmpty, Set(ids).count == ids.count, ids.contains(id),
              ids.allSatisfy(SongBinding.isValidPersistentID) else { throw MusicLibraryError.invalidRequest }
        let startIndex = ids.firstIndex(of: id)!
        let playbackIDs = Array(ids[startIndex...]) + Array(ids[..<startIndex])
        if case let .playlist(id: playlistID) = source,
           !SongBinding.isValidPersistentID(playlistID) { throw MusicLibraryError.invalidRequest }
        try checkCancellation()
        cleanUp(excluding: source)
        try checkCancellation()
        do {
            let ownership = try build(playbackIDs, in: source, checkCancellation: checkCancellation)
            try checkCancellation()
            // Music 的 shuffle 属性在无曲目时可能不可用，先建立新歌单的实际播放上下文。
            markPlaybackRequested(ownership)
            try executor.start(ownership, at: id, shuffleEnabled: shuffleEnabled, checkCancellation: checkCancellation)
            finishConfirmedPlayback()
            try checkCancellation()
        } catch {
            // 不删除已开始播放的列表，也不删除旧的正在播放列表。
            cleanUp()
            throw error
        }
    }

    private func build(_ ids: [String], in source: MusicLibrarySource,
                       checkCancellation: () throws -> Void) throws -> MusicPlaybackContextOwnership {
        let token = UUID()
        let playlistID = try executor.create(token: token, checkCancellation: checkCancellation)
        guard SongBinding.isValidPersistentID(playlistID) else { throw MusicPlaybackContextError(stage: .create) }
        var ownership = MusicPlaybackContextOwnership(playlistID: playlistID, token: token, trackIDs: [], usesUniqueName: true)
        owned.append(ownership)
        save()
        for offset in stride(from: 0, to: ids.count, by: Self.copyBatchSize) {
            try checkCancellation()
            let batch = Array(ids[offset..<min(offset + Self.copyBatchSize, ids.count)])
            let confirmedIDs = try executor.append(batch, to: ownership, from: source, checkCancellation: checkCancellation)
            guard confirmedIDs == ownership.trackIDs + batch else { throw MusicLibraryError.contentsChanged }
            ownership.trackIDs = confirmedIDs
            owned[owned.count - 1] = ownership
            save()
        }
        return ownership
    }

    private func markPlaybackRequested(_ ownership: MusicPlaybackContextOwnership) {
        guard let index = owned.firstIndex(where: { $0.playlistID == ownership.playlistID }) else { return }
        owned[index].playbackRequested = true
        save()
    }

    private func finishConfirmedPlayback(excluding source: MusicLibrarySource? = nil) {
        // 新上下文已真实确认，旧的未确认请求才能释放清理保护。
        for index in owned.indices { owned[index].playbackRequested = false }
        save()
        cleanUp(excluding: source)
    }

    private func cleanUp(excluding source: MusicLibrarySource? = nil) {
        owned.removeAll { ownership in
            if ownership.playbackRequested == true { return false }
            if source == .playlist(id: ownership.playlistID) { return false }
            // 删除失败保留本机记录，下次主动播放时重试；不会静默扩大到用户歌单。
            return (try? executor.remove(ownership)) == true
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(owned) { defaults.set(data, forKey: Self.storageKey) }
    }
}

struct AppleScriptMusicPlaybackContextExecutor: MusicPlaybackContextExecuting {
    /// Music 异步切换的有界确认策略；每次等待都释放 OSA 锁，未确认的已发请求不会被清理。
    private static let confirmationTimeoutNanos: UInt64 = 5_000_000_000
    private static let confirmationPollInterval: TimeInterval = 0.08
    func create(token: UUID, checkCancellation: () throws -> Void) throws -> String {
        let result = try execute(MusicPlaybackContextScripts.create(token: token), stage: .create,
                                 checkCancellation: checkCancellation)
        guard let id = result.stringValue, SongBinding.isValidPersistentID(id) else {
            throw MusicPlaybackContextError(stage: .create)
        }
        return id
    }

    func append(_ ids: [String], to ownership: MusicPlaybackContextOwnership, from source: MusicLibrarySource,
                checkCancellation: () throws -> Void) throws -> [String] {
        let result = try execute(MusicPlaybackContextScripts.append(ids, to: ownership, from: source), stage: .append,
                                 checkCancellation: checkCancellation)
        return try MusicLibraryDescriptorParser.list(result).map { descriptor in
            guard let id = descriptor.stringValue, SongBinding.isValidPersistentID(id) else {
                throw MusicPlaybackContextError(stage: .readback)
            }
            return id
        }
    }

    func start(_ ownership: MusicPlaybackContextOwnership, at persistentID: String, shuffleEnabled: Bool?,
               checkCancellation: () throws -> Void) throws {
        let result = try execute(
            MusicPlaybackContextScripts.start(ownership, at: persistentID, shuffleEnabled: shuffleEnabled),
            stage: .start, checkCancellation: checkCancellation)
        guard result.numberOfItems == 2, result.atIndex(1)?.stringValue == "ok" else {
            throw MusicPlaybackContextError(stage: .start)
        }
        let previousShuffle: Bool?
        switch result.atIndex(2)?.stringValue {
        case "true": previousShuffle = true
        case "false": previousShuffle = false
        default: previousShuffle = nil
        }
        let desiredShuffle = shuffleEnabled ?? previousShuffle
        try confirm(ownership, selectedID: persistentID, shuffleEnabled: nil, checkCancellation: checkCancellation)
        if let desiredShuffle {
            _ = try execute(MusicPlaybackContextScripts.setShuffle(ownership, enabled: desiredShuffle), stage: .shuffle,
                            checkCancellation: checkCancellation)
        }
        try confirm(ownership, selectedID: persistentID, shuffleEnabled: desiredShuffle, checkCancellation: checkCancellation)
    }

    func shuffleSource(_ ids: [String], in source: MusicLibrarySource,
                       checkCancellation: () throws -> Void) throws -> Bool {
        try startRandom(MusicPlaybackContextScripts.shuffleSource(source, expectedIDs: ids),
                        expectedIDs: ids, ownership: nil, checkCancellation: checkCancellation)
    }

    func shuffleManaged(_ ownership: MusicPlaybackContextOwnership, checkCancellation: () throws -> Void) throws -> Bool {
        try startRandom(MusicPlaybackContextScripts.shuffleManaged(ownership), expectedIDs: ownership.trackIDs,
                        ownership: ownership, checkCancellation: checkCancellation)
    }

    private func startRandom(_ source: String, expectedIDs: [String],
                             ownership: MusicPlaybackContextOwnership?, checkCancellation: () throws -> Void) throws -> Bool {
        let result: NSAppleEventDescriptor
        do {
            result = try execute(source, stage: .start, checkCancellation: checkCancellation)
        } catch let failure as MusicPlaybackContextError where failure.stage == .select && failure.appleEventCode == -1728 {
            return false // play 尚未发送；找不到或被用户改动的候选，回到建立隔离上下文的路径。
        }
        if result.stringValue == "different" { return false }
        guard result.numberOfItems == 3, result.atIndex(1)?.stringValue == "ok",
              let prepared = result.atIndex(2).flatMap(MusicLibraryDescriptorParser.boolean),
              let playlistID = result.atIndex(3)?.stringValue, SongBinding.isValidPersistentID(playlistID),
              ownership.map({ $0.playlistID == playlistID }) ?? true else { throw MusicPlaybackContextError(stage: .start) }
        let confirmation = try ownership.map {
            try MusicPlaybackContextScripts.confirm($0, selectedID: nil, shuffleEnabled: true)
        } ?? MusicPlaybackContextScripts.confirm(playlistID: playlistID, expectedIDs: expectedIDs,
                                               selectedID: nil, shuffleEnabled: true)
        let resetShuffle = try ownership.map { try MusicPlaybackContextScripts.setShuffle($0, enabled: true) }
            ?? MusicPlaybackContextScripts.setSourceShuffle(playlistID, expectedIDs: expectedIDs)
        try confirm(confirmation, resetShuffle: resetShuffle, checkCancellation: checkCancellation)
        if !prepared {
            let replay = try execute(
                MusicPlaybackContextScripts.replayShuffle(playlistID, expectedIDs: expectedIDs, ownership: ownership),
                stage: .start, checkCancellation: checkCancellation)
            guard replay.stringValue == "ok" else { throw MusicPlaybackContextError(stage: .start) }
            try confirm(confirmation, resetShuffle: resetShuffle, checkCancellation: checkCancellation)
        }
        return true
    }

    private func confirm(_ ownership: MusicPlaybackContextOwnership, selectedID: String?, shuffleEnabled: Bool?,
                         checkCancellation: () throws -> Void) throws {
        let source = try MusicPlaybackContextScripts.confirm(ownership, selectedID: selectedID, shuffleEnabled: shuffleEnabled)
        let resetShuffle = try shuffleEnabled.map { try MusicPlaybackContextScripts.setShuffle(ownership, enabled: $0) }
        try confirm(source, resetShuffle: resetShuffle, checkCancellation: checkCancellation)
    }

    private func confirm(_ source: String, resetShuffle: String?, checkCancellation: () throws -> Void) throws {
        // Music 在 play 返回后异步建立上下文。每次读回释放 OSA 锁，专用命令队列短等，UI与采样可继续。
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.confirmationTimeoutNanos
        var pendingStage = MusicPlaybackContextError.Stage.currentPlaylist
        repeat {
            try checkCancellation()
            let result = try execute(source, stage: .currentPlaylist, checkCancellation: checkCancellation)
            if result.stringValue == "ok" { return }
            switch result.stringValue {
            case "pending": pendingStage = .currentPlaylist
            case "pending-track": pendingStage = .select
            case "pending-shuffle":
                pendingStage = .shuffle
                // Music 初始化新队列时可能回写旧随机状态；只在身份和完整成员已确认后幂等重设。
                if let resetShuffle {
                    _ = try execute(resetShuffle, stage: .shuffle, checkCancellation: checkCancellation)
                }
            default: throw MusicPlaybackContextError(stage: .readback)
            }
            Thread.sleep(forTimeInterval: Self.confirmationPollInterval)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        throw MusicPlaybackContextError(stage: pendingStage, appleEventCode: -1712)
    }

    func remove(_ ownership: MusicPlaybackContextOwnership) throws -> Bool {
        let result = try execute(MusicPlaybackContextScripts.remove(ownership), stage: .cleanup)
        switch result.stringValue {
        case "removed", "released": return true
        case "playing": return false
        default: throw MusicLibraryError.contentsChanged
        }
    }

    private func execute(_ source: String, stage: MusicPlaybackContextError.Stage,
                         checkCancellation: () throws -> Void = {}) throws -> NSAppleEventDescriptor {
        let result = try MusicLibraryScriptExecution.execute(source, checkCancellation: checkCancellation)
        if result.numberOfItems == 3, result.atIndex(1)?.stringValue == "context-error" {
            let failedStage = result.atIndex(2)?.stringValue.flatMap(MusicPlaybackContextError.Stage.init(rawValue:)) ?? stage
            throw MusicPlaybackContextError(stage: failedStage, appleEventCode: result.atIndex(3).map { Int($0.int32Value) })
        }
        return result
    }
}
