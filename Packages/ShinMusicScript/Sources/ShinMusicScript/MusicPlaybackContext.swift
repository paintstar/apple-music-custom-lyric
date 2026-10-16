import Foundation
import ShinAppleKit

/// 仅记录本 App 创建的歌单。随机标记和成员共同防止认领同名或被用户改动的歌单。
struct MusicPlaybackContextOwnership: Codable, Equatable, Sendable {
    var playlistID: String
    var token: UUID
    var trackIDs: [String]
    /// play 已发送但尚未确认时保留，包含取消/超时；退出清理前必须先确认停止。
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
    /// false 只表示 play 尚未发送且完整顺序或所有权已失效。
    func reuse(_ ownership: MusicPlaybackContextOwnership, at persistentID: String, shuffleEnabled: Bool?,
               checkCancellation: () throws -> Void) throws -> Bool
    /// 所选曲为完整来源首曲时整单起播；false 表示 play 尚未发送，可以建立隔离列表。
    func playSource(_ ids: [String], at persistentID: String, in source: MusicLibrarySource, shuffleEnabled: Bool?,
                    checkCancellation: () throws -> Void) throws -> Bool
    /// false 只表示发送 play 前已确认不是完整原歌单或可复用的管理歌单。
    func shuffleSource(_ ids: [String], in source: MusicLibrarySource, checkCancellation: () throws -> Void) throws -> Bool
    func shuffleManaged(_ ownership: MusicPlaybackContextOwnership, checkCancellation: () throws -> Void) throws -> Bool
    /// 返回 true 表示已删除、已不存在或用户改动后已释放所有权；false 表示仍在播放，保留以便后续清理。
    func remove(_ ownership: MusicPlaybackContextOwnership) throws -> Bool
    func stopForCleanup(checkCancellation: () throws -> Void) throws -> Bool
    func remove(_ ownership: MusicPlaybackContextOwnership, allowStoppedCurrent: Bool,
                checkCancellation: () throws -> Void) throws -> Bool
}

