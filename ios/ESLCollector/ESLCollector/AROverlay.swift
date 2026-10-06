import ARKit
import HPASSKit
import SceneKit
import SwiftUI

/// AR 叠加的内容：在摄像头画面上，把地图里附近的实物货架画成线框、通道中心线画在地上、点位竖成标杆、
/// 走过的路画成地面绿带。用来现场一眼看出地图和实物差多少。
///
/// 节点层级：`root`（地图 → ARKit：绕 y 转 φ、平移、抬到地面高度）→ `nudge`（现场微调：绕我所在位置转、平移）→ 内容。
/// 内容的坐标 = 地图 cm / 100（米），y = 离地高度。只在主线程使用。
final class AROverlayScene {
    let root = SCNNode()
    private let nudge = SCNNode()
    private let content = SCNNode()
    private let trailNode = SCNNode()
    private var builtCenter: Point2?
    private var builtKey = ""

    /// 只画这个半径内的东西（cm）。整张图一千多个货架都叠上去，远处的会穿墙乱成一片。
    var radiusCm: Double = 1500
    var shelfHeightM: Double = 1.8

    init() {
        root.addChildNode(nudge)
        nudge.addChildNode(content)
        nudge.addChildNode(trailNode)
        root.isHidden = true
    }

    /// 地图 → ARKit 的变换；nil 表示还没对齐，隐藏叠加。
    func setTransform(_ t: MapARTransform?, floorY: Double) {
        guard let t else { root.isHidden = true; return }
        root.isHidden = false
        let tr = t.sceneTranslationM
        root.position = SCNVector3(tr.x, floorY, tr.z)
        root.eulerAngles = SCNVector3(0, t.sceneRotationY, 0)
    }

    /// 现场微调：绕当前位置 `pivot` 转 `angleDeg`（俯视逆时针为正），再平移 (dx, dy) cm（地图坐标方向）。
    func setNudge(angleDeg: Double, dxCm: Double, dyCm: Double, pivot: Point2) {
        let px = pivot.x / 100, pz = pivot.y / 100
        nudge.pivot = SCNMatrix4MakeTranslation(Float(px), 0, Float(pz))
        nudge.position = SCNVector3(px + dxCm / 100, 0, pz + dyCm / 100)
        nudge.eulerAngles = SCNVector3(0, angleDeg * Double.pi / 180, 0)
    }

    /// 以 `center` 为中心重建附近的货架、通道、点位。走出 3 m 才重建。
    func setLocal(center: Point2, map: StoreMap, points: [MarkPoint], force: Bool = false) {
        let key = "\(map.shelves.count)/\(map.crosses.count)/\(points.count)/\(shelfHeightM)"
        if !force, key == builtKey, let c = builtCenter, c.distance(to: center) < 300 { return }
        builtCenter = center
        builtKey = key
        content.childNodes.forEach { $0.removeFromParentNode() }
        let holder = SCNNode()

        let wire = SCNMaterial()
        wire.diffuse.contents = UIColor.systemOrange
        wire.fillMode = .lines
        wire.lightingModel = .constant
        wire.isDoubleSided = true
        let face = SCNMaterial()
        face.diffuse.contents = UIColor.systemOrange.withAlphaComponent(0.12)
        face.lightingModel = .constant
        face.isDoubleSided = true
        face.writesToDepthBuffer = false

        for s in map.physicalShelves where Point2(s.x, s.y).distance(to: center) <= radiusCm {
            for m in [face, wire] {
                let box = SCNBox(width: s.width / 100, height: shelfHeightM, length: s.height / 100, chamferRadius: 0)
                box.firstMaterial = m
                let n = SCNNode(geometry: box)
                n.position = SCNVector3(s.x / 100, shelfHeightM / 2, s.y / 100)
                n.eulerAngles = SCNVector3(0, -s.rotation * Double.pi / 180, 0)
                holder.addChildNode(n)
            }
        }

        let cyan = SCNMaterial()
        cyan.diffuse.contents = UIColor.systemTeal
        cyan.lightingModel = .constant
        for c in map.crosses {
            let len = c.a.distance(to: c.b)
            guard len > 1 else { continue }
            // 只画离中心近的那一段
            let dir = Point2((c.b.x - c.a.x) / len, (c.b.y - c.a.y) / len)
            let t = max(0, min(len, (center - c.a).dot(dir)))
            let near = Point2(c.a.x + dir.x * t, c.a.y + dir.y * t)
            guard near.distance(to: center) <= radiusCm else { continue }
            let s0 = max(0, t - radiusCm), s1 = min(len, t + radiusCm)
            let box = SCNBox(width: (s1 - s0) / 100, height: 0.01, length: 0.06, chamferRadius: 0)
            box.firstMaterial = cyan
            let n = SCNNode(geometry: box)
            let mid = (s0 + s1) / 2
            n.position = SCNVector3((c.a.x + dir.x * mid) / 100, 0.01, (c.a.y + dir.y * mid) / 100)
            n.eulerAngles = SCNVector3(0, -atan2(dir.y, dir.x), 0)
            holder.addChildNode(n)
        }

        let pin = SCNMaterial()
        pin.diffuse.contents = UIColor.systemBlue
        pin.lightingModel = .constant
        for p in points where p.position.distance(to: center) <= radiusCm {
            let cyl = SCNCylinder(radius: 0.05, height: 2.2)
            cyl.firstMaterial = pin
            let n = SCNNode(geometry: cyl)
            n.position = SCNVector3(p.x / 100, 1.1, p.y / 100)
            holder.addChildNode(n)
        }
        content.addChildNode(holder.flattenedClone())
    }

