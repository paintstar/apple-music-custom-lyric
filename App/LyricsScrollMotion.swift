import AppKit
import QuartzCore

// 歌词的显示帧、有限运动与等待提示；文本坐标/浏览交互保留在 LyricsScrollView。
@MainActor
extension LyricsScrollView {
    func scroll(to lineId: UUID, animated: Bool, previousLineId: UUID? = nil) {
        guard let destination = offset(for: lineId) else { return }
        let current = contentView.bounds.minY
        let distance = abs(destination - current)
        guard animated, window != nil else {
            cancelAnimation()
            setScrollOffset(destination)
            textLayout.finishEmphasis()
            return
        }
        // 视口/播放采样会重发同一锚点；沿用当前运动，不能重新起步或重播淡出。
        if let motion = scrollMotion {
            if motion.target == destination { return }
        } else if jump?.destination == destination { return }
        motionOmega = LyricsMotionStyle.response(forDistance: distance, viewport: contentSize.height)
        if let active = jump, !active.positioned {
            // 远距淡出尚未落位时，新组继续改写终点，不能突然恢复全亮并扫过几屏。
            jump = LyricsJumpTransition(destination: destination, elapsed: active.elapsed, initialAlpha: active.initialAlpha)
            ensureDisplayLink()
            return
        }
        guard distance > 0.5 else {
            scrollMotion = nil
            setScrollOffset(destination)
            textLayout.finishEmphasis()
            if jump == nil { cancelAnimation() }
            return
        }
        // 大幅 seek 不把中间几屏推过眼前。布局保持原位，短淡出后准确落位再淡入。
        let neighboring = textLayout.areNeighboringAnchors(previousLineId, lineId)
        if !neighboring, distance > contentSize.height * LyricsMotionStyle.jumpViewportFraction {
            scrollMotion = nil
            jump = LyricsJumpTransition(destination: destination, initialAlpha: canvas.alphaValue)
        } else {
            // 远距落位后的首个相邻组可一边完成淡入、一边接续位移，避免亮度突跳。
            if jump?.positioned != true { canvas.alphaValue = 1 }
            var motion = scrollMotion ?? LyricsScalarMotion(position: current)
            motion.retarget(destination, omega: motionOmega)
            scrollMotion = motion
        }
        ensureDisplayLink()
    }

