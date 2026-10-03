import Foundation

/// 通道约束的修正结果（单位 cm）。
struct FusionCorridorProjection {
    /// 修正后的目标点。
    var point: Point2
    /// 从原点到目标点的距离（cm），用于判断这次修正是否「合理」。
    var distanceCm: Double
}

/// 由 `CrossSegment`（通道中心线 + lineWidth 宽度，单位 cm）构建的可行走区域。
///
/// 几何模型：每条通道取「中心线 ⊕ 半径 h 的圆盘」，即 **胶囊 / stadium**
/// （中间是矩形，两端是半圆帽），h = lineWidth/2 − corridorMargin。
///
/// 为什么用胶囊而不是严格矩形：通道在交叉口是两条线段的端点相接，
/// 严格矩形之间会留下三角形缝隙，人走到拐角时会被错误地往回推、形成「卡角」。
/// 胶囊的端帽正好向外延伸半个通道宽，自然覆盖交叉口。
/// 需要严格矩形（比如绘制调试图）时用 `polygon(at:marginCm:)`。
///
/// 线程约定：不可变数据 + 纯函数，天然安全；但仍只在 FusionEngine 的串行队列上使用。
final class FusionCorridorMap {

    /// 半宽下限（cm）。lineWidth 很小或 margin 很大时，避免算出零/负宽度导致「哪里都不合法」。
    /// 20 cm ≈ 人体站立所需的最小横向余量。
    private let minHalfWidthCm: Double = 20.0
    /// 投影落点相对边界的内缩比例。0.95 让点落在边界内侧一点，
    /// 避免下一帧因浮点误差又被判成越界、反复抖动。
    private let insetFactor: Double = 0.95

    let segments: [CrossSegment]

    init(_ segments: [CrossSegment]) {
        self.segments = segments
    }

    var isEmpty: Bool { segments.isEmpty }

    /// 某条通道在给定 margin 下的有效半宽（cm）。
    func halfWidth(_ seg: CrossSegment, marginCm: Double) -> Double {
        max(seg.lineWidth / 2.0 - max(marginCm, 0.0), minHalfWidthCm)
    }

    /// 点是否落在任一通道内。
    func contains(_ p: Point2, marginCm: Double) -> Bool {
        for seg in segments {
            let c = FusionCorridorMap.closestPoint(on: seg, to: p)
            if p.distance(to: c) <= halfWidth(seg, marginCm: marginCm) { return true }
        }
        return false
    }

    /// 点在任一通道内（或通道列表为空）→ 返回 nil，表示不需要修正。
    /// 否则投影到「越界最少」的那条通道的边界内侧。
    func project(_ p: Point2, marginCm: Double) -> FusionCorridorProjection? {
        guard !segments.isEmpty else { return nil }
        guard p.x.isFinite && p.y.isFinite else { return nil }

        var bestOver = Double.greatestFiniteMagnitude
        var best: FusionCorridorProjection?

        for seg in segments {
            let c = FusionCorridorMap.closestPoint(on: seg, to: p)
            let h = halfWidth(seg, marginCm: marginCm)
            let d = p.distance(to: c)
            if d <= h { return nil }           // 已经在某条通道内
            let over = d - h
            if over < bestOver {
                bestOver = over
                // d > h ≥ 20，不会除零
                let dir = (p - c) * (1.0 / d)
                let target = c + dir * (h * insetFactor)
                best = FusionCorridorProjection(point: target, distanceCm: p.distance(to: target))
            }
        }
        return best
    }

    /// 调试 / 绘制用：第 index 条通道的矩形（不含端帽）四个角点，顺序为
    /// a+n, b+n, b−n, a−n（n 为中心线的左法向 × 半宽）。index 越界或线段退化时返回空数组。
    func polygon(at index: Int, marginCm: Double) -> [Point2] {
        guard index >= 0 && index < segments.count else { return [] }
        let seg = segments[index]
        let ab = seg.b - seg.a
        let len = ab.length
        guard len > 1e-9 else { return [] }
        let n = Point2(-ab.y, ab.x) * (1.0 / len)
        let h = halfWidth(seg, marginCm: marginCm)
        return [seg.a + n * h, seg.b + n * h, seg.b - n * h, seg.a - n * h]
    }

    /// 线段上距 p 最近的点。退化线段（a == b）当作单点。
    private static func closestPoint(on seg: CrossSegment, to p: Point2) -> Point2 {
        let ab = seg.b - seg.a
        let len2 = ab.dot(ab)
        guard len2 > 1e-9 else { return seg.a }
        let t = FusionMath.clamp((p - seg.a).dot(ab) / len2, 0.0, 1.0)
        return seg.a + ab * t
    }
}
