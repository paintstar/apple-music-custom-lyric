import CoreServices
import Foundation
import ShinAppleKit

protocol MusicLibraryScriptReading: Sendable {
    func readPlaylists(cancellation: MusicLibraryCancellation) throws -> [MusicLibraryPlaylist]
    func readTracks(in source: MusicLibrarySource, cancellation: MusicLibraryCancellation) throws -> [MusicLibraryTrack]
    func currentPlaybackSource(cancellation: MusicLibraryCancellation) throws -> MusicLibrarySource?
    func artworkData(persistentID: String, cancellation: MusicLibraryCancellation) throws -> Data?
    func setFavorite(persistentID: String, value: Bool, cancellation: MusicLibraryCancellation) throws -> Bool
}

extension MusicLibraryScriptReading {
    func currentPlaybackSource(cancellation: MusicLibraryCancellation) throws -> MusicLibrarySource? { nil }
    func artworkData(persistentID: String, cancellation: MusicLibraryCancellation) throws -> Data? { nil }
    func setFavorite(persistentID: String, value: Bool, cancellation: MusicLibraryCancellation) throws -> Bool {
        throw MusicLibraryError.unsupported
    }
}

/// 调用由 MusicLibraryCache 的专用串行队列承接，绝不占播放采样的 executorLock。
/// 按整列取值是为了规避 Music 在 fixed indexing=false 时范围索引的空洞与次序偏差。
/// 每列一个公开查询，字段间可取消，前后 ID 序列和每列长度不一致则拒绝整批。
struct AppleScriptMusicLibraryReader: MusicLibraryScriptReading {
    func currentPlaybackSource(cancellation: MusicLibraryCancellation) throws -> MusicLibrarySource? {
        try cancellation.check()
        let result = try MusicLibraryScriptExecution.execute(MusicLibraryScriptSources.currentPlaybackSource,
                                                            cancellation: cancellation)
        try cancellation.check()
        return try MusicLibraryDescriptorParser.playbackSource(result)
    }

    func artworkData(persistentID: String, cancellation: MusicLibraryCancellation) throws -> Data? {
        try cancellation.check()
        let source = try MusicLibraryScriptSources.artwork(persistentID: persistentID)
        let result = try MusicLibraryScriptExecution.execute(source, cancellation: cancellation)
        try cancellation.check()
        // sdef artwork.raw data 返回 tdta，按图像字节解码；缺失值不伪造图像。
        guard result.descriptorType == typeData else { return nil }
        let data = result.data
        // 控制单项内存成本；超大的原始图像保持占位，不影响点播与歌词。
        guard !data.isEmpty, data.count <= 8 * 1_024 * 1_024 else { return nil }
        return data
    }

    func setFavorite(persistentID: String, value: Bool, cancellation: MusicLibraryCancellation) throws -> Bool {
        try cancellation.check()
        let source = try MusicLibraryScriptSources.favorite(persistentID: persistentID, value: value)
        let result = try MusicLibraryScriptExecution.execute(source, cancellation: cancellation)
        guard let confirmed = MusicLibraryDescriptorParser.boolean(result) else {
            throw MusicScriptFailure.fieldUnavailable("library:favorite")
        }
        return confirmed
    }

    func readTracks(in source: MusicLibrarySource, cancellation: MusicLibraryCancellation) throws -> [MusicLibraryTrack] {
        var columns: [MusicLibraryScriptSources.TrackColumn: [NSAppleEventDescriptor]] = [:]
        for column in MusicLibraryScriptSources.TrackColumn.allCases {
            try cancellation.check()
            let script = try MusicLibraryScriptSources.trackColumn(column, in: source)
            let result = try MusicLibraryScriptExecution.execute(script, cancellation: cancellation)
            columns[column] = try MusicLibraryDescriptorParser.list(result)
        }
        try cancellation.check()
        let script = try MusicLibraryScriptSources.trackColumn(.persistentID, in: source)
        let recheck = try MusicLibraryScriptExecution.execute(script, cancellation: cancellation)
        return try MusicLibraryDescriptorParser.tracks(columns: columns, finalIDs: MusicLibraryDescriptorParser.list(recheck))
    }

