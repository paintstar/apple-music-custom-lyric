import AppKit
import Foundation
import SwiftUI
import ShinAppleKit

/// 可控延迟与失败，只验证本地状态和生产音量控件，不实例化真实 Music 服务。
@MainActor
enum PlaybackOptionsUICheck {
    static func runChecks() async throws {
        try await checkPendingVolume()
        try await checkPreparePlayback()
        try await checkNativeVolume()
    }

    private static func checkPendingVolume() async throws {
        let service = OptionsCheckService()
        let model = PlaybackOptionsModel(service: service)
        model.refresh()
        try await settle("初始读取应送出") { await service.commands == [.read] }
        await service.completeNext()
        try await settle("初始音量确认") { model.snapshot.volume == 40 && !model.isBusy }
        model.setVolume(70)
        precondition(model.displayedVolume == 70 && model.snapshot.volume == 40, "松手后保留目标，不冒充确认值")
        model.setVolume(80)
        model.setVolume(91)
        try await settle("第一笔写入送出") { await service.commands == [.read, .volume(70)] }
        await service.completeNext()
        try await settle("连续输入只排队最新音量") { await service.commands == [.read, .volume(70), .volume(91)] }
        precondition(model.displayedVolume == 91 && model.snapshot.volume == 70 && model.isBusy,
                     "较旧读回不能把滑块从最新目标拉回")
        await service.completeNext()
        try await settle("最终确认清理目标") { model.snapshot.volume == 91 && model.pendingVolume == nil && !model.isBusy }

        model.setVolume(33)
        try await settle("失败写入送出") { await service.commands.last == .volume(33) }
        await service.completeNext(failing: true)
        try await settle("失败保留确认值并报告") {
            model.displayedVolume == 91 && model.snapshot.volume == 91 && !model.isBusy && model.errorMessage != nil
        }
        model.refresh()
        model.setVolume(42)
        try await settle("刷新与写入串行") { await service.commands.last == .read }
        await service.completeNext()
        try await settle("刷新后提交最新音量") { await service.commands.last == .volume(42) }
        precondition(model.displayedVolume == 42, "读取旧音量不能清掉待提交目标")
        await service.completeNext()
        try await settle("刷新期间的输入最终生效") { model.snapshot.volume == 42 && !model.isBusy }

        model.setVolume(65)
        try await settle("生命周期旧写入送出") { await service.commands.last == .volume(65) }
        model.cancel()
        precondition(model.pendingVolume == nil && !model.isBusy, "隐藏时清理待确认值")
        model.refresh()
        try await settle("新生命周期读取送出") { await service.commands.last == .read }
        await service.completeNext()
        await Task.yield()
        precondition(model.snapshot.volume == 42 && model.isBusy, "取消后的旧完成不得覆盖新生命周期")
        await service.completeNext()
        try await settle("新读取可正常确认") { model.snapshot.volume == 65 && !model.isBusy }
        print("PASS 音量待确认值、串行合并最新输入、失败保留确认值、刷新输入与生命周期隔离")
    }

