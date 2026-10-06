import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

@Suite("自动导入与人工保存竞争")
struct AutoImportSafetyTests {
    @Test("自动预览之后的人工导入优先；人工确认仍可按原有方式替换")
    func manualImportWins() async throws {
        let (store, directory) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(directory) }
        let automatic = ImportWorkflowService(store: store)
        try await automatic.openImportSession(target: Fixture.targetA())
        _ = try await automatic.ingest(fileData: Fixture.lrcData, filename: nil)
        let manual = ImportWorkflowService(store: store)
        try await manual.openImportSession(target: Fixture.targetA())
        _ = try await manual.ingest(fileData: Fixture.lrcData, filename: nil)
        let expected = try await manual.confirmImport()
        #expect(try await automatic.confirmImportIfUnbound(isValid: { true }) == nil)
        #expect(try await store.document(for: Fixture.trackA) == expected.document)
        #expect(try await store.allDocuments().count == 1)
        let explicit = try await automatic.confirmImport()
        #expect(explicit.replacedBinding == expected.binding)
        #expect(try await store.document(for: Fixture.trackA) == explicit.document)
    }

    @Test("已停用的自动导入不保存文档和绑定")
    func inactiveImportDoesNotWrite() async throws {
        let (store, directory) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(directory) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())
        _ = try await service.ingest(fileData: Fixture.lrcData, filename: nil)
        await #expect(throws: CancellationError.self) {
            _ = try await service.confirmImportIfUnbound(isValid: { false })
        }
        #expect(try await store.allDocuments().isEmpty)
        #expect(try await store.allBindings().isEmpty)
    }
}
