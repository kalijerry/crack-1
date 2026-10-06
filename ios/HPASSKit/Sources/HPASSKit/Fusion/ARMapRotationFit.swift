import Foundation

/// 从「同一时刻的 ARKit 位置 a 和地图位置 m」这些点对，估 ARKit → 地图的旋转 φ（map ≈ p + R(φ)(a − a0)）。
///
/// 用在不知道起始朝向的场合：自动定位（冷启动）收敛后，地磁给出地图位置，ARKit 给出自己的位置，
/// 两段轨迹一比就知道差多少度。最小二乘（二维 Procrustes）：φ = atan2(Σ a×m, Σ a·m)，a、m 都去掉均值。
/// 要求最近一段路有足够的长度（默认 3 m）且不是原地打转。
public final class ARMapRotationFit {
    /// 只用最近这么长路程（cm）的点对
    public var windowCm = 1000.0
    /// 至少要这么长（cm）才给结果
    public var minSpanCm = 300.0
    /// 点对之间至少隔多远（cm）
    public var stepCm = 20.0

    private var pairs: [(a: Point2, m: Point2, s: Double)] = []
    private var path = 0.0

    public init() {}

    public func reset() {
        pairs.removeAll()
        path = 0
    }

    public func add(ar a: Point2, map m: Point2) {
        if let last = pairs.last {
            let d = a.distance(to: last.a)
            guard d >= stepCm else { return }
            guard d < 300 else { reset(); pairs.append((a, m, 0)); return }   // ARKit 坐标系重置
            path += d
        }
        pairs.append((a, m, path))
        while let f = pairs.first, path - f.s > windowCm { pairs.removeFirst() }
    }

    /// 窗口里 ARKit 轨迹的外接尺寸（cm）
    public var spanCm: Double {
        guard let f = pairs.first, let l = pairs.last else { return 0 }
        return f.a.distance(to: l.a)
    }

    /// ARKit → 地图的旋转（弧度）；数据不够时为 nil。
    public var phi: Double? {
        guard pairs.count >= 8, spanCm >= minSpanCm else { return nil }
        let n = Double(pairs.count)
        let ca = pairs.reduce(Point2.zero) { $0 + $1.a } * (1 / n)
        let cm = pairs.reduce(Point2.zero) { $0 + $1.m } * (1 / n)
        var sDot = 0.0, sCross = 0.0
        for p in pairs {
            let a = p.a - ca, m = p.m - cm
            sDot += a.dot(m)
            sCross += a.x * m.y - a.y * m.x
        }
        guard sDot * sDot + sCross * sCross > 1 else { return nil }
        return atan2(sCross, sDot)
    }
}
