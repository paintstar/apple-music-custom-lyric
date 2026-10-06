import Foundation

// domain/lyrics：字节解码与输入预处理（严格、无静默替换）。
// 供 LyricsParser 使用；模块内部实现，不属于公开契约。
//
// 编码支持：默认 UTF-8 与 UTF-8 BOM；检测到 UTF-16 LE/BE BOM 时顺带支持。
// 无法解码时报告首个非法序列的字节位置，绝不替换为 U+FFFD。

/// 输入解码与行切分。
enum LyricInputDecoding {

    static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// 按字节序 BOM 判定编码并严格解码：
    /// UTF-8 BOM / UTF-16 LE BOM / UTF-16 BE BOM / 无 BOM 时按 UTF-8。
    static func decode(_ bytes: [UInt8]) throws -> String {
        if bytes.starts(with: utf8BOM) {
            return try decodeUTF8(bytes, from: utf8BOM.count)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return try decodeUTF16(bytes, littleEndian: true, from: 2)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return try decodeUTF16(bytes, littleEndian: false, from: 2)
        }
        return try decodeUTF8(bytes, from: 0)
    }

    /// 严格 UTF-8 解码：拒绝非法首字节/续字节、过长编码、代理项区与越界码点。
    static func decodeUTF8(_ bytes: [UInt8], from start: Int) throws -> String {
        var index = start
        while index < bytes.count {
            guard let sequenceLength = utf8SequenceLength(bytes[index]),
                  utf8Scalar(bytes, at: index, length: sequenceLength) != nil else {
                throw LyricParseError.undecodableUTF8(byteOffset: index)
            }
            index += sequenceLength
        }
        // 已逐序列校验；防御性兜底仍用可失败初始化，不静默替换。
        guard let text = String(bytes: bytes[start...], encoding: .utf8) else {
            throw LyricParseError.undecodableUTF8(byteOffset: start)
        }
        return text
    }

    /// 首字节 → 序列字节数；非法首字节返回 nil。
    private static func utf8SequenceLength(_ lead: UInt8) -> Int? {
        switch lead {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return nil
        }
    }

    /// 校验从 index 开始的 length 字节序列并返回码点；非法返回 nil
    /// （含续字节不合法、过长编码、UTF-16 代理项区、超出 Unicode 上限）。
    private static func utf8Scalar(_ bytes: [UInt8], at index: Int, length: Int) -> UInt32? {
        guard index + length <= bytes.count else { return nil }
        let lead = bytes[index]
        var scalar: UInt32
        switch length {
        case 1: scalar = UInt32(lead)
        case 2: scalar = UInt32(lead & 0x1F)
        case 3: scalar = UInt32(lead & 0x0F)
        default: scalar = UInt32(lead & 0x07)
        }
        for offset in 1..<length {
            let continuation = bytes[index + offset]
            guard continuation & 0xC0 == 0x80 else { return nil }
            scalar = (scalar << 6) | UInt32(continuation & 0x3F)
        }
        return utf8ScalarIsValid(scalar, length: length) ? scalar : nil
    }

    /// 序列码点值合法性：拒绝过长编码、代理项区与超出 Unicode 上限。
    private static func utf8ScalarIsValid(_ scalar: UInt32, length: Int) -> Bool {
        switch length {
        case 1: return true
        case 2: return scalar >= 0x80
        case 3: return scalar >= 0x800 && !(0xD800...0xDFFF).contains(scalar)
        default: return (0x1_0000...0x10_FFFF).contains(scalar)
        }
    }

    /// 严格 UTF-16 解码：拒绝奇数字节与未配对代理项，失败时报告字节偏移。
    static func decodeUTF16(_ bytes: [UInt8], littleEndian: Bool, from start: Int) throws -> String {
        var units: [UInt16] = []
        units.reserveCapacity((bytes.count - start) / 2)
        var index = start
        while index + 1 < bytes.count {
            let firstByte = bytes[index]
            let secondByte = bytes[index + 1]
            // LE：首字节为低位；BE：首字节为高位。
            let unit = littleEndian
                ? UInt16(secondByte) << 8 | UInt16(firstByte)
                : UInt16(firstByte) << 8 | UInt16(secondByte)
            units.append(unit)
            index += 2
        }
        guard index == bytes.count else {
            throw LyricParseError.undecodableUTF16(byteOffset: index)
        }
        var unitIndex = 0
        while unitIndex < units.count {
            let unit = units[unitIndex]
            if (0xD800...0xDBFF).contains(unit) {
                let paired = unitIndex + 1 < units.count && (0xDC00...0xDFFF).contains(units[unitIndex + 1])
                guard paired else {
                    throw LyricParseError.undecodableUTF16(byteOffset: start + unitIndex * 2)
                }
                unitIndex += 2
            } else if (0xDC00...0xDFFF).contains(unit) {
                throw LyricParseError.undecodableUTF16(byteOffset: start + unitIndex * 2)
            } else {
                unitIndex += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// 按 LF、CRLF、CR 切分行；行内容保留原字符（不含行分隔符）。
    /// 注意：Swift 字符串按字素簇迭代，CRLF 是单个 Character，需显式处理。
    /// 末尾有换行符时不产生多余空行。
    static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var previousWasCarriageReturn = false
        for character in text {
            if character == "\r\n" {
                lines.append(current)
                current = ""
                previousWasCarriageReturn = false
            } else if character == "\r" {
                lines.append(current)
                current = ""
                previousWasCarriageReturn = true
            } else if character == "\n" {
                if !previousWasCarriageReturn {
                    lines.append(current)
                }
                current = ""
                previousWasCarriageReturn = false
            } else {
                current.append(character)
                previousWasCarriageReturn = false
            }
        }
        lines.append(current)
        let endsWithNewline = text.hasSuffix("\n") || text.hasSuffix("\r\n") || text.hasSuffix("\r")
        if endsWithNewline, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}
