import Foundation

/// 地图坐标 ↔ ARKit 世界坐标。
///
/// ARKit 世界系：重力对齐，x 右、y 上、z 朝向观察者。水平面取 (x, z)，与地图 (x, y)（y 向下）同手性，
/// 所以两者只差一个平面旋转 φ 和一个平移：
///
///     map = pRef + R(φ) · (a − aRef)
///
/// 这与 `VisualOdometryAligner` 的定义完全一致（`aligner.transform` 直接给出本结构）。
public struct MapARTransform: Equatable {
    /// 锚点：地图坐标（cm）。
    public var pRef: Point2
    /// 同一时刻的 ARKit (x, z)（cm）。
    public var aRef: Point2
    /// 旋转（弧度）：ARKit → 地图。
    public var phi: Double

    public init(pRef: Point2, aRef: Point2, phi: Double) {
        self.pRef = pRef
        self.aRef = aRef
        self.phi = phi
    }

    /// 地图坐标（cm）→ ARKit (x, z)（cm）。
    public func toAR(_ p: Point2) -> Point2 {
        let d = p - pRef
        let c = cos(phi), s = sin(phi)                  // R(−φ)
        return Point2(aRef.x + d.x * c + d.y * s, aRef.y - d.x * s + d.y * c)
    }

    /// ARKit (x, z)（cm）→ 地图坐标（cm）。
    public func toMap(_ a: Point2) -> Point2 {
        let d = a - aRef
        let c = cos(phi), s = sin(phi)                  // R(φ)
        return Point2(pRef.x + d.x * c - d.y * s, pRef.y + d.x * s + d.y * c)
    }

    /// 给 SceneKit 用：把「场景坐标 = 地图 cm / 100」的内容放进 ARKit 世界。
    /// 根节点绕 +y 转 `sceneRotationY`，再平移 `sceneTranslationM`（米）。
    /// SceneKit 绕 +y 转 α：(x, z) → (x cos α + z sin α, −x sin α + z cos α)，恰好等于 R(−φ)，所以 α = φ。
    public var sceneRotationY: Double { phi }

    public var sceneTranslationM: (x: Double, z: Double) {
        let px = pRef.x / 100, pz = pRef.y / 100
        let c = cos(phi), s = sin(phi)
        return (aRef.x / 100 - (px * c + pz * s), aRef.y / 100 - (-px * s + pz * c))
    }
}

// MARK: - 刚体变换代数
//
// 同一个结构也用来表示「某个扫描段的 map.json 坐标 → 合成地图坐标」（把「AR 一侧」当成源坐标系）。
// 扫描段入图的变换 = 段坐标 →（段 arAlign 的逆）→ AR →（地图 arAlign）→ 地图，
// 即 `segAlign.inverse.compose(mapAlign)`，都用下面几个方法表达，不手写三角函数。
extension MapARTransform {
    /// 恒等变换
    public static let identity = MapARTransform(pRef: .zero, aRef: .zero, phi: 0)

    /// 逆变换：`inverse.toMap(p) == toAR(p)`
    public var inverse: MapARTransform { MapARTransform(pRef: aRef, aRef: pRef, phi: -phi) }

    /// 先自己、后 `next`：`compose(next).toMap(x) == next.toMap(toMap(x))`
    public func compose(_ next: MapARTransform) -> MapARTransform {
        MapARTransform(pRef: next.toMap(pRef), aRef: aRef, phi: phi + next.phi)
    }

    /// 地图原点平移之后（地图坐标整体 + offset）同一个映射的写法
    public func translated(by offset: Point2) -> MapARTransform {
        MapARTransform(pRef: pRef + offset, aRef: aRef, phi: phi)
    }

    /// 旋转角（度，归一到 (−180, 180]）
    public var angleDeg: Double { MapARTransform.wrapDeg(phi * 180 / Double.pi) }

    /// 只转方向（不平移）
    public func rotate(_ v: Point2) -> Point2 {
        let c = cos(phi), s = sin(phi)
        return Point2(v.x * c - v.y * s, v.x * s + v.y * c)
    }

    /// 角度归一到 (−180, 180]
    public static func wrapDeg(_ d: Double) -> Double {
        var d = d.truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 }
        if d > 180 { d -= 360 }
        return d
    }

    /// 两个变换是否几乎一样：源坐标里 aRef 附近 `extentCm` 范围的几个点映射后距离都不超过 tolCm
    public func isClose(to o: MapARTransform, tolCm: Double, extentCm: Double = 1000) -> Bool {
        for p in [aRef, aRef + Point2(extentCm, 0), aRef + Point2(0, extentCm)] where toMap(p).distance(to: o.toMap(p)) > tolCm {
            return false
        }
        return true
    }
}

extension VisualOdometryAligner {
    /// 当前对齐的变换；还没对齐时为 nil。
    public var transform: MapARTransform? {
        phi.map { MapARTransform(pRef: pRef, aRef: aRef, phi: $0) }
    }
}