/// 只在控制器的播放命令串行队列访问；重启后的清理也必须重新验证所有权及成员。
final class MusicPlaybackContext {
    private let executor: any MusicPlaybackContextExecuting
    private let defaults: UserDefaults
    private var owned: [MusicPlaybackContextOwnership]
    private static let storageKey = "ShinApple.musicPlaybackContexts"
    /// 连续区间整批复制，限制单次脚本工作量；常见歌单可用两段区间完成旋转。
    private static let copyBatchSize = 256
    /// 当前与最近一个已确认上下文可复用；每次成功在短预算内最多处理两个更旧清单。
    private static let retainedContextCount = 2
    /// 清理只做少量尝试，批次之间检查时间，不把历史积累带入切歌关键路径。
    private static let reclamationBudgetNanos: UInt64 = 500_000_000
    private static let reclamationAttempts = 2

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
            finishConfirmedPlayback(keeping: source, checkCancellation: checkCancellation)
            try checkCancellation()
            return
        }
        for index in owned.indices.reversed() where owned[index].playbackRequested != true
            && owned[index].trackIDs.count == ids.count && Set(owned[index].trackIDs) == Set(ids) {
            owned[index].playbackRequested = true
            save()
            if try executor.shuffleManaged(owned[index], checkCancellation: checkCancellation) {
                finishConfirmedPlayback(keeping: .playlist(id: owned[index].playlistID), checkCancellation: checkCancellation)
                try checkCancellation()
                return
            }
            // 校验在发送 play 前失败，释放本次保护；用户修改的歌单仍由精确清理规则保留。
            owned[index].playbackRequested = false
            save()
        }
        try checkCancellation()
        let ownership = try build(ids, in: source, checkCancellation: checkCancellation)
        try checkCancellation()
        markPlaybackRequested(ownership)
        guard try executor.shuffleManaged(ownership, checkCancellation: checkCancellation) else {
            throw MusicPlaybackContextError(stage: .readback)
        }
        finishConfirmedPlayback(keeping: .playlist(id: ownership.playlistID), checkCancellation: checkCancellation)
        try checkCancellation()
    }

    func play(_ ids: [String], startingAt id: String, in source: MusicLibrarySource,
              shuffleEnabled: Bool?, checkCancellation: () throws -> Void) throws {
        guard !ids.isEmpty, Set(ids).count == ids.count, ids.contains(id),
              ids.allSatisfy(SongBinding.isValidPersistentID) else { throw MusicLibraryError.invalidRequest }
        if case let .playlist(id: playlistID) = source,
           !SongBinding.isValidPersistentID(playlistID) { throw MusicLibraryError.invalidRequest }
        try checkCancellation()
        let offset = ids.firstIndex(of: id)!
        let playbackIDs = Array(ids[offset...]) + ids[..<offset]
        let isOwnedSource = owned.contains { source == .playlist(id: $0.playlistID) }
        if !isOwnedSource,
           try executor.playSource(playbackIDs, at: id, in: source, shuffleEnabled: shuffleEnabled,
                                   checkCancellation: checkCancellation) {
            finishConfirmedPlayback(keeping: source, checkCancellation: checkCancellation)
            try checkCancellation()
            return
        }
        // 所选曲成为完整列表起点，整单播放才能保留 Music 的真实连续播放范围。
        for index in owned.indices.reversed() where owned[index].playbackRequested != true && owned[index].trackIDs == playbackIDs {
            owned[index].playbackRequested = true
            save()
            if try executor.reuse(owned[index], at: id, shuffleEnabled: shuffleEnabled, checkCancellation: checkCancellation) {
                finishConfirmedPlayback(keeping: .playlist(id: owned[index].playlistID), checkCancellation: checkCancellation)
                try checkCancellation()
                return
            }
            // 只有 play 前明确校验失效才允许新建，已发请求失败仍由 pending 记录保护。
            owned[index].playbackRequested = false
            save()
        }
        try checkCancellation()
        let ownership = try build(playbackIDs, in: source, checkCancellation: checkCancellation)
        try checkCancellation()
        // Music 的 shuffle 属性在无曲目时可能不可用，先建立新歌单的实际播放上下文。
        markPlaybackRequested(ownership)
        try executor.start(ownership, at: id, shuffleEnabled: shuffleEnabled, checkCancellation: checkCancellation)
        finishConfirmedPlayback(keeping: .playlist(id: ownership.playlistID), checkCancellation: checkCancellation)
        try checkCancellation()
    }

    /// 退出前停止并读回成功，才能解除待确认 play 的保护；每项删除独立重验和保存。
    func cleanupOnQuit(checkCancellation: () throws -> Void) throws {
        try checkCancellation()
        guard !owned.isEmpty else { return }
        guard try executor.stopForCleanup(checkCancellation: checkCancellation) else {
            throw MusicPlaybackContextError(stage: .cleanup)
        }
        try checkCancellation()
        for index in owned.indices { owned[index].playbackRequested = false }
        save()
        var firstError: (any Error)?
        for ownership in owned {
            try checkCancellation()
            do {
                guard try executor.remove(ownership, allowStoppedCurrent: true, checkCancellation: checkCancellation) else {
                    throw MusicPlaybackContextError(stage: .cleanup)
                }
                owned.removeAll { $0.playlistID == ownership.playlistID && $0.token == ownership.token }
                save()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private func build(_ ids: [String], in source: MusicLibrarySource,
                       checkCancellation: () throws -> Void) throws -> MusicPlaybackContextOwnership {
        let token = UUID()
        let playlistID = try executor.create(token: token, checkCancellation: checkCancellation)
        guard SongBinding.isValidPersistentID(playlistID) else { throw MusicPlaybackContextError(stage: .create) }
        var ownership = MusicPlaybackContextOwnership(playlistID: playlistID, token: token, trackIDs: [], usesUniqueName: true)
        owned.append(ownership)
        save()
        while ownership.trackIDs.count < ids.count {
            try checkCancellation()
            let offset = ownership.trackIDs.count
            let batch = Array(ids[offset..<min(offset + Self.copyBatchSize, ids.count)])
            let confirmedIDs = try executor.append(batch, to: ownership, from: source, checkCancellation: checkCancellation)
            guard confirmedIDs.count > offset, confirmedIDs.count <= offset + batch.count,
                  confirmedIDs == Array(ids.prefix(confirmedIDs.count)) else { throw MusicLibraryError.contentsChanged }
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

    private func finishConfirmedPlayback(keeping source: MusicLibrarySource, checkCancellation: () throws -> Void) {
        // 新上下文已真实确认，旧的未确认请求才能释放清理保护。
        if case let .playlist(id) = source, let index = owned.firstIndex(where: { $0.playlistID == id }) {
            owned.append(owned.remove(at: index))
        }
        for index in owned.indices { owned[index].playbackRequested = false }
        save()
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.reclamationBudgetNanos
        var attempted = Set<UUID>()
        for _ in 0..<Self.reclamationAttempts {
            guard owned.count > Self.retainedContextCount, DispatchTime.now().uptimeNanoseconds < deadline,
                  let index = owned.firstIndex(where: {
                      source != .playlist(id: $0.playlistID) && !attempted.contains($0.token)
                  }) else { break }
            let obsolete = owned[index]
            attempted.insert(obsolete.token)
            // 执行器仍检查非当前、名称、标记和完整成员；失败轮到队尾，避免饿死其他旧清单。
            do {
                if try executor.remove(obsolete, allowStoppedCurrent: false, checkCancellation: checkCancellation) {
                    owned.remove(at: index)
                } else {
                    owned.append(owned.remove(at: index))
                }
            } catch is CancellationError {
                break
            } catch {
                owned.append(owned.remove(at: index))
            }
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(owned) { defaults.set(data, forKey: Self.storageKey) }
    }
}

struct AppleScriptMusicPlaybackContextExecutor: MusicPlaybackContextExecuting {
    typealias ScriptExecution = @Sendable (String, () throws -> Void) throws -> NSAppleEventDescriptor
    private let scriptExecution: ScriptExecution
    /// Music 异步切换的有界确认策略；每次等待都释放 OSA 锁，未确认的已发请求不会被清理。
    private static let confirmationTimeoutNanos: UInt64 = 5_000_000_000
    private static let confirmationPollInterval: TimeInterval = 0.08
    /// 退出总预算为 10 秒；停止确认只短等，给后续严格删除与取消留下时间。
    private static let cleanupStopTimeoutNanos: UInt64 = 2_000_000_000

    init(scriptExecution: @escaping ScriptExecution = { source, cancellation in
        try MusicLibraryScriptExecution.execute(source, checkCancellation: cancellation)
    }) {
        self.scriptExecution = scriptExecution
    }

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
        try finishStart(result, ownership: ownership, persistentID: persistentID,
                        shuffleEnabled: shuffleEnabled, checkCancellation: checkCancellation)
    }

    func reuse(_ ownership: MusicPlaybackContextOwnership, at persistentID: String, shuffleEnabled: Bool?,
               checkCancellation: () throws -> Void) throws -> Bool {
        let result = try execute(
            MusicPlaybackContextScripts.start(ownership, at: persistentID, shuffleEnabled: shuffleEnabled, reuse: true),
            stage: .start, checkCancellation: checkCancellation)
        if result.stringValue == "different" { return false }
        try finishStart(result, ownership: ownership, persistentID: persistentID,
                        shuffleEnabled: shuffleEnabled, checkCancellation: checkCancellation)
        return true
    }

    private func finishStart(_ result: NSAppleEventDescriptor, ownership: MusicPlaybackContextOwnership,
                             persistentID: String, shuffleEnabled: Bool?, checkCancellation: () throws -> Void) throws {
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
        try preservingShuffle(previousShuffle) {
            try confirm(ownership, selectedID: persistentID, shuffleEnabled: nil,
                        orderedMembers: true, checkCancellation: checkCancellation)
            if let desiredShuffle {
                _ = try execute(MusicPlaybackContextScripts.setShuffle(ownership, enabled: desiredShuffle), stage: .shuffle,
                                checkCancellation: checkCancellation)
            }
            try confirm(ownership, selectedID: persistentID, shuffleEnabled: desiredShuffle,
                        orderedMembers: true, checkCancellation: checkCancellation)
        }
    }

    func playSource(_ ids: [String], at persistentID: String, in source: MusicLibrarySource, shuffleEnabled: Bool?,
                    checkCancellation: () throws -> Void) throws -> Bool {
        let result: NSAppleEventDescriptor
        do {
            result = try execute(MusicPlaybackContextScripts.playSource(source, expectedIDs: ids, at: persistentID),
                                 stage: .start, checkCancellation: checkCancellation)
        } catch let failure as MusicPlaybackContextError where failure.stage == .select && failure.appleEventCode == -1728 {
            return false // 目标已不存在，play 尚未发送。
        }
        if result.stringValue == "different" { return false }
        guard result.numberOfItems == 3, result.atIndex(1)?.stringValue == "ok",
              let playlistID = result.atIndex(3)?.stringValue, SongBinding.isValidPersistentID(playlistID) else {
            throw MusicPlaybackContextError(stage: .start)
        }
        let previousShuffle: Bool?
        switch result.atIndex(2)?.stringValue {
        case "true": previousShuffle = true
        case "false": previousShuffle = false
        default: previousShuffle = nil
        }
        let desiredShuffle = shuffleEnabled ?? previousShuffle
        try preservingShuffle(previousShuffle) {
            let initial = try MusicPlaybackContextScripts.confirm(playlistID: playlistID, expectedIDs: ids,
                                                                  selectedID: persistentID, shuffleEnabled: nil, orderedMembers: true)
            try confirm(initial, resetShuffle: nil, checkCancellation: checkCancellation)
            let resetShuffle = try desiredShuffle.map {
                try MusicPlaybackContextScripts.setSourceShuffle(playlistID, expectedIDs: ids, enabled: $0, orderedMembers: true)
            }
            if let resetShuffle { _ = try execute(resetShuffle, stage: .shuffle, checkCancellation: checkCancellation) }
            let confirmation = try MusicPlaybackContextScripts.confirm(playlistID: playlistID, expectedIDs: ids,
                                                                       selectedID: persistentID, shuffleEnabled: desiredShuffle,
                                                                       orderedMembers: true)
            try confirm(confirmation, resetShuffle: resetShuffle, checkCancellation: checkCancellation)
        }
        return true
    }

    private func preservingShuffle(_ previous: Bool?, operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            // 即便请求已取消，也先在串行命令队列恢复已知偏好；不得覆盖原来的失败原因。
            if let previous {
                let compensation = MusicAppleScriptExecution.gate.reservePlayback()
                defer { compensation.release() }
                _ = try? MusicAppleScriptExecution.gate.withPlaybackPriority(compensation) {
                    try execute(MusicPlaybackContextScripts.restoreShuffle(previous), stage: .shuffle)
                }
            }
            throw error
        }
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
                         orderedMembers: Bool = false, checkCancellation: () throws -> Void) throws {
        let source = try MusicPlaybackContextScripts.confirm(ownership, selectedID: selectedID,
                                                             shuffleEnabled: shuffleEnabled, orderedMembers: orderedMembers)
        let resetShuffle = try shuffleEnabled.map { try MusicPlaybackContextScripts.setShuffle(ownership, enabled: $0) }
        try confirm(source, resetShuffle: resetShuffle, checkCancellation: checkCancellation)
    }

    private func confirm(_ source: String, resetShuffle: String?, checkCancellation: () throws -> Void) throws {
        // Music 在 play 返回后异步建立上下文。每次读回释放 OSA 锁，专用命令队列短等，UI与采样可继续。
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.confirmationTimeoutNanos
        var pendingStage = MusicPlaybackContextError.Stage.currentPlaylist
        repeat {
            try checkCancellation()
            do {
                let result = try execute(source, stage: .currentPlaylist, checkCancellation: checkCancellation)
                if result.stringValue == "ok" { return }
                switch result.stringValue {
                case "pending": pendingStage = .currentPlaylist
                case "pending-track": pendingStage = .select
                case "pending-playback": pendingStage = .start
                case "pending-shuffle":
                    pendingStage = .shuffle
                    // Music 初始化新队列时可能回写旧随机状态；只在身份和完整成员已确认后幂等重设。
                    if let resetShuffle {
                        _ = try execute(resetShuffle, stage: .shuffle, checkCancellation: checkCancellation)
                    }
                default: throw MusicPlaybackContextError(stage: .readback)
                }
            } catch let failure as MusicPlaybackContextError where failure.appleEventCode == -1728
                && [.currentPlaylist, .readback, .shuffle].contains(failure.stage) {
                // play 已返回后，旧快照消失和新上下文就绪之间可能短暂无可读对象；仍须完整读回才能成功。
                pendingStage = failure.stage
            }
            Thread.sleep(forTimeInterval: Self.confirmationPollInterval)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        throw MusicPlaybackContextError(stage: pendingStage, appleEventCode: -1712)
    }

    func remove(_ ownership: MusicPlaybackContextOwnership) throws -> Bool {
        try remove(ownership, allowStoppedCurrent: false) {}
    }

    func stopForCleanup(checkCancellation: () throws -> Void) throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.cleanupStopTimeoutNanos
        var result = try execute(MusicPlaybackContextScripts.stopForCleanup, stage: .cleanup,
                                 checkCancellation: checkCancellation)
        while true {
            if result.stringValue == "stopped" { return true }
            guard result.stringValue == "pending" else { throw MusicPlaybackContextError(stage: .cleanup) }
            try checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            Thread.sleep(forTimeInterval: Self.confirmationPollInterval)
            result = try execute(MusicPlaybackContextScripts.confirmStoppedForCleanup, stage: .cleanup,
                                 checkCancellation: checkCancellation)
        }
    }

    func remove(_ ownership: MusicPlaybackContextOwnership, allowStoppedCurrent: Bool,
                checkCancellation: () throws -> Void) throws -> Bool {
        let result = try execute(MusicPlaybackContextScripts.remove(ownership, allowStoppedCurrent: allowStoppedCurrent),
                                 stage: .cleanup, checkCancellation: checkCancellation)
        switch result.stringValue {
        case "removed", "released": return true
        case "playing": return false
        default: throw MusicLibraryError.contentsChanged
        }
    }

    private func execute(_ source: String, stage: MusicPlaybackContextError.Stage,
                         checkCancellation: () throws -> Void = {}) throws -> NSAppleEventDescriptor {
        try checkCancellation()
        let result = try scriptExecution(source, checkCancellation)
        if result.numberOfItems == 3, result.atIndex(1)?.stringValue == "context-error" {
            let failedStage = result.atIndex(2)?.stringValue.flatMap(MusicPlaybackContextError.Stage.init(rawValue:)) ?? stage
            throw MusicPlaybackContextError(stage: failedStage, appleEventCode: result.atIndex(3).map { Int($0.int32Value) })
        }
        return result
    }
}
