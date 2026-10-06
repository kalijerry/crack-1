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

extension VisualOdometryAligner {
    /// 当前对齐的变换；还没对齐时为 nil。
    public var transform: MapARTransform? {
        phi.map { MapARTransform(pRef: pRef, aRef: aRef, phi: $0) }
    }
}
