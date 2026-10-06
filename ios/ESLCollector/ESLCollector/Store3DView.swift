import HPASSKit
import SceneKit
import SwiftUI

/// 3D 场景的持有者。地图变了才重建；位置、轨迹、采集进度由页面推送进来。
@MainActor
final class Store3DModel: ObservableObject {
    private(set) var scene: Store3DScene?
    private var signature = ""
    private var lastCoverageRevision = -1
    private var lastCoverageTime = Date.distantPast
    private var fieldSignature = -1

    /// 地图换了就重建场景；返回场景。
    @discardableResult
    func ensure(map: StoreMap, shelfOffset: Point2 = Point2(0, 0)) -> Store3DScene {
        // 签名里不含货架偏移：偏移变了只挪货架节点（setShelfOffset），不重建整个场景
        let sig = "\(Int(map.width))x\(Int(map.height))/\(map.shelves.count)/\(map.crosses.count)"
        if let s = scene, sig == signature { return s }
        let s = Store3DScene(map: map, shelfOffset: shelfOffset)
        scene = s
        signature = sig
        lastCoverageRevision = -1
        fieldSignature = -1
        lastPaint = nil
        paintShown = false
        objectWillChange.send()
        return s
    }

    /// 采集进度最多每秒重建一次：通道多的时候重建要生成几千个小盒子。
    func updateCoverage(crosses: [CrossSegment], coverage: SurveyCoverage, force: Bool = false) {
        guard let s = scene else { return }
        let rev = coverage.revision
        if !force && (rev == lastCoverageRevision || Date().timeIntervalSince(lastCoverageTime) < 1) { return }
        lastCoverageRevision = rev
        lastCoverageTime = Date()
        s.setCoverage(crosses: crosses, states: coverage.states, binCm: SurveyCoverage.binCm)
    }

    private weak var lastPaint: PaintLayer?
    private var paintShown = false

    /// 不画按方向的采集进度（切到涂色图层时）
    func clearCoverage() {
        guard let s = scene, lastCoverageRevision != -2 else { return }
        lastCoverageRevision = -2
        s.setCoverage(crosses: [], states: [], binCm: SurveyCoverage.binCm)
    }

    /// 涂色图层换了（每秒最多一次）才重新贴
    func updatePaint(_ l: PaintLayer?) {
        guard let s = scene else { return }
        if l === lastPaint && (l != nil) == paintShown { return }
        lastPaint = l
        paintShown = l != nil
        s.setPaint(l)
    }

    func updateField(_ f: MagneticFieldMap?, signature sig: Int) {
        guard let s = scene, sig != fieldSignature else { return }
        fieldSignature = sig
        s.setField(f)
    }
}

/// 把 SceneKit 场景放进 SwiftUI。跟随模式下相机由程序控制，其他模式可以单指转、双指缩放 / 平移。
struct Store3DView: UIViewRepresentable {
    let scene: Store3DScene
    var follow: Bool

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = scene.scene
        v.pointOfView = scene.cameraNode
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = .secondarySystemBackground
        v.allowsCameraControl = !follow
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        v.rendersContinuously = false
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        if v.scene !== scene.scene { v.scene = scene.scene; v.pointOfView = scene.cameraNode }
        v.allowsCameraControl = !follow
        v.setNeedsDisplay()
    }
}