    private static func checkPreparePlayback() async throws {
        let service = OptionsCheckService()
        let model = PlaybackOptionsModel(service: service)
        model.refresh()
        let prepare = Task { await model.preparePlayback(shuffleEnabled: true) }
        try await settle("播放准备先等待读取") { await service.commands == [.read] }
        await service.completeNext()
        try await settle("播放准备设置随机") { await service.commands == [.read, .shuffle(true)] }
        await service.completeNext()
        let prepared = await prepare.value
        precondition(prepared && model.snapshot.shuffleEnabled == true, "随机状态确认后才能继续播放")

        let failedWithVolume = Task { await model.preparePlayback(shuffleEnabled: true) }
        try await settle("失败播放准备送出") { await service.commands.count == 3 }
        model.setVolume(55)
        await service.completeNext(failing: true)
        let failedResult = await failedWithVolume.value
        precondition(!failedResult, "排队音量不能掩盖随机设置失败，即使旧状态恰好匹配")
        try await settle("失败准备仍需完成排队音量") { await service.commands.last == .volume(55) }
        await service.completeNext()
        try await settle("排队音量确认") { !model.isBusy }

        let mismatch = Task { await model.preparePlayback(shuffleEnabled: false) }
        try await settle("第二次播放准备送出") { await service.commands.last == .shuffle(false) }
        await service.completeNext(reported: .init(volume: 40, shuffleEnabled: true, repeatMode: .off))
        let mismatchResult = await mismatch.value
        precondition(!mismatchResult && model.errorMessage != nil, "写入后状态不匹配必须阻止误播")

        model.refresh()
        let cancelled = Task { await model.preparePlayback(shuffleEnabled: false) }
        try await settle("取消前读取送出") { await service.commands.last == .read }
        model.cancel()
        await service.completeNext()
        let cancelledResult = await cancelled.value
        precondition(!cancelledResult && !model.isBusy, "生命周期取消不能继续触发主页播放")
        print("PASS 主页播放准备等待、随机读回确认、不匹配阻止播放与取消隔离")
    }

