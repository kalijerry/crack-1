import Foundation
import HPASSKit
import SceneKit

#if canImport(UIKit)
import UIKit
typealias S3Color = UIColor
#else
import AppKit
typealias S3Color = NSColor
#endif

/// 门店的 3D 场景（SceneKit）：地板、实物货架、通道采集进度、点位、磁场热力图、轨迹和当前位置。
///
/// 坐标：地图 (x, y) 厘米 → 场景 (x, 0, y) 米。俯视时 x 向右、z 向下，与地图的 x 右、y 下一致，不用翻转。
/// 场景不依赖 UIKit，所以能在 Mac 上离屏渲染做回归检查。只在主线程使用。
final class Store3DScene {
    enum CameraMode { case overview, top, follow }

    let scene = SCNScene()
    let cameraNode = SCNNode()

    private let world = SCNNode()
    private let shelvesNode = SCNNode()
    private let coverageNode = SCNNode()
    private let pointsNode = SCNNode()
    private let trailNode = SCNNode()
    private let fieldNode = SCNNode()
    private let avatarRoot = SCNNode()
    private let ringNode = SCNNode()

    private let widthM: Double
    private let heightM: Double
    private let map: StoreMap
    /// 有内容的范围（米）：货架和通道的外接矩形。相机按它取景，不按整张地图（地图左边常有大片空白）。
    private let content: (minX: Double, minZ: Double, maxX: Double, maxZ: Double)
    private var avatarPos = SCNVector3(0, 0, 0)
    private var avatarHeading = 0.0

    /// 实物货架的显示高度（米）。地图里没有高度数据，默认 1.8 m；激光雷达量到真实高度之后再改。
    private(set) var shelfHeightM = 1.8

    init(map: StoreMap) {
        self.map = map
        widthM = max(map.width, 100) / 100
        heightM = max(map.height, 100) / 100
        var minX = Double.infinity, minZ = Double.infinity, maxX = -Double.infinity, maxZ = -Double.infinity
        func grow(_ x: Double, _ y: Double) { minX = min(minX, x); maxX = max(maxX, x); minZ = min(minZ, y); maxZ = max(maxZ, y) }
        for s in map.physicalShelves { let r = max(s.width, s.height) / 2; grow(s.x - r, s.y - r); grow(s.x + r, s.y + r) }
        for c in map.crosses { grow(c.a.x, c.a.y); grow(c.b.x, c.b.y) }
        if minX > maxX { minX = 0; minZ = 0; maxX = map.width; maxZ = map.height }
        content = (max(minX, 0) / 100, max(minZ, 0) / 100, min(maxX, map.width) / 100, min(maxZ, map.height) / 100)

        scene.rootNode.addChildNode(world)
        for n in [shelvesNode, coverageNode, pointsNode, trailNode, fieldNode, avatarRoot] { world.addChildNode(n) }
        scene.background.contents = S3Color(white: 0.94, alpha: 1)

        buildFloor()
        rebuildShelves()
        buildLights()
        buildAvatar()

        let cam = SCNCamera()
        cam.zNear = 0.1
        cam.zFar = 3000
        cam.fieldOfView = 50
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
        setCamera(.overview)
    }

    // MARK: 静态部分

    private func buildFloor() {
        let floor = SCNBox(width: widthM, height: 0.02, length: heightM, chamferRadius: 0)
        floor.firstMaterial = Self.material(S3Color(white: 0.985, alpha: 1))
        let n = SCNNode(geometry: floor)
        n.position = SCNVector3(widthM / 2, -0.01, heightM / 2)
        world.addChildNode(n)
    }

    func setShelfHeight(_ m: Double) {
        guard abs(m - shelfHeightM) > 0.01 else { return }
        shelfHeightM = m
        rebuildShelves()
    }

