import Foundation
import Testing
import ShinAppleKit
@testable import ShinAppleData

// 运行期保存位置切换：在线备份 API 的行为锁定。
// 全部使用临时目录与原创夹具，不触及任何真实数据。
struct RuntimeRelocationTests {

    @Test("在线备份产出内容一致的新库，源库继续可用")
    func backupProducesConsistentCopy() async throws {
        let sourceDir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(sourceDir) }
        let targetDir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(targetDir) }
        let source = try TestEnv.makeStore(sourceDir)
        let document = Fixture.documentA()
        try await source.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))

        try source.backupDatabase(toFileAt: TestEnv.storePath(in: targetDir))

        let target = try TestEnv.makeStore(targetDir)
        #expect(try await target.document(for: Fixture.trackA) == document)

        // 源库备份后继续可写（backup 不锁源、不停止服务）。
        let extra = Fixture.textDocument()
        try await source.save(document: extra, binding: Fixture.binding(Fixture.trackB, to: extra))
        #expect(try await source.document(for: Fixture.trackB) == extra)
        // 备份是完成时刻的快照，之后源库新增的数据不在其中。
        #expect(try await target.document(for: Fixture.trackB) == nil)
    }

    @Test("目标已有数据库文件时拒绝覆盖")
    func refusesToOverwrite() async throws {
        let sourceDir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(sourceDir) }
        let targetDir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(targetDir) }
        let source = try TestEnv.makeStore(sourceDir)
        let document = Fixture.documentA()
        try await source.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))

        // 目标位置先有自己的库与不同内容。
        let target = try TestEnv.makeStore(targetDir)
        let targetDocument = Fixture.textDocument()
        try await target.save(
            document: targetDocument, binding: Fixture.binding(Fixture.trackC, to: targetDocument)
        )

        await #expect(throws: ShinAppleDataError.self) {
            try source.backupDatabase(toFileAt: TestEnv.storePath(in: targetDir))
        }
        #expect(try await target.document(for: Fixture.trackC) == targetDocument)
        #expect(try await target.document(for: Fixture.trackA) == nil, "被拒绝的备份不得改动目标")
    }

    @Test("目标目录不可写时失败且不留半成品")
    func readOnlyTargetFailsCleanly() async throws {
        let sourceDir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(sourceDir) }
        let targetDir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(targetDir) }
        let source = try TestEnv.makeStore(sourceDir)
        let document = Fixture.documentA()
        try await source.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))

        try TestEnv.makeReadOnly(targetDir)
        await #expect(throws: ShinAppleDataError.self) {
            try source.backupDatabase(toFileAt: TestEnv.storePath(in: targetDir))
        }
        try TestEnv.makeWritable(targetDir)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: targetDir)
            .filter { $0.contains("partial") || $0.hasSuffix(".sqlite") }
        #expect(leftovers.isEmpty, "失败后不得残留半成品文件：\(leftovers)")
        // 源库不受失败影响。
        #expect(try await source.document(for: Fixture.trackA) == document)
    }

    @Test("hasAnyContent 反映库是否为空")
    func hasAnyContentReflectsEmptiness() async throws {
        let emptyDir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(emptyDir) }
        let empty = try TestEnv.makeStore(emptyDir)
        #expect(await empty.hasAnyContent() == false)

        let seededDir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(seededDir) }
        let seeded = try TestEnv.makeStore(seededDir)
        let document = Fixture.documentA()
        try await seeded.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))
        #expect(await seeded.hasAnyContent() == true)
    }
}