    private static func checkNativeVolume() async throws {
        let service = OptionsCheckService()
        let model = PlaybackOptionsModel(service: service)
        model.refresh()
        try await settle("原生音量初始读取") { await service.commands == [.read] }
        await service.completeNext()
        try await settle("原生音量初始确认") { model.snapshot.volume == 40 && !model.isBusy }
        let preview = VolumePreviewProbe()
        let host = NSHostingView(rootView: VolumeCheckHost(model: model, preview: preview).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 260, height: 132),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle("生产音量滑块挂载") {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            host.displayIfNeeded()
            guard let slider = findSlider(host), let cell = slider.cell as? NSSliderCell else { return false }
            slider.displayIfNeeded()
            let knob = cell.knobRect(flipped: slider.isFlipped)
            let bar = cell.barRect(flipped: slider.isFlipped)
            return window.isKeyWindow && slider.integerValue == 40 && knob.width > 0 && knob.height > 0
                && bar.width > knob.width && slider.bounds.contains(NSPoint(x: knob.midX, y: knob.midY))
        }
        let slider = findSlider(host)!
        let identity = ObjectIdentifier(slider)
        let originalFrame = slider.frame
        let originalSize = host.fittingSize
        let initialKnob = (slider.cell as! NSSliderCell).knobRect(flipped: slider.isFlipped)
        let initialBar = (slider.cell as! NSSliderCell).barRect(flipped: slider.isFlipped)
        let start = NSPoint(x: initialKnob.midX + 2, y: initialKnob.midY)
        let end = NSPoint(x: slider.bounds.width * 0.72, y: slider.bounds.midY)
        let hit = host.hitTest(slider.convert(start, to: host.superview))
        precondition(hit === slider && !slider.mouseDownCanMoveWindow,
                     "音量滑块必须命中且不能拖窗：hit=\(String(describing: hit)), frame=\(slider.frame), "
                     + "bounds=\(slider.bounds), knob=\(initialKnob), bar=\(initialBar), start=\(start)")
        let event: @MainActor @Sendable (NSEvent.EventType, NSPoint) -> NSEvent = { type, point in
            NSEvent.mouseEvent(with: type, location: slider.convert(point, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // 与生产进度控件同样由窗口派发连续事件；不嵌套阻塞 AppKit 跟踪循环。
        window.sendEvent(event(.leftMouseDown, start))
        precondition(slider.isTrackingMouse && abs(slider.integerValue - 40) <= 1,
                     "抓住滑块边缘不应跳动：tracking=\(slider.isTrackingMouse), value=\(slider.integerValue)")
        for point in [end, start, end] {
            window.sendEvent(event(.leftMouseDragged, point))
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
            precondition(slider.isTrackingMouse && model.pendingVolume == nil && !model.isBusy,
                         "持续拖动只能预览：tracking=\(slider.isTrackingMouse), pending=\(String(describing: model.pendingVolume)), "
                         + "busy=\(model.isBusy), enabled=\(slider.isEnabled), value=\(slider.integerValue), previews=\(preview.values)")
            precondition(slider.frame == originalFrame && host.fittingSize == originalSize, "持续拖动不得重排弹窗")
            if point == end { precondition(slider.integerValue > 60, "拖动必须真正改变音量") }
        }
        window.sendEvent(event(.leftMouseUp, end))
        try await settle("松手应提交一次且保留目标") { model.pendingVolume != nil && !slider.isTrackingMouse }
        let target = model.pendingVolume!
        precondition(target != 40 && slider.integerValue == target && slider.isEnabled,
                     "等待读回不能回跳或变灰：target=\(target), slider=\(slider.integerValue), enabled=\(slider.isEnabled), "
                     + "snapshot=\(String(describing: model.snapshot.volume)), tracking=\(slider.isTrackingMouse), busy=\(model.isBusy), "
                     + "previews=\(preview.values)")
        let expectedDragCommands: [OptionsCheckService.Command] = [.read, .volume(target)]
        try await settle("松手后的异步音量请求应实际送出") {
            let commands = await service.commands
            precondition(commands.count <= expectedDragCommands.count,
                         "松手不能重复提交：actual=\(commands), expected=\(expectedDragCommands)")
            return commands == expectedDragCommands
        }
        let dragCommands = await service.commands
        precondition(dragCommands == expectedDragCommands,
                     "多次原生拖动只在松手提交一次：actual=\(dragCommands), expected=\(expectedDragCommands)")
        // 未确认期间再用原生方向键提交不同目标，覆盖连续输入与较旧读回。
        window.makeFirstResponder(slider)
        let beforeKey = slider.integerValue
        slider.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
                                             isARepeat: false, keyCode: 124)!)
        try await settle("方向键应在未确认时直接提交新目标") { model.pendingVolume != beforeKey }
        let keyTarget = model.pendingVolume!
        precondition(keyTarget != beforeKey && slider.integerValue == keyTarget, "原生方向键必须实际调节音量")
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(15))
            host.layoutSubtreeIfNeeded()
            precondition(findSlider(host).map(ObjectIdentifier.init) == identity && slider.isEnabled
                         && slider.integerValue == keyTarget && slider.frame == originalFrame && host.fittingSize == originalSize,
                         "慢速读回期间滑块实例、目标、布局与弹窗高度应稳定")
        }
        await service.completeNext()
        try await settle("旧拖动确认后提交键盘新目标") { await service.commands.count == 3 }
        host.layoutSubtreeIfNeeded()
        precondition(model.pendingVolume == keyTarget && slider.integerValue == keyTarget && slider.isEnabled,
                     "旧鼠标确认不能清理或回跳较新的键盘目标")
        await service.completeNext()
        try await settle("方向键目标确认") { !model.isBusy && model.snapshot.volume == keyTarget }
        host.layoutSubtreeIfNeeded()
        precondition(slider.frame == originalFrame && host.fittingSize == originalSize, "成功读回不应重排弹窗")
        let beforeAX = slider.integerValue
        precondition(slider.accessibilityPerformDecrement(), "音量滑块应保留辅助功能递减动作")
        try await settle("辅助功能调节应直接提交") { model.pendingVolume != nil }
        precondition(model.pendingVolume == beforeAX - 1, "辅助功能递减应精确调节一个百分点")
        try await settle("辅助功能写入送出") { await service.commands.count == 4 }
        await service.completeNext()
        try await settle("辅助功能确认") { !model.isBusy }