    private func rebuildShelves() {
        shelvesNode.childNodes.forEach { $0.removeFromParentNode() }
        let mat = Self.material(S3Color(white: 0.58, alpha: 1))
        let holder = SCNNode()
        for s in map.physicalShelves {
            let box = SCNBox(width: s.width / 100, height: shelfHeightM, length: s.height / 100, chamferRadius: 0)
            box.firstMaterial = mat
            let n = SCNNode(geometry: box)
            n.position = SCNVector3(s.x / 100, shelfHeightM / 2, s.y / 100)
            // 地图旋转：u = (cos r, sin r) 沿 width，顺时针（y 向下）。绕场景 +y 轴转 −r 才对得上
            n.eulerAngles = SCNVector3(0, -s.rotation * Double.pi / 180, 0)
            holder.addChildNode(n)
        }
        // 把一千多个盒子合成一个几何体，一次绘制
        shelvesNode.addChildNode(holder.flattenedClone())
    }

    private func buildLights() {
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 650
        scene.rootNode.addChildNode(amb)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 800
        sun.eulerAngles = SCNVector3(-Double.pi / 3, Double.pi / 5, 0)
        scene.rootNode.addChildNode(sun)
    }

    // MARK: 通道采集进度

    /// 没采的段：一条淡细线；采过的段：半透明绿带 + 中间的线。
    /// 线：绿色实线 = 孤立的一段，黑色虚线 = 已经和别的路段关联起来。
    func setCoverage(crosses: [CrossSegment], states: [[CoverageState]], binCm: Double) {
        coverageNode.childNodes.forEach { $0.removeFromParentNode() }
        let holder = SCNNode()
        let colored = states.count == crosses.count
        let band = Self.material(S3Color(red: 0.2, green: 0.78, blue: 0.35, alpha: 0.42), lit: false)
        let green = Self.material(S3Color(red: 0.1, green: 0.7, blue: 0.2, alpha: 1), lit: false)
        let black = Self.material(S3Color(white: 0.05, alpha: 1), lit: false)
        let faint = Self.material(S3Color(red: 0.2, green: 0.4, blue: 0.9, alpha: 0.22), lit: false)
        let thin = Self.material(S3Color(white: 0.45, alpha: 0.5), lit: false)

        for (i, c) in crosses.enumerated() {
            let len = c.a.distance(to: c.b)
            guard len > 1 else { continue }
            let dir = Point2((c.b.x - c.a.x) / len, (c.b.y - c.a.y) / len)
            let yaw = -atan2(dir.y, dir.x)
            func piece(from s0: Double, to s1: Double, width: Double, y: Double, height: Double, material: SCNMaterial) {
                let l = (s1 - s0) / 100
                guard l > 0.001 else { return }
                let box = SCNBox(width: l, height: height, length: width / 100, chamferRadius: 0)
                box.firstMaterial = material
                let n = SCNNode(geometry: box)
                let mid = (s0 + s1) / 2
                n.position = SCNVector3((c.a.x + dir.x * mid) / 100, y, (c.a.y + dir.y * mid) / 100)
                n.eulerAngles = SCNVector3(0, yaw, 0)
                holder.addChildNode(n)
            }
            guard colored else {
                piece(from: 0, to: len, width: c.lineWidth, y: 0.012, height: 0.004, material: faint)
                continue
            }
            let bins = states[i]
            var k = 0
            while k < bins.count {
                let st = bins[k]
                var e = k
                while e + 1 < bins.count && bins[e + 1] == st { e += 1 }
                let s0 = Double(k) * binCm, s1 = min(Double(e + 1) * binCm, len)
                switch st {
                case .none:
                    piece(from: s0, to: s1, width: 8, y: 0.012, height: 0.004, material: thin)
                case .isolated:
                    piece(from: s0, to: s1, width: c.lineWidth, y: 0.012, height: 0.004, material: band)
                    piece(from: s0, to: s1, width: 22, y: 0.02, height: 0.006, material: green)
                case .linked:
                    piece(from: s0, to: s1, width: c.lineWidth, y: 0.012, height: 0.004, material: band)
                    // 黑色虚线：每 80 cm 画 40 cm
                    var d = s0
                    while d < s1 {
                        piece(from: d, to: min(d + 40, s1), width: 18, y: 0.02, height: 0.006, material: black)
                        d += 80
                    }
                }
                k = e + 1
            }
        }
        coverageNode.addChildNode(holder.flattenedClone())
    }

    // MARK: 点位

