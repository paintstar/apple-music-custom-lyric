// 连续区间按公开词典批量复制，无法精确核验的区间退回逐项引用。
extension MusicPlaybackContextScripts {
    /// 连续区间算一次；回退逐项复制时仍在少量操作后交还取消与采样机会。
    private static let maxCopyOperations = 24

    /// Music 对空歌单读取整列 ID 会抛 -1728，首批只能先确认确实为空。
    static func orderedMembersCheck(_ ids: [String], mismatch: String) throws -> String {
        let expected = try list(ids)
        if ids.isEmpty { return "if (count of tracks of targetPlaylist) is not 0 then \(mismatch)" }
        return """
        set actualMemberCount to count of tracks of targetPlaylist
        if actualMemberCount is 0 then \(mismatch)
        set actualIDs to get persistent ID of every track of targetPlaylist
        if actualIDs is not \(expected) then \(mismatch)
        """
    }

    /// sourceIDs 只用于寻找候选区间；真正复制前重新核对 numeric range，避免索引/播放顺序差异。
    static var copySelectedReferences: String {
        """
        set selectedOffset to 1
        set copyOperations to 0
        repeat while selectedOffset ≤ (count of selectedIDs) and copyOperations < \(maxCopyOperations)
            set contextStage to "select"
            set selectedID to item selectedOffset of selectedIDs
            set sourceStart to 0
            repeat with sourceIndex from 1 to (count of sourceIDs)
                if item sourceIndex of sourceIDs is selectedID then
                    set sourceStart to sourceIndex
                    exit repeat
                end if
            end repeat
            if sourceStart is 0 then error number -1728
            set runLength to 1
            repeat while (sourceStart + runLength) ≤ (count of sourceIDs) and (selectedOffset + runLength) ≤ (count of selectedIDs)
                if item (sourceStart + runLength) of sourceIDs is not item (selectedOffset + runLength) of selectedIDs then exit repeat
                set runLength to runLength + 1
            end repeat
            set sourceEnd to sourceStart + runLength - 1
            set selectedEnd to selectedOffset + runLength - 1
            set expectedRange to items selectedOffset through selectedEnd of selectedIDs
            set candidateIDs to missing value
            try
                set candidateIDs to get persistent ID of tracks sourceStart through sourceEnd of sourcePlaylist
            on error number rangeError
                if rangeError is not -1728 then error number rangeError
            end try
            if candidateIDs is expectedRange then
                set contextStage to "append"
                duplicate (tracks sourceStart through sourceEnd of sourcePlaylist) to targetPlaylist
                set selectedOffset to selectedEnd + 1
            else
                set matchedTracks to (tracks of sourcePlaylist whose persistent ID is selectedID)
                if (count of matchedTracks) is 0 then error number -1728
                set contextStage to "append"
                duplicate (item 1 of matchedTracks) to targetPlaylist
                set selectedOffset to selectedOffset + 1
            end if
            set copyOperations to copyOperations + 1
        end repeat
        """
    }

}
