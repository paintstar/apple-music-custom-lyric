import Foundation

// domain/lyrics：schema v1 校验。
// 供存储层与备份导入复用的入口。所有问题都直接拒绝：
// 校验是纯函数，绝不修改传入数据，调用方据结果决定是否入库，
// 任何失败都不允许触碰已有库数据。

/// schema 校验问题（拒绝理由）。
public enum LyricSchemaIssue: Error, Equatable, Sendable {
    /// schemaVersion 不是当前支持的版本（如未来版本）：拒绝导入，原库不变。
    case unsupportedSchemaVersion(found: Int)
    /// 重复 line.id：行身份必须唯一，翻译按 id 绑定，重复会错配。
    case duplicateLineId(UUID)
    /// 非有限时间（NaN/无穷大）：只能出现在 JSON 层，模型层 Int64 不可能。
    case nonFiniteTime(lineId: UUID)
    /// 小数毫秒：拒绝（不静默取整）。
    case fractionalMilliseconds(lineId: UUID)
    /// 时间超出 Int64 毫秒范围。
    case timeOutOfRange(lineId: UUID)
    /// 结构/类型非法，message 描述位置与原因。
    case invalidStructure(String)
}

/// schema v1 校验器。
public enum LyricSchemaValidator {

    /// 校验内存中的文档。返回空数组表示合法。
    /// 说明：startMs 为 Int64?，模型层天然不可能出现小数/非有限时间，
    /// 因此这两类问题只在 JSON 备份入口（`issuesInBackupJSON`）检查。
    public static func issues(in document: LyricDocument) -> [LyricSchemaIssue] {
        var issues: [LyricSchemaIssue] = []
        if document.schemaVersion != LyricDocument.currentSchemaVersion {
            issues.append(.unsupportedSchemaVersion(found: document.schemaVersion))
        }
        var seenIds = Set<UUID>()
        for line in document.lines {
            if seenIds.contains(line.id) {
                issues.append(.duplicateLineId(line.id))
            }
            seenIds.insert(line.id)
        }
        return issues
    }

    /// 校验 JSON 备份字节（备份导入入口）。
    ///
    /// 用 JSONSerialization 在解码到模型之前检查数值形状：
    /// 小数毫秒、非有限时间、越界时间在这里显式拒绝，避免解码层把小数
    /// 静默截断成整数毫秒。非 JSON 标准的非有限字面量（如 1e999）会在
    /// JSON 解析层被直接拒绝。未知键一律忽略（白名单解析），
    /// 未来版本由 schemaVersion 检查拒绝。
    public static func issuesInBackupJSON(_ data: Data) -> [LyricSchemaIssue] {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return [.invalidStructure("不是合法 JSON：\(error.localizedDescription)")]
        }
        guard let root = raw as? [String: Any] else {
            return [.invalidStructure("顶层必须是 JSON 对象")]
        }
        return issues(inJSONObject: root)
    }

    /// 校验已解析的 JSON 对象图（用其他解码方式时的复用入口）。
    /// 数值必须以 NSNumber 到达；小数/非有限/越界在此拒绝，绝不取整或裁剪。
    public static func issues(inJSONObject root: [String: Any]) -> [LyricSchemaIssue] {
        var issues: [LyricSchemaIssue] = []
        if let versionIssue = validateSchemaVersion(root["schemaVersion"]) {
            issues.append(versionIssue)
        }
        guard let rawLines = root["lines"] as? [[String: Any]] else {
            issues.append(.invalidStructure("缺少 lines 数组"))
            return issues
        }
        issues.append(contentsOf: validateLines(rawLines))
        return issues
    }

    private static func validateSchemaVersion(_ value: Any?) -> LyricSchemaIssue? {
        guard let number = value as? NSNumber, !isBoolean(number) else {
            return .invalidStructure("缺少 schemaVersion 或类型不是数字")
        }
        guard let version = exactInt64(number) else {
            return .invalidStructure("schemaVersion 必须是整数")
        }
        guard version == Int64(LyricDocument.currentSchemaVersion) else {
            return .unsupportedSchemaVersion(found: Int(version))
        }
        return nil
    }

    private static func validateLines(_ rawLines: [[String: Any]]) -> [LyricSchemaIssue] {
        var issues: [LyricSchemaIssue] = []
        var seenIds = Set<UUID>()
        for (index, rawLine) in rawLines.enumerated() {
            guard let idText = rawLine["id"] as? String, let id = UUID(uuidString: idText) else {
                issues.append(.invalidStructure("第 \(index + 1) 行缺少合法的 id（UUID）"))
                continue
            }
            if seenIds.contains(id) {
                issues.append(.duplicateLineId(id))
            }
            seenIds.insert(id)
            if let issue = validateStartMs(rawLine["startMs"], lineId: id, index: index) {
                issues.append(issue)
            }
        }
        return issues
    }

    private static func validateStartMs(_ value: Any?, lineId: UUID, index: Int) -> LyricSchemaIssue? {
        // 缺失或 JSON null：未打轴（startMs = nil），合法。
        if value == nil || value is NSNull {
            return nil
        }
        guard let number = value as? NSNumber, !isBoolean(number) else {
            return .invalidStructure("第 \(index + 1) 行 startMs 类型非法（应为整数毫秒或 null）")
        }
        guard let finite = finiteDouble(number) else {
            return .nonFiniteTime(lineId: lineId)
        }
        guard exactInt64(number) == nil else {
            return nil // 整数且在 Int64 范围内：合法
        }
        if finite != finite.rounded(.towardZero) {
            return .fractionalMilliseconds(lineId: lineId)
        }
        return .timeOutOfRange(lineId: lineId)
    }

    /// NSNumber 是否为 JSON 布尔（true/false 会桥接成 NSNumber）。
    private static func isBoolean(_ number: NSNumber) -> Bool {
        String(cString: number.objCType) == "c"
    }

    /// 非有限值返回 nil；否则返回 Double 值。
    private static func finiteDouble(_ number: NSNumber) -> Double? {
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    /// NSNumber 是否为可精确落入 Int64 的整数。
    private static func exactInt64(_ number: NSNumber) -> Int64? {
        switch String(cString: number.objCType) {
        case "c", "i", "s", "l", "q":
            return number.int64Value
        case "f", "d":
            return Int64(exactly: number.doubleValue)
        default:
            return nil
        }
    }
}
