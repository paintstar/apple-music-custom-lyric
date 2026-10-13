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
        try await checkModeChanges()
        try await checkNativeModeHelp()
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
        model.refreshAfterPlayback()
        try await settle("播放后刷新先等待旧读取") { await service.commands == [.read] }
        await service.completeNext()
        try await settle("列表服务确认播放后只重新读取，不在无曲目时预设随机") {
            await service.commands == [.read, .read]
        }
        await service.completeNext(reported: .init(volume: 40, shuffleEnabled: true, repeatMode: .off))
        try await settle("刷新确认上下文服务设置的随机状态") { !model.isBusy && model.snapshot.shuffleEnabled == true }

        model.setVolume(55)
        model.refreshAfterPlayback()
        model.setVolume(67)
        try await settle("等待音量不插入随机写入") { await service.commands.last == .volume(55) }
        await service.completeNext()
        try await settle("先提交最新排队音量") { await service.commands.last == .volume(67) }
        await service.completeNext()
        try await settle("音量完成后刷新播放方式") { await service.commands.last == .read }
        await service.completeNext(reported: .init(volume: 67, shuffleEnabled: false, repeatMode: .off))
        try await settle("刷新确认普通播放和最新音量") {
            !model.isBusy && model.snapshot.shuffleEnabled == false && model.snapshot.volume == 67
        }

        model.refresh()
        model.refreshAfterPlayback()
        try await settle("取消前读取送出") { await service.commands.count == 6 }
        model.cancel()
        await service.completeNext()
        try await Task.sleep(for: .milliseconds(30))
        let commands = await service.commands
        precondition(commands.count == 6 && !model.isBusy, "生命周期取消不能送出迟到的播放后刷新")
        print("PASS 上下文播放后刷新、保留音量串行合并、读取真实随机状态与取消隔离")
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
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate()
        defer { window.close() }
        let windowReadiness = {
            "active=\(NSApplication.shared.isActive), visible=\(window.isVisible), "
                + "unoccluded=\(window.occlusionState.contains(.visible)), key=\(window.isKeyWindow)"
        }
        try await settle("音量测试窗口激活与可见", failureDetails: windowReadiness) {
            window.displayIfNeeded()
            return NSApplication.shared.isActive && window.isVisible && window.occlusionState.contains(.visible)
        }
        // 激活完成后再请求键盘焦点，避免应用尚未激活时的首次请求被系统延后。
        window.makeKeyAndOrderFront(nil)
        try await settle("音量测试窗口接收键盘焦点", failureDetails: windowReadiness) { window.isKeyWindow }
        var mountReadiness: [String: Bool] = [:]
        try await settle("生产音量滑块挂载", failureDetails: {
            windowReadiness() + ", " + mountReadiness.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        }) {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            host.displayIfNeeded()
            let slider = findSlider(host)
            mountReadiness = ["slider": slider != nil, "cell": slider?.cell is NSSliderCell]
            guard let slider, let cell = slider.cell as? NSSliderCell else { return false }
            slider.displayIfNeeded()
            let knob = cell.knobRect(flipped: slider.isFlipped)
            let bar = cell.barRect(flipped: slider.isFlipped)
            let start = NSPoint(x: knob.midX + 2, y: knob.midY)
            // 原生几何就绪后仍需等宿主命中区域更新，再由窗口派发鼠标。
            let hit = host.hitTest(slider.convert(start, to: host.superview))
            mountReadiness.merge([
                "key": window.isKeyWindow, "unoccluded": window.occlusionState.contains(.visible),
                "valueReady": slider.integerValue == 40, "knobWidth": knob.width > 0, "knobHeight": knob.height > 0,
                "barReady": bar.width > knob.width, "knobInBounds": slider.bounds.contains(NSPoint(x: knob.midX, y: knob.midY)),
                "hit": hit === slider
            ]) { _, latest in latest }
            return mountReadiness.values.allSatisfy { $0 }
        }
        let slider = findSlider(host)!
        let identity = ObjectIdentifier(slider)
        // fittingSize 会触发 SwiftUI 测量；先完成测量和绘制，再跨三个30fps周期确认基线。
        _ = host.fittingSize
        var previousFrame: NSRect?
        var previousBounds: NSRect?
        var previousKnob: NSRect?
        var previousBar: NSRect?
        var previousSize: NSSize?
        var stableSince = ProcessInfo.processInfo.systemUptime
        try await settle("音量控件完成测量后实例、几何及命中应稳定") {
            let size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            host.displayIfNeeded()
            slider.displayIfNeeded()
            guard findSlider(host) === slider, window.isKeyWindow, window.occlusionState.contains(.visible), slider.isEnabled,
                  slider.integerValue == 40, let cell = slider.cell as? NSSliderCell else {
                stableSince = ProcessInfo.processInfo.systemUptime
                return false
            }
            let knob = cell.knobRect(flipped: slider.isFlipped)
            let bar = cell.barRect(flipped: slider.isFlipped)
            let start = NSPoint(x: knob.midX + 2, y: knob.midY)
            guard knob.width > 0, knob.height > 0, bar.width > knob.width,
                  host.hitTest(slider.convert(start, to: host.superview)) === slider else {
                stableSince = ProcessInfo.processInfo.systemUptime
                return false
            }
            if previousFrame != slider.frame || previousBounds != slider.bounds || previousKnob != knob
                || previousBar != bar || previousSize != size {
                previousFrame = slider.frame
                previousBounds = slider.bounds
                previousKnob = knob
                previousBar = bar
                previousSize = size
                stableSince = ProcessInfo.processInfo.systemUptime
                return false
            }
            return ProcessInfo.processInfo.systemUptime - stableSince >= 0.1
        }
        let originalFrame = slider.frame
        let originalSize = previousSize!
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
        precondition(slider.focusRingType == .none, "鼠标操作只显示原生拇指，不叠加键盘焦点环")
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
        precondition(slider.focusRingType == .default, "鼠标之后使用方向键应恢复系统焦点提示")
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
        precondition(slider.focusRingType == .none, "卸载后不得保留旧键盘焦点环")
        slider.mouseUp(with: event(.leftMouseUp, end))
        let finalCommands = await service.commands
        precondition(finalCommands.count == 4 && model.pendingVolume == nil, "卸载后的松手不得提交旧手势")
        print("PASS 原生音量持续拖动实际变化、松手一次提交、慢读回与连续输入不回跳、固定布局、键盘/辅助功能、边界裁剪与卸载取消")
    }

    private static func checkModeChanges() async throws {
        let service = OptionsCheckService()
        let model = PlaybackOptionsModel(service: service)
        let mainControl = UUID()
        model.appear(mainControl)
        model.toggleShuffle()
        model.cycleRepeat()
        precondition(model.pendingShuffleChange && model.pendingRepeatChange, "首次读取期间点击应保留意图")
        try await settle("模式首读") { await service.commands == [.read] }
        await service.completeNext()
        try await settle("初读后真正执行随机开启") { await service.commands == [.read, .shuffle(true)] }
        precondition(model.snapshot.shuffleEnabled == false, "设置完成前不假定随机已经开启")
        await service.completeNext()
        try await settle("随机之后串行切换循环") { await service.commands.last == .repeatMode(.all) }
        await service.completeNext()
        try await settle("两个模式均真实确认") {
            !model.isBusy && model.snapshot.shuffleEnabled == true && model.snapshot.repeatMode == .all
                && !model.pendingShuffleChange && !model.pendingRepeatChange
        }

        let floatingControl = UUID()
        model.appear(floatingControl)
        try await settle("主窗仍可见时新浮窗也读取选项") { await service.commands.last == .read }
        await service.completeNext(reported: .init(volume: 40, shuffleEnabled: false, repeatMode: .all))
        try await settle("新浮窗可更新外部修改") { !model.isBusy && model.snapshot.shuffleEnabled == false }
        model.cycleRepeat()
        try await settle("点击循环前先读取 Music 当前值") { await service.commands.last == .read }
        await service.completeNext(reported: .init(volume: 40, shuffleEnabled: false, repeatMode: .one))
        try await settle("以刚读回的单曲循环决定关闭，而非缓存的列表循环") {
            await service.commands.last == .repeatMode(.off)
        }
        await service.completeNext()
        try await settle("关闭循环确认") { !model.isBusy && model.snapshot.repeatMode == .off }

        model.toggleShuffle()
        model.setVolume(73)
        model.cycleRepeat()
        try await settle("模式重读请求送出") { await service.commands.last == .read }
        await service.completeNext(failing: true)
        try await settle("失败后待提交音量仍能执行") { await service.commands.last == .volume(73) }
        precondition(model.shuffleErrorMessage != nil && model.repeatErrorMessage != nil
                     && !model.pendingShuffleChange && !model.pendingRepeatChange,
                     "播放方式失败不能被后续音量请求清掉或误作成功")
        await service.completeNext()
        try await settle("音量成功后模式失败仍可发现") { !model.isBusy && model.shuffleErrorMessage != nil }
        model.toggleShuffle()
        try await settle("失败后的点击保留切换意图并重新读取") { await service.commands.last == .read }
        await service.completeNext()
        try await settle("失败后的下一次点击真正切换") { await service.commands.last == .shuffle(true) }
        await service.completeNext()
        try await settle("重试切换确认") { !model.isBusy && model.shuffleErrorMessage == nil && model.snapshot.shuffleEnabled == true }

        model.toggleShuffle()
        try await settle("未知状态前读取送出") { await service.commands.last == .read }
        await service.completeNext(reported: .init(volume: 73, repeatMode: .off))
        try await settle("仍然未知时明确告知未切换") {
            !model.isBusy && !model.pendingShuffleChange && model.shuffleErrorMessage?.contains("未执行切换") == true
        }
        let beforeCancellation = await service.commands.count
        model.cycleRepeat()
        try await settle("取消前模式读取送出") { await service.commands.count == beforeCancellation + 1 }
        model.cancel()
        await service.completeNext(reported: .init(volume: 73, shuffleEnabled: false, repeatMode: .one))
        try await Task.sleep(for: .milliseconds(30))
        let cancelledCommands = await service.commands
        precondition(cancelledCommands.count == beforeCancellation + 1 && !model.isBusy && !model.pendingRepeatChange,
                     "生命周期取消后不得执行迟到的循环写入")
        precondition(model.snapshot.repeatMode == .off, "取消后旧读取不能覆盖新生命周期")
        print("PASS 首读点击排队、共享控件新显示刷新、点击前读取当前值、失败保留、真正重试、未知和生命周期取消")
    }

    private static func checkNativeModeHelp() async throws {
        let service = OptionsCheckService()
        let model = PlaybackOptionsModel(service: service)
        let host = NSHostingView(rootView: HStack {
            PlaybackShuffleButton(model: model)
            PlaybackRepeatButton(model: model)
        }.padding(20).environment(\.colorScheme, .dark))
        let panel = NSPanel(contentRect: NSRect(x: 380, y: 160, width: 160, height: 88),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.level = .floating
        panel.orderFrontRegardless()
        defer { panel.close() }
        try await settle("非激活面板读取模式") { await service.commands == [.read] }
        try await settle("首读期间未知状态与点击行为可从原生提示发现") {
            host.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            let helps = nativeHelpViews(host)
            return helps.count == 2 && helps.allSatisfy {
                $0.toolTip?.contains("状态未知") == true
                    && $0.toolTip?.contains("点击后读取状态并切换") == true
                    && $0.toolTip?.contains("正在读取或调整其他播放选项") == true
            }
        }
        await service.completeNext()
        try await settle("非激活面板原生提示挂载") {
            host.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            let helps = nativeHelpViews(host)
            return !model.isBusy && helps.count == 2 && helps.allSatisfy { $0.bounds.width > 0 }
        }
        var helps = nativeHelpViews(host)
        let shuffle = helps.first { $0.toolTip?.hasPrefix("随机播放：") == true }!
        let repeating = helps.first { $0.toolTip?.hasPrefix("循环播放：") == true }!
        precondition(shuffle.toolTip?.contains("点击开启随机播放") == true
                     && repeating.toolTip?.contains("点击切换为列表循环") == true,
                     "悬停提示必须同时说明功能、当前状态和下一次操作")
        let center = NSPoint(x: shuffle.bounds.midX, y: shuffle.bounds.midY)
        precondition(shuffle.hitTest(center) == nil, "原生 tooltip 不能拦截按钮命中")
        let location = shuffle.convert(center, to: nil)
        let event: @MainActor @Sendable (NSEvent.EventType) -> NSEvent = { type in
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        // SwiftUI 按钮可进入 AppKit 跟踪循环；用其事件队列释放，避免 down 阻塞后续 up。
        let release = Timer(timeInterval: 0.04, repeats: false) { _ in
            MainActor.assumeIsolated { NSApplication.shared.postEvent(event(.leftMouseUp), atStart: false) }
        }
        RunLoop.main.add(release, forMode: .common)
        RunLoop.main.add(release, forMode: .eventTracking)
        panel.sendEvent(event(.leftMouseDown))
        try await Task.sleep(for: .milliseconds(100))
        try await settle("非激活面板点击确实送出读取") { await service.commands.last == .read && model.pendingShuffleChange }
        try await settle("等待确认期间原生悬停提示可读") {
            host.layoutSubtreeIfNeeded()
            return nativeHelpViews(host).first { $0.toolTip?.hasPrefix("随机播放：") == true }?.toolTip?
                .contains("正在切换，等待「音乐」App 确认") == true
        }
        await service.completeNext()
        try await settle("非激活面板点击确实执行切换") { await service.commands.last == .shuffle(true) }
        await service.completeNext()
        try await settle("读回后原生悬停提示随状态更新") {
            host.layoutSubtreeIfNeeded()
            helps = nativeHelpViews(host)
            return helps.first { $0.toolTip?.hasPrefix("随机播放：") == true }?.toolTip?.contains("点击关闭随机播放") == true
        }
        print("PASS 非激活浮窗原生 tooltip 功能/当前状态/下一动作、提示不吞点击和确认后更新")
    }

    private static func nativeHelpViews(_ view: NSView) -> [NSView] {
        (view.toolTip == nil ? [] : [view]) + view.subviews.flatMap(nativeHelpViews)
    }

    private static func settle(_ message: String, failureDetails: (() -> String)? = nil, _ predicate: () async -> Bool) async throws {
        for _ in 0..<250 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure(failureDetails.map { message + ": " + $0() } ?? message)
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