    func ensureDisplayLink() {
        guard frameLink == nil, window?.isVisible == true, window?.occlusionState.contains(.visible) == true,
              isScrollAnimating || textLayout.hasActiveEmphasis || waitingNeedsFrames else { return }
        let link = displayLink(target: displayLinkTarget, selector: #selector(LyricsDisplayLinkTarget.tick(_:)))
        lastFrameTime = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    func advanceFrame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let delta = max(0, now - (lastFrameTime ?? now))
        lastFrameTime = now
        if var transition = jump {
            transition.elapsed += delta
            if transition.elapsed < LyricsMotionStyle.jumpFadeOut {
                canvas.alphaValue = transition.initialAlpha * max(0, 1 - transition.elapsed / LyricsMotionStyle.jumpFadeOut)
            } else {
                if !transition.positioned {
                    setScrollOffset(transition.destination)
                    textLayout.finishEmphasis()
                    transition.positioned = true
                }
                let progress = min(1, (transition.elapsed - LyricsMotionStyle.jumpFadeOut) / LyricsMotionStyle.jumpFadeIn)
                canvas.alphaValue = progress * progress * (3 - 2 * progress)
            }
            jump = transition.elapsed >= LyricsMotionStyle.jumpFadeOut + LyricsMotionStyle.jumpFadeIn ? nil : transition
            if jump == nil { canvas.alphaValue = 1 }
        }
        if var motion = scrollMotion {
            motion.advance(by: delta, omega: motionOmega, tolerance: 0.18)
            setScrollOffset(motion.position)
            scrollMotion = motion.isSettled ? nil : motion
        }
        textLayout.advanceEmphasis(by: delta, omega: LyricsMotionStyle.omega)
        updateWaitingIndicator()
        if !isScrollAnimating, !textLayout.hasActiveEmphasis, !waitingNeedsFrames { stopDisplayLink() }
    }

    /// 用户阅读只取消自动位移；文字提亮与等待提示仍可更新，绝不抢回阅读位置。
    func cancelAnimation() {
        scrollMotion = nil
        jump = nil
        canvas.alphaValue = 1
        if !textLayout.hasActiveEmphasis, !waitingNeedsFrames { stopDisplayLink() }
    }

    func stopDisplayLink() {
        frameLink?.invalidate()
        frameLink = nil
        lastFrameTime = nil
    }

    func stopAllFrames() {
        cancelAnimation()
        textLayout.finishEmphasis()
        stopDisplayLink()
    }

    func updateWaitingIndicator() {
        guard let value = configuration, let interval = value.waitingInterval else {
            waitingIndicator.configure(interval: nil, positionMs: nil, reduceMotion: true)
            waitingNeedsFrames = false
            return
        }
        let rowFrame: NSRect?
        if let id = interval.anchorLineId, let index = textLayout.rowIndices[id] {
            rowFrame = textLayout.rows[index].frame
        } else {
            rowFrame = textLayout.preludeFrame
        }
        guard let rowFrame else { waitingIndicator.isHidden = true; waitingNeedsFrames = false; return }
        // 独立绘制在已有文字槽，既不改变 document height，也不拦截文本选择事件。
        waitingIndicator.frame = NSRect(
            x: rowFrame.minX, y: rowFrame.minY + textTopInset,
            width: min(contentSize.width, 90), height: max(24, rowFrame.height)
        )
        let position = value.waitingPosition?()
        waitingIndicator.configure(interval: interval, positionMs: position, reduceMotion: value.reduceMotion)
        waitingNeedsFrames = !value.reduceMotion && value.waitingIsPlaying && position != nil && position! < interval.endMs
    }

}

struct LyricsJumpTransition {
    let destination: CGFloat
    var elapsed: TimeInterval = 0
    var positioned = false
    let initialAlpha: CGFloat
}

/// displayLink 会持有 target；弱转发避免离开视图后反向保活整个歌词面板。
@MainActor
final class LyricsDisplayLinkTarget: NSObject {
    weak var owner: LyricsScrollView?
    @objc func tick(_ link: CADisplayLink) { owner?.advanceFrame(link) }
}

/// 一组共享的视觉参数；更长的相邻歌词适度放缓，不因更高刷新率改变运动速度。
enum LyricsMotionStyle {
    static let omega = 18.0
    static let jumpViewportFraction = 0.85
    static let jumpFadeOut = 0.085
    static let jumpFadeIn = 0.16
    static func response(forDistance distance: CGFloat, viewport: CGFloat) -> Double {
        // 常见短句维持敏捷；跨大半屏的长句降低峰值速度，末端仍用同一无回弹收敛。
        let fraction = Double(distance / max(1, viewport))
        return max(8, omega / (1 + 1.3 * fraction))
    }
}

/// 临界阻尼解析解，无弹簧回弹；同向改目标保留速度，反向立即停止旧方向。
/// 不用固定步长积分，掉帧或 120Hz 屏幕下仍得到相同轨迹。
struct LyricsScalarMotion {
    private(set) var position: Double
    private(set) var velocity = 0.0
    private(set) var target: Double
    var isSettled: Bool { position == target && velocity == 0 }

    init(position: Double) { self.position = position; target = position }

    mutating func retarget(_ destination: Double, omega: Double) {
        target = destination
        let distance = target - position
        if velocity * distance <= 0 { velocity = 0 }
        // 保持单调：当新目标很近，限速以免冲过目标后再拉回来。
        velocity = (distance < 0 ? -1 : 1) * min(abs(velocity), omega * abs(distance))
    }

    mutating func advance(by delta: TimeInterval, omega: Double, tolerance: Double) {
        guard !isSettled else { return }
        let error = position - target
        let coefficient = velocity + omega * error
        let decay = exp(-omega * delta)
        position = target + (error + coefficient * delta) * decay
        velocity = (velocity - omega * coefficient * delta) * decay
        if abs(position - target) < tolerance, abs(velocity) < tolerance * omega { finish() }
    }

    mutating func finish() { position = target; velocity = 0 }
}