    /// 走过的路：地上一条绿带。
    func setTrail(_ trail: [Point2]) {
        trailNode.childNodes.forEach { $0.removeFromParentNode() }
        guard trail.count >= 2 else { return }
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.7)
        m.lightingModel = .constant
        m.isDoubleSided = true
        let holder = SCNNode()
        for i in 1..<trail.count {
            let a = trail[i - 1], b = trail[i]
            let l = a.distance(to: b)
            guard l > 1 else { continue }
            let box = SCNBox(width: l / 100, height: 0.005, length: 0.15, chamferRadius: 0)
            box.firstMaterial = m
            let n = SCNNode(geometry: box)
            n.position = SCNVector3((a.x + b.x) / 200, 0.015, (a.y + b.y) / 200)
            n.eulerAngles = SCNVector3(0, -atan2(b.y - a.y, b.x - a.x), 0)
            holder.addChildNode(n)
        }
        trailNode.addChildNode(holder.flattenedClone())
    }
}

/// 摄像头画面 + 叠加。和视觉里程计共用同一个 ARSession，不会再开一个会话。
struct AROverlayView: UIViewRepresentable {
    let session: ARSession
    let overlay: AROverlayScene

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = session
        v.scene = SCNScene()
        v.scene.rootNode.addChildNode(overlay.root)
        v.automaticallyUpdatesLighting = false
        v.autoenablesDefaultLighting = true
        v.rendersCameraGrain = false
        return v
    }

    func updateUIView(_ v: ARSCNView, context: Context) {
        if v.session !== session { v.session = session }
        if overlay.root.parent == nil { v.scene.rootNode.addChildNode(overlay.root) }
    }
}

/// 现场校对记录：每次「记录偏移」写一行，回电脑可以汇总出地图哪里偏、偏多少。
enum ARCheckLog {
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ar-checks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ar_offsets.csv")
    }

    static func append(position: Point2, angleDeg: Double, dxCm: Double, dyCm: Double, shelfHeightM: Double, note: String) {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("t_ms,map_x_cm,map_y_cm,rotate_deg,dx_cm,dy_cm,shelf_height_m,note\n".utf8).write(to: url)
        }
        let line = [
            "\(Fmt.nowMs())", Fmt.f(position.x, 0), Fmt.f(position.y, 0), Fmt.f(angleDeg, 1),
            Fmt.f(dxCm, 0), Fmt.f(dyCm, 0), Fmt.f(shelfHeightM, 2), Fmt.csv(note),
        ].joined(separator: ",") + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
        AppLog.i("AR校对", "记录偏移：位置 \(position)，旋转 \(Fmt.f(angleDeg, 1))°，平移 (\(Int(dxCm)), \(Int(dyCm))) cm")
    }

    static var count: Int {
        guard let t = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        return max(t.split(separator: "\n").count - 1, 0)
    }
}
