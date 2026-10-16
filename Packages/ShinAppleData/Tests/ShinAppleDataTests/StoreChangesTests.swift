import Darwin
import Foundation
import GRDB
import Testing
import ShinAppleKit
@testable import ShinAppleData

@Suite("本地歌词存储变化通知", .timeLimit(.minutes(1)))
struct StoreChangesTests {
    @Test("订阅有初始值，其他连接的保存、修改和解除关联都会通知")
    func anotherConnectionChanges() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let reader = try TestEnv.makeStore(directory)
        let writer = try TestEnv.makeStore(directory)
        let probe = ChangeProbe()
        let observation = observe(reader, into: probe)
        defer { observation.cancel() }
        try await waitUntil { await probe.eventCount > 0 }
        #expect(await probe.snapshot?.documents.isEmpty == true)

        var document = Fixture.documentA()
        let documentID = document.id
        let binding = Fixture.binding(Fixture.trackA, to: document)
        try await writer.save(document: document, binding: binding)
        try await waitUntil { await probe.snapshot?.documents[documentID]?.revision == 3 }
        document.revision += 1
        document.lines[0].text = "另一个连接写入的原创文本"
        try await writer.updateDocument(document)
        try await waitUntil { await probe.snapshot?.documents[documentID]?.revision == 4 }
        try await writer.deleteBinding(forTrackKey: binding.trackKey)
        try await waitUntil { await probe.snapshot?.bindings.isEmpty == true }
        #expect(await probe.snapshot?.documents[document.id]?.lines[0].text == document.lines[0].text)
    }

    @Test("WAL checkpoint 后继续收到外部连接写入，读查询不形成通知循环")
    func checkpointAndReadStability() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let reader = try TestEnv.makeStore(directory)
        let writer = try TestEnv.makeStore(directory)
        let probe = ChangeProbe()
        let observation = observe(reader, into: probe)
        defer { observation.cancel() }
        try await waitUntil { await probe.eventCount > 0 }
        _ = try await writer.relocationSourcePool.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
        let document = Fixture.documentA()
        try await writer.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))
        try await waitUntil { await probe.snapshot?.documents[document.id] != nil }
        // 等待最后一批文件事件被消费，再检查连续读取不会写出 shm 通知循环。
        try await Task.sleep(for: .milliseconds(150))
        let before = await probe.eventCount
        for _ in 0..<8 { _ = try await reader.currentSnapshot() }
        try Data("目录中的无关文件".utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent("unrelated.txt"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await probe.eventCount == before)
    }

    @Test("取消消费后不再接收并释放只读监控文件描述符")
    func cancellationReleasesFileDescriptors() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let reader = try TestEnv.makeStore(directory)
        let writer = try TestEnv.makeStore(directory)
        let before = eventOnlyDescriptorCount(in: directory)
        let probe = ChangeProbe()
        let observation = observe(reader, into: probe)
        try await waitUntil { await probe.eventCount > 0 }
        #expect(eventOnlyDescriptorCount(in: directory) > before)
        observation.cancel()
        await observation.value
        try await waitUntil { eventOnlyDescriptorCount(in: directory) == before }
        let received = await probe.eventCount
        let document = Fixture.documentA()
        try await writer.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await probe.eventCount == received)
        #expect(eventOnlyDescriptorCount(in: directory) == before)
    }
}

private actor ChangeProbe {
    var snapshot: BackupStoreSnapshot?
    var eventCount = 0

    func record(_ snapshot: BackupStoreSnapshot) {
        self.snapshot = snapshot
        eventCount += 1
    }
}

private func observe(_ store: GRDBLyricsStore, into probe: ChangeProbe) -> Task<Void, Never> {
    // 先同步建立订阅，之后 Task 尚未调度也不会丢掉安装间隙的提交。
    let changes = store.changes()
    return Task {
        for await _ in changes {
            guard !Task.isCancelled else { return }
            if let snapshot = try? await store.currentSnapshot() { await probe.record(snapshot) }
        }
    }
}

private struct ChangeNotificationTimeout: Error {}

private func waitUntil(_ predicate: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw ChangeNotificationTimeout() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func eventOnlyDescriptorCount(in directory: String) -> Int {
    guard let resolvedPath = realpath(directory, nil) else { return 0 }
    defer { free(resolvedPath) }
    let canonicalDirectory = String(cString: resolvedPath)
    return (0..<getdtablesize()).filter { descriptor in
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, flags & O_EVTONLY != 0 else { return false }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = path.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let address = buffer.baseAddress else { return -1 }
            return fcntl(descriptor, F_GETPATH, UnsafeMutableRawPointer(address))
        }
        let decoded = String(bytes: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
        return result == 0 && decoded?.hasPrefix(canonicalDirectory) == true
    }.count
}