        let cancellationKnob = (slider.cell as! NSSliderCell).knobRect(flipped: slider.isFlipped)
        window.sendEvent(event(.leftMouseDown, NSPoint(x: cancellationKnob.midX, y: cancellationKnob.midY)))
        window.sendEvent(event(.leftMouseDragged, NSPoint(x: slider.bounds.maxX + 60, y: slider.bounds.midY)))
        precondition(slider.integerValue == 100 && model.pendingVolume == nil, "拖出轨道应裁剪到最大值但不提前写入")
        window.sendEvent(event(.leftMouseDragged, NSPoint(x: slider.bounds.minX - 60, y: slider.bounds.midY)))
        precondition(slider.integerValue == 0 && model.pendingVolume == nil, "向左拖出轨道应裁剪到最小值")
        window.contentView = nil
        try await settle("卸载窗口应取消预览") { !slider.isTrackingMouse && preview.value == nil }
        slider.mouseUp(with: event(.leftMouseUp, end))
        let finalCommands = await service.commands
        precondition(finalCommands.count == 4 && model.pendingVolume == nil, "卸载后的松手不得提交旧手势")
        print("PASS 原生音量持续拖动实际变化、松手一次提交、慢读回与连续输入不回跳、固定布局、键盘/辅助功能、边界裁剪与卸载取消")
    }

    private static func settle(_ message: String, _ predicate: () async -> Bool) async throws {
        for _ in 0..<250 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure(message)
    }

    private static func findSlider(_ view: NSView) -> PlaybackVolumeSlider.VolumeSlider? {
        if let slider = view as? PlaybackVolumeSlider.VolumeSlider { return slider }
        return view.subviews.lazy.compactMap(findSlider).first
    }
}

private struct VolumeCheckHost: View {
    @ObservedObject var model: PlaybackOptionsModel
    @ObservedObject var preview: VolumePreviewProbe
    var body: some View {
        PlaybackVolumePopover(model: model, previewVolume: Binding(get: { preview.value }, set: { preview.update($0) }))
    }
}

@MainActor private final class VolumePreviewProbe: ObservableObject {
    @Published var value: Int?
    var values: [Int] = []
    func update(_ volume: Int?) {
        value = volume
        if let volume { values.append(volume) }
    }
}

private actor OptionsCheckService: PlaybackOptionsControlling {
    enum Command: Equatable, Sendable { case read, volume(Int), shuffle(Bool), repeatMode(PlaybackRepeatMode) }
    enum CheckFailure: Error { case unavailable }
    private var snapshot = PlaybackOptionsSnapshot(volume: 40, shuffleEnabled: false, repeatMode: .off)
    private var pending: [(Command, CheckedContinuation<PlaybackOptionsSnapshot, Error>)] = []
    private(set) var commands: [Command] = []

    func readOptions() async throws -> PlaybackOptionsSnapshot { try await perform(.read) }
    func setVolume(_ value: Int) async throws -> PlaybackOptionsSnapshot { try await perform(.volume(value)) }
    func setShuffleEnabled(_ value: Bool) async throws -> PlaybackOptionsSnapshot { try await perform(.shuffle(value)) }
    func setRepeatMode(_ value: PlaybackRepeatMode) async throws -> PlaybackOptionsSnapshot { try await perform(.repeatMode(value)) }

    private func perform(_ command: Command) async throws -> PlaybackOptionsSnapshot {
        commands.append(command)
        return try await withCheckedThrowingContinuation { pending.append((command, $0)) }
    }

    func completeNext(failing: Bool = false, reported: PlaybackOptionsSnapshot? = nil) {
        precondition(!pending.isEmpty, "测试需要先送出选项请求")
        let (command, continuation) = pending.removeFirst()
        if failing { continuation.resume(throwing: CheckFailure.unavailable); return }
        switch command {
        case .read: break
        case let .volume(value): snapshot.volume = value
        case let .shuffle(value): snapshot.shuffleEnabled = value
        case let .repeatMode(value): snapshot.repeatMode = value
        }
        if let reported { snapshot = reported }
        continuation.resume(returning: snapshot)
    }
}