    func setPoints(_ points: [MarkPoint], highlight: String? = nil) {
        pointsNode.childNodes.forEach { $0.removeFromParentNode() }
        let orange = Self.material(S3Color(red: 1, green: 0.55, blue: 0.1, alpha: 1))
        let ring = Self.material(S3Color(red: 0.1, green: 0.5, blue: 1, alpha: 1))
        for p in points {
            let cyl = SCNCylinder(radius: 0.14, height: 0.9)
            cyl.firstMaterial = p.id == highlight ? ring : orange
            let n = SCNNode(geometry: cyl)
            n.position = SCNVector3(p.x / 100, 0.45, p.y / 100)
            pointsNode.addChildNode(n)
        }
    }

    // MARK: 磁场热力图

    /// 把磁场地图（|B|）画成贴在地板上的彩色图：蓝 = 弱，红 = 强。只画有数据的格子。
    func setField(_ f: MagneticFieldMap?) {
        fieldNode.childNodes.forEach { $0.removeFromParentNode() }
        guard let f, f.coveredCells > 0, let img = Self.heatImage(f) else { return }
        let plane = SCNPlane(width: f.widthCm / 100, height: f.heightCm / 100)
        let m = SCNMaterial()
        m.diffuse.contents = img
        m.diffuse.magnificationFilter = .nearest
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        plane.firstMaterial = m
        let n = SCNNode(geometry: plane)
        n.position = SCNVector3(f.widthCm / 200, 0.03, f.heightCm / 200)
        n.eulerAngles = SCNVector3(-Double.pi / 2, 0, 0)       // 平放；图片顶边对应地图 y = 0
        fieldNode.addChildNode(n)
    }

    private static func heatImage(_ f: MagneticFieldMap) -> CGImage? {
        var vals: [Double] = []
        for j in 0..<f.rows { for i in 0..<f.cols {
            if let s = f.sample(at: Point2((Double(i) + 0.5) * f.cellCm, (Double(j) + 0.5) * f.cellCm)) { vals.append(s.mean.total) }
        } }
        guard vals.count > 4 else { return nil }
        vals.sort()
        let lo = vals[vals.count / 20], hi = max(vals[vals.count * 19 / 20], lo + 1)
        var px = [UInt8](repeating: 0, count: f.cols * f.rows * 4)
        for j in 0..<f.rows { for i in 0..<f.cols {
            guard let s = f.sample(at: Point2((Double(i) + 0.5) * f.cellCm, (Double(j) + 0.5) * f.cellCm)) else { continue }
            let t = min(max((s.mean.total - lo) / (hi - lo), 0), 1)
            let (r, g, b) = ramp(t)
            let k = (j * f.cols + i) * 4
            px[k] = UInt8(r * 190); px[k + 1] = UInt8(g * 190); px[k + 2] = UInt8(b * 190); px[k + 3] = 190   // 预乘 alpha
        } }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let prov = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: f.cols, height: f.rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.cols * 4,
                       space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 蓝 → 青 → 绿 → 黄 → 红
    private static func ramp(_ t: Double) -> (Double, Double, Double) {
        let stops: [(Double, Double, Double)] = [(0.15, 0.25, 0.9), (0.1, 0.75, 0.9), (0.2, 0.8, 0.3), (0.95, 0.85, 0.15), (0.9, 0.2, 0.15)]
        let x = t * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2), f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
    }

    // MARK: 当前位置与轨迹