    func readPlaylists(cancellation: MusicLibraryCancellation) throws -> [MusicLibraryPlaylist] {
        var columns: [[NSAppleEventDescriptor]] = []
        for column: MusicLibraryScriptSources.PlaylistColumn in [.persistentID, .name, .kind, .smart] {
            try cancellation.check()
            let script = MusicLibraryScriptSources.playlistColumn(column)
            let result = try MusicLibraryScriptExecution.execute(script, cancellation: cancellation)
            columns.append(try MusicLibraryDescriptorParser.list(result))
        }
        let count = columns[0].count
        guard columns.allSatisfy({ $0.count == count }) else { throw MusicLibraryError.contentsChanged }
        var playlists: [MusicLibraryPlaylist] = []
        for index in 0..<count {
            try cancellation.check()
            guard let id = MusicLibraryDescriptorParser.text(columns[0][index]),
                  SongBinding.isValidPersistentID(id) else { throw MusicLibraryError.contentsChanged }
            // 根歌单没有 parent 时 Music 抛 -1728，而不是返回空列表；按公开的缺失语义处理。
            let script = try MusicLibraryScriptSources.playlistParent(id)
            let parent = try MusicLibraryScriptExecution.execute(script, cancellation: cancellation)
            let parentID = MusicLibraryDescriptorParser.text(parent)
            playlists.append(MusicLibraryPlaylist(
                id: id, name: MusicLibraryDescriptorParser.text(columns[1][index]) ?? "",
                isFolder: columns[2][index].enumCodeValue == 0x6B53_7046, // sdef eSpK.folder ('kSpF')
                parentID: parentID.flatMap { SongBinding.isValidPersistentID($0) ? $0 : nil },
                isSmart: MusicLibraryDescriptorParser.boolean(columns[3][index]) ?? false
            ))
        }
        try cancellation.check()
        let script = MusicLibraryScriptSources.playlistColumn(.persistentID)
        let final = try MusicLibraryScriptExecution.execute(script, cancellation: cancellation)
        let finalIDs = try MusicLibraryDescriptorParser.list(final).map(MusicLibraryDescriptorParser.text)
        guard finalIDs == columns[0].map(MusicLibraryDescriptorParser.text) else { throw MusicLibraryError.contentsChanged }
        return playlists
    }
}

enum MusicLibraryDescriptorParser {
    static func playbackSource(_ descriptor: NSAppleEventDescriptor) throws -> MusicLibrarySource? {
        // AppleScript missing value 为 type('msng')；null 同样表示来源未知。
        if descriptor.descriptorType == typeNull
            || (descriptor.descriptorType == typeType && descriptor.typeCodeValue == 0x6D73_6E67) {
            return nil
        }
        let items = try list(descriptor)
        guard let marker = items.first.flatMap(text) else {
            throw MusicScriptFailure.fieldUnavailable("library:playbackSource")
        }
        if marker == "library", items.count == 1 { return .library }
        if marker == "playlist", items.count == 2,
           let id = text(items[1]), SongBinding.isValidPersistentID(id) {
            return .playlist(id: id)
        }
        throw MusicScriptFailure.fieldUnavailable("library:playbackSource")
    }

    static func list(_ descriptor: NSAppleEventDescriptor) throws -> [NSAppleEventDescriptor] {
        guard descriptor.descriptorType == typeAEList else { throw MusicScriptFailure.fieldUnavailable("library:list") }
        return (0..<descriptor.numberOfItems).compactMap { descriptor.atIndex($0 + 1) }
    }

    static func text(_ descriptor: NSAppleEventDescriptor) -> String? {
        switch descriptor.descriptorType {
        case typeUnicodeText, typeUTF8Text, typeChar:
            return descriptor.stringValue
        default:
            return nil
        }
    }

    static func boolean(_ descriptor: NSAppleEventDescriptor) -> Bool? {
        switch descriptor.descriptorType {
        case typeBoolean, typeTrue, typeFalse: return descriptor.booleanValue
        default: return nil
        }
    }

    static func tracks(
        columns: [MusicLibraryScriptSources.TrackColumn: [NSAppleEventDescriptor]],
        finalIDs: [NSAppleEventDescriptor]
    ) throws -> [MusicLibraryTrack] {
        guard let firstIDs = columns[.persistentID],
              MusicLibraryScriptSources.TrackColumn.allCases.allSatisfy({ columns[$0]?.count == firstIDs.count }),
              firstIDs.map(text) == finalIDs.map(text) else { throw MusicLibraryError.contentsChanged }
        return try firstIDs.indices.map { index in
            guard let id = text(firstIDs[index]), SongBinding.isValidPersistentID(id) else {
                throw MusicLibraryError.contentsChanged
            }
            let duration = columns[.duration]?[index]
            let seconds = duration.flatMap { value -> Double? in
                guard [typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint, typeSInt32, typeSInt64]
                    .contains(value.descriptorType) else { return nil }
                return value.doubleValue
            }
            return MusicLibraryTrack(
                persistentID: id, title: columns[.title].flatMap { text($0[index]) } ?? "",
                artist: columns[.artist].flatMap { text($0[index]) },
                albumArtist: columns[.albumArtist].flatMap { text($0[index]) }, album: columns[.album].flatMap { text($0[index]) },
                durationMs: seconds.flatMap(MusicScriptMapping.secondsToMs),
                isFavorite: columns[.favorite].flatMap { boolean($0[index]) },
                dateAdded: columns[.dateAdded].flatMap { $0[index].descriptorType == typeLongDateTime ? $0[index].dateValue : nil }
            )
        }
    }
}