    private func buildAvatar() {
        let cone = SCNCone(topRadius: 0, bottomRadius: 0.32, height: 0.9)
        cone.firstMaterial = Self.material(S3Color(red: 0.05, green: 0.4, blue: 0.95, alpha: 1))
        let c = SCNNode(geometry: cone)
        c.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)       // 锥尖朝 +z，即地图 +y（航向 0）
        c.position = SCNVector3(0, 0.35, 0.65)
        let body = SCNSphere(radius: 0.26)
        body.firstMaterial = Self.material(S3Color(red: 0.05, green: 0.4, blue: 0.95, alpha: 1))
        let b = SCNNode(geometry: body)
        b.position = SCNVector3(0, 0.3, 0)
        avatarRoot.addChildNode(c)
        avatarRoot.addChildNode(b)
        let tube = SCNTube(innerRadius: 0.94, outerRadius: 1.0, height: 0.02)
        tube.firstMaterial = Self.material(S3Color(red: 0.05, green: 0.4, blue: 0.95, alpha: 0.55), lit: false)
        ringNode.geometry = tube
        ringNode.position = SCNVector3(0, 0.04, 0)
        avatarRoot.addChildNode(ringNode)
        avatarRoot.isHidden = true
    }

    /// 位置（cm）、朝向（弧度，0 = 地图 +y，dx = sin，dy = cos）、1σ 不确定度（cm）。position 为 nil 时隐藏。
    func setPose(position: Point2?, headingRad: Double, uncertaintyCm: Double) {
        guard let p = position else { avatarRoot.isHidden = true; return }
        avatarRoot.isHidden = false
        avatarPos = SCNVector3(p.x / 100, 0, p.y / 100)
        avatarHeading = headingRad
        avatarRoot.position = avatarPos
        avatarRoot.eulerAngles = SCNVector3(0, headingRad, 0)
        let r = max(uncertaintyCm / 100, 0.3)
        ringNode.scale = SCNVector3(r, 1, r)
    }

    func setTrail(_ trail: [Point2]) {
        trailNode.childNodes.forEach { $0.removeFromParentNode() }
        guard trail.count >= 2 else { return }
        let w = 0.09
        var verts: [SCNVector3] = [], idx: [Int32] = []
        for i in 0..<trail.count {
            let p = trail[i]
            let a = trail[max(i - 1, 0)], b = trail[min(i + 1, trail.count - 1)]
            var dx = b.x - a.x, dy = b.y - a.y
            let l = (dx * dx + dy * dy).squareRoot()
            if l < 1e-6 { dx = 1; dy = 0 } else { dx /= l; dy /= l }
            let nx = -dy * w, nz = dx * w                      // 法向
            verts.append(SCNVector3(p.x / 100 + nx, 0.05, p.y / 100 + nz))
            verts.append(SCNVector3(p.x / 100 - nx, 0.05, p.y / 100 - nz))
            if i > 0 {
                let k = Int32(i * 2)
                idx += [k - 2, k - 1, k, k - 1, k + 1, k]
            }
        }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        let m = Self.material(S3Color(red: 0.05, green: 0.4, blue: 0.95, alpha: 1), lit: false)
        m.isDoubleSided = true
        geo.firstMaterial = m
        trailNode.addChildNode(SCNNode(geometry: geo))
    }

    // MARK: 相机

    func setCamera(_ mode: CameraMode) {
        let cx = (content.minX + content.maxX) / 2, cz = (content.minZ + content.maxZ) / 2
        let span = max(content.maxX - content.minX, (content.maxZ - content.minZ) * 2.0) * 0.95
        switch mode {
        case .overview:
            cameraNode.position = SCNVector3(cx, span * 0.62, cz + span * 0.55)
            cameraNode.look(at: SCNVector3(cx, 0, cz))
        case .top:
            cameraNode.position = SCNVector3(cx, span * 0.95, cz + 0.001)
            cameraNode.look(at: SCNVector3(cx, 0, cz), up: SCNVector3(0, 0, -1), localFront: SCNVector3(0, 0, -1))
        case .follow:
            followAvatar()
        }
    }

    /// 跟随视角：在人身后偏上方，朝前看。
    func followAvatar(back: Double = 6, up: Double = 3.6) {
        let f = (x: sin(avatarHeading), z: cos(avatarHeading))
        cameraNode.position = SCNVector3(Double(avatarPos.x) - f.x * back, up, Double(avatarPos.z) - f.z * back)
        cameraNode.look(at: SCNVector3(Double(avatarPos.x) + f.x * 3, 0.6, Double(avatarPos.z) + f.z * 3))
    }

    // MARK: 工具

    private static func material(_ color: S3Color, lit: Bool = true) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = lit ? .lambert : .constant
        m.isDoubleSided = false
        if color.cgColor.alpha < 1 {
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
        }
        return m
    }
}
